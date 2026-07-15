import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Turns client `Input` / `RequestFocus` messages into real macOS events (issue
/// #7, Phase 5). This is the impure half of input: the coordinate math
/// (`Coordinates.axGlobalPoint`), the keycode table (`Keymap`) and the modifier
/// tracking (`ModifierState`) are all pure and tested elsewhere — this type wires
/// them to `CGEventPost` and `AXRaise`, which can only be exercised on the Mac
/// (I-7).
///
/// **Threading.** `ControlServer` calls `handle` from its per-connection receive
/// loop, in message order. A lock serialises the mutable state (modifier + mouse
/// button tracking) and the posting so events land in the order the client sent
/// them; `@unchecked Sendable` is on that confinement, not to hide a race.
public final class InputInjector: @unchecked Sendable {

    private let display: DisplayInfo
    private let registry: WindowRegistry
    private let modifierMap: ModifierMap
    private let source: CGEventSource?
    private let lock = NSLock()

    // Mutable state, all under `lock`.
    private var modifiers = ModifierState()
    private var mouseButtonsDown: Set<MouseButton> = []

    /// Optional human-readable trace of the full translation chain, one line per
    /// event. `serve --log-input` and the `inject` command wire this to `print`;
    /// otherwise the same detail still goes to `Log.input`.
    public var onTrace: (@Sendable (String) -> Void)?

    public init(display: DisplayInfo, registry: WindowRegistry, modifierMap: ModifierMap = .swap) {
        self.display = display
        self.registry = registry
        self.modifierMap = modifierMap
        // A dedicated HID-level source. The host is headless with no local user
        // (issue #7), so there is no real cursor or keyboard state to fight with.
        self.source = CGEventSource(stateID: .hidSystemState)
    }

    /// Entry point from the control channel. Ignores messages that are not input
    /// (those are handled elsewhere — e.g. `requestResize`).
    public func handle(_ message: ClientMessage) {
        switch message {
        case .input(let id, let event, let ts):
            inject(id: id, event: event, ts: ts)
        case .requestFocus(let id):
            requestFocus(id: id)
        case .requestResize, .requestClose:
            break
        }
    }

    /// Drop all modifier state. Called when a client disconnects so a ⌘ left held
    /// by a dropped session cannot wedge into the next one.
    public func resetModifiers() {
        lock.withLock { modifiers.reset() }
    }

    // MARK: - Injection

    public func inject(id: UInt64, event: InputEvent, ts: UInt64) {
        lock.withLock {
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
                postKey(vk: vk, down: true, ts: ts)
            case .keyUp(let vk):
                postKey(vk: vk, down: false, ts: ts)
            }
        }
    }

    /// Raise + focus the window behind `id` (client `RequestFocus`). Wires up
    /// protocol.md §4 `RequestFocus`.
    public func requestFocus(id: UInt64) {
        lock.withLock {
            guard let element = registry.element(for: id) else {
                trace("requestFocus id=\(id): unknown window id")
                return
            }
            let outcome = raise(element)
            trace(
                "requestFocus id=\(id): raised=\(outcome.raised) activatedApp=\(outcome.activatedApp)"
            )
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

        // A click on a window that is not frontmost must raise it *before* the
        // event lands, or the click goes to the wrong place (issue #7).
        var raiseNote = ""
        if down, let element = registry.element(for: id) {
            let outcome = raise(element)
            if outcome.activatedApp || outcome.raised {
                raiseNote = " raised=\(outcome.raised) activatedApp=\(outcome.activatedApp)"
            }
        }

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
            extra: "button=\(button.rawValue) flags=\(describe(flags))\(raiseNote)",
            ts: ts)
    }

    /// Assumes `lock` is held.
    private func postMouseMove(id: UInt64, x: UInt32, y: UInt32, ts: UInt64) {
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
    private func postKey(vk: UInt32, down: Bool, ts: UInt64) {
        // Modifiers are tracked, not posted: their state is stamped onto the
        // events that follow (issue #7). `apply` returns true iff `vk` is one.
        if modifiers.apply(vk: vk, down: down) {
            traceChain(
                id: 0, label: down ? "modDown" : "modUp", x: 0, y: 0, point: nil,
                extra: "vk=0x\(hex(vk)) held=\(describeHeld())", ts: ts)
            return
        }

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
            id: 0, label: down ? "keyDown" : "keyUp", x: 0, y: 0, point: nil,
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

    /// Raise the window within its app, and bring the app frontmost if it is not
    /// already. AX raise is cheap and idempotent; app activation only fires when
    /// the frontmost app actually differs, so a click inside the already-front
    /// app does not thrash focus.
    private func raise(_ element: AXUIElement) -> (raised: Bool, activatedApp: Bool) {
        let raiseErr = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        var pid: pid_t = 0
        var activated = false
        if AXUIElementGetPid(element, &pid) == .success {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                NSRunningApplication(processIdentifier: pid)?.activate()
                activated = true
            }
        }
        return (raiseErr == .success, activated)
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
