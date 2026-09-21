import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Turns client `Input` / `RequestFocus` messages into real macOS events (issue
/// #7, Phase 5). This is the impure half of input: the coordinate math
/// (`Coordinates.axGlobalPoint`), the keycode table (`Keymap`) and the modifier
/// tracking (`ModifierState`) are all pure and tested elsewhere — this type wires
/// them to HID events and verified AX focus, which can only be exercised on the Mac
/// (I-7).
///
/// **Threading.** `ControlServer` calls `handle` from its per-connection receive
/// loop, in message order. A serial worker keeps AX calls off the receive actor.
/// Adjacent motion coalesces while clicks/keys retain order. Locks confine the
/// mailbox and injection state, including the synchronous diagnostic CLI API.
public final class InputInjector: @unchecked Sendable {

    private let display: DisplayInfo
    private let registry: WindowRegistry
    private let modifierMap: ModifierMap
    private let source: CGEventSource?
    private let lock = NSLock()
    private let mailboxLock = NSLock()
    private let deliveryQueue = DispatchQueue(label: "one.transom.input", qos: .userInteractive)
    private var mailbox = InputMailbox()
    private var draining = false

    // Mutable state, all under `lock`.
    private var modifiers = ModifierState()
    private var mouseButtonsDown: Set<MouseButton> = []
    private var focusedID: UInt64?

    /// Optional human-readable trace of the full translation chain, one line per
    /// event. `serve --log-input` and the `inject` command wire this to `print`;
    /// otherwise the same detail still goes to `Log.input`.
    public var onTrace: (@Sendable (String) -> Void)?

    public init(display: DisplayInfo, registry: WindowRegistry, modifierMap: ModifierMap = .swap) {
        self.display = display
        self.registry = registry
        self.modifierMap = modifierMap
        // Use a dedicated event source; modifier flags are supplied explicitly
        // from the client. HID delivery follows verified target focus.
        self.source = CGEventSource(stateID: .hidSystemState)
    }

    /// Entry point from the control channel. Ignores messages that are not input
    /// (those are handled elsewhere — e.g. `requestResize`).
    public func handle(_ message: ClientMessage) {
        enqueue(message)
    }

    private func enqueue(_ message: ClientMessage) {
        let start = mailboxLock.withLock {
            mailbox.append(message)
            guard !draining else { return false }
            draining = true
            return true
        }
        if start { deliveryQueue.async { [self] in drain() } }
    }

    private func drain() {
        while let work = mailboxLock.withLock({ () -> InputMailbox.Work? in
            guard let work = mailbox.next() else { draining = false; return nil }
            return work
        }) {
            switch work {
            case .message(let message): deliver(message)
            case .reset: lock.withLock { modifiers.reset(); mouseButtonsDown.removeAll(); focusedID = nil }
            }
        }
    }

    private func deliver(_ message: ClientMessage) {
        switch message {
        case .input(let id, let event, let ts):
            inject(id: id, event: event, ts: ts)
        case .requestFocus(let id):
            requestFocus(id: id)
        case .requestResize, .commitResize, .requestClose, .requestKeyframe, .openWindow, .releaseWindow, .previewWindow:
            break
        }
    }

    /// Drop all modifier state. Called when a client disconnects so a ⌘ left held
    /// by a dropped session cannot wedge into the next one.
    public func resetModifiers() {
        let start = mailboxLock.withLock {
            mailbox.reset()
            guard !draining else { return false }
            draining = true
            return true
        }
        if start { deliveryQueue.async { [self] in drain() } }
    }

    // MARK: - Injection

    public func inject(id: UInt64, event: InputEvent, ts: UInt64) {
        lock.withLock {
            guard registry.entry(for: id) != nil else {
                trace("input id=\(id): window is not shared, dropped")
                return
            }
            switch event {
            case .mouseDown(let x, let y, let button):
                postMouse(id: id, x: x, y: y, button: button, down: true, ts: ts)
            case .mouseUp(let x, let y, let button):
                postMouse(id: id, x: x, y: y, button: button, down: false, ts: ts)
            case .mouseMove(let x, let y):
                postMouseMove(id: id, x: x, y: y, ts: ts)
            case .scroll(let x, let y, let dx, let dy):
                postScroll(id: id, x: x, y: y, dx: dx, dy: dy, ts: ts)
            case .keyDown(let vk):
                postKey(id: id, vk: vk, down: true, ts: ts)
            case .keyUp(let vk):
                postKey(id: id, vk: vk, down: false, ts: ts)
            }
        }
    }

    /// Raise + focus the window behind `id` (client `RequestFocus`). Wires up
    /// protocol.md §4 `RequestFocus`.
    public func requestFocus(id: UInt64) {
        lock.withLock {
            _ = prepareTarget(id: id)
        }
    }

    /// Ask the remote app to close the window behind `id`. AX does not expose a
    /// universal close action on every window, but standard macOS windows expose
    /// their close button as an AX element. Pressing that button preserves the
    /// app's normal close semantics (including unsaved-document prompts).
    public func close(id: UInt64) {
        lock.withLock {
            guard let element = registry.element(for: id) else {
                trace("requestClose id=\(id): unknown window id")
                return
            }
            var value: CFTypeRef?
            let read = AXUIElementCopyAttributeValue(
                element, "AXCloseButton" as CFString, &value)
            guard read == .success, let value else {
                trace("requestClose id=\(id): close button unavailable")
                return
            }
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                trace("requestClose id=\(id): close button had an unexpected AX type")
                return
            }
            let button = unsafeDowncast(value, to: AXUIElement.self)
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            trace("requestClose id=\(id): press=\(result.rawValue)")
        }
    }

    // MARK: - Mouse

    /// Assumes `lock` is held.
    private func postMouse(
        id: UInt64, x: UInt32, y: UInt32, button: MouseButton, down: Bool, ts: UInt64
    ) {
        guard let point = axPoint(id: id, x: x, y: y, label: down ? "mouseDown" : "mouseUp") else {
            return
        }

        // Focus must be observed, not merely requested, before desktop hit testing.
        if down && !prepareTarget(id: id) { return }
        if !down && !mouseButtonsDown.contains(button) { return }

        if down { mouseButtonsDown.insert(button) } else { mouseButtonsDown.remove(button) }

        let types = mouseTypes(button)
        let flags = modifiers.flags(using: modifierMap)
        guard
            let event = CGEvent(
                mouseEventSource: source, mouseType: down ? types.down : types.up,
                mouseCursorPosition: point, mouseButton: types.cg)
        else {
            trace("mouse: CGEvent creation failed")
            return
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        traceChain(
            id: id, label: down ? "mouseDown" : "mouseUp",
            x: x, y: y, point: point,
            extra: "button=\(button.rawValue) flags=\(describe(flags))",
            ts: ts)
    }

    /// Assumes `lock` is held.
    private func postMouseMove(id: UInt64, x: UInt32, y: UInt32, ts: UInt64) {
        // Hovering an inactive PC view must not send motion to the app covering
        // it on the Mac. Local cursor movement and AX cursor hints still work.
        guard focusedID == id else { return }
        guard let point = axPoint(id: id, x: x, y: y, label: "mouseMove") else { return }
        // If a button is held this is a drag, which apps treat very differently
        // from a hover (text selection, window drags).
        let dragButton = mouseButtonsDown.first
        let type: CGEventType
        let cgButton: CGMouseButton
        if let dragButton {
            let t = mouseTypes(dragButton)
            type = t.drag
            cgButton = t.cg
        } else {
            type = .mouseMoved
            cgButton = .left
        }
        let flags = modifiers.flags(using: modifierMap)
        guard
            let event = CGEvent(
                mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                mouseButton: cgButton)
        else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        traceChain(
            id: id, label: dragButton == nil ? "mouseMove" : "mouseDrag",
            x: x, y: y, point: point, extra: "flags=\(describe(flags))", ts: ts)
    }

    /// Assumes `lock` is held.
    private func postScroll(id: UInt64, x: UInt32, y: UInt32, dx: Int32, dy: Int32, ts: UInt64) {
        guard prepareTarget(id: id) else { return }
        guard let point = axPoint(id: id, x: x, y: y, label: "scroll") else { return }
        // wheel1 = vertical, wheel2 = horizontal (CoreGraphics ordering).
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                wheel1: dy, wheel2: dx, wheel3: 0)
        else { return }
        event.location = point
        event.flags = modifiers.flags(using: modifierMap)
        event.post(tap: .cghidEventTap)
        traceChain(
            id: id, label: "scroll", x: x, y: y, point: point, extra: "dx=\(dx) dy=\(dy)", ts: ts)
    }

    private func mouseTypes(_ button: MouseButton)
        -> (down: CGEventType, up: CGEventType, drag: CGEventType, cg: CGMouseButton)
    {
        switch button {
        case .left: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged, .left)
        case .right: return (.rightMouseDown, .rightMouseUp, .rightMouseDragged, .right)
        case .middle: return (.otherMouseDown, .otherMouseUp, .otherMouseDragged, .center)
        }
    }

    // MARK: - Keyboard

    /// Assumes `lock` is held.
    private func postKey(id: UInt64, vk: UInt32, down: Bool, ts: UInt64) {
        // Modifiers are tracked, not posted: their state is stamped onto the
        // events that follow (issue #7). `apply` returns true iff `vk` is one.
        if modifiers.apply(vk: vk, down: down) {
            traceChain(
                id: id, label: down ? "modDown" : "modUp", x: 0, y: 0, point: nil,
                extra: "vk=0x\(hex(vk)) held=\(describeHeld())", ts: ts)
            return
        }
        guard prepareTarget(id: id) else { return }

        guard let keyCode = Keymap.macKeyCode(forVK: vk) else {
            // Report unmapped keys rather than silently dropping them (issue #7).
            Log.input.notice(
                "input: UNMAPPED Windows VK 0x\(self.hex(vk), privacy: .public), dropped")
            onTrace?("input: UNMAPPED Windows VK 0x\(hex(vk)) — dropped (add it to Keymap)")
            return
        }

        let flags = modifiers.flags(using: modifierMap)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
        else {
            trace("key: CGEvent creation failed for vk=0x\(hex(vk))")
            return
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        traceChain(
            id: id, label: down ? "keyDown" : "keyUp", x: 0, y: 0, point: nil,
            extra: "vk=0x\(hex(vk)) -> mac=0x\(hex(UInt32(keyCode))) flags=\(describe(flags))",
            ts: ts)
    }

    // MARK: - Coordinate translation (the whole risk)

    /// Window-local physical pixels → AX global point, or nil (with a trace) if
    /// the id is unknown. Assumes `lock` is held.
    private func axPoint(id: UInt64, x: UInt32, y: UInt32, label: String) -> CGPoint? {
        guard let entry = registry.entry(for: id) else {
            trace("\(label) id=\(id): unknown window id, dropped")
            return nil
        }
        return Coordinates.axGlobalPoint(
            fromWindowLocalPixels: CGPoint(x: Double(x), y: Double(y)),
            windowOriginVDS: CGPoint(x: Double(entry.rect.x), y: Double(entry.rect.y)),
            displayOriginPoints: display.originPoints,
            scale: display.scale)
    }

    // MARK: - Focus / raise

    /// CGEvent.postToPid accepts event metadata without ensuring AppKit/Electron
    /// deliver the event. Use the normal HID path only after focus readback.
    private func prepareTarget(id: UInt64) -> Bool {
        guard registry.entry(for: id) != nil, let element = registry.element(for: id) else { return false }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.04)
        AXUIElementSetMessagingTimeout(element, 0.04)
        func ready() -> Bool {
            var frontmost: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFrontmostAttribute as CFString, &frontmost) == .success,
                  let frontmost, CFEqual(frontmost, kCFBooleanTrue) else { return false }
            var focused: CFTypeRef?
            return AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success
                && focused.map { CFEqual($0, element) } == true
        }
        if ready() { focusedID = id; return true }
        let start = ProcessInfo.processInfo.systemUptime
        let activated = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if activated != .success { _ = NSRunningApplication(processIdentifier: pid)?.activate() }
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        repeat {
            if ready() {
                focusedID = id
                trace("focus id=\(id) verified=true elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - start) * 1000))")
                return true
            }
            Thread.sleep(forTimeInterval: 0.005)
        } while ProcessInfo.processInfo.systemUptime - start < 0.15
        trace("focus id=\(id) verified=false activate=\(activated.rawValue) raise=\(raised.rawValue); input dropped")
        focusedID = nil
        return false
    }

    // MARK: - Tracing

    private func traceChain(
        id: UInt64, label: String, x: UInt32, y: UInt32, point: CGPoint?, extra: String, ts: UInt64
    ) {
        let coords: String
        if let point {
            coords = "local=(\(x),\(y))px -> ax=(\(fmt(point.x)),\(fmt(point.y)))pt "
        } else {
            coords = ""
        }
        let line = "input id=\(id) \(label) \(coords)\(extra) ts=\(ts)"
        Log.input.info("\(line, privacy: .public)")
        onTrace?(line)
    }

    private func trace(_ message: String) {
        Log.input.notice("\(message, privacy: .public)")
        onTrace?(message)
    }

    private func describeHeld() -> String {
        let names = modifiers.heldModifiers.map { "\($0)" }.sorted()
        return names.isEmpty ? "none" : names.joined(separator: "+")
    }

    private func describe(_ flags: CGEventFlags) -> String {
        var parts: [String] = []
        if flags.contains(.maskCommand) { parts.append("cmd") }
        if flags.contains(.maskShift) { parts.append("shift") }
        if flags.contains(.maskControl) { parts.append("ctrl") }
        if flags.contains(.maskAlternate) { parts.append("opt") }
        return parts.isEmpty ? "none" : parts.joined(separator: "+")
    }

    private func hex(_ v: UInt32) -> String { String(v, radix: 16, uppercase: true) }
    private func fmt(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }
}
