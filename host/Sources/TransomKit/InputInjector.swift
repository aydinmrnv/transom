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
/// loop, in message order. A lock serialises the mutable state (modifier + pointer
/// tracking) and the posting so events land in the order the client sent
/// them; `@unchecked Sendable` is on that confinement, not to hide a race.
public final class InputInjector: @unchecked Sendable {

    private let display: DisplayInfo
    private let registry: WindowRegistry
    private let modifierMap: ModifierMap
    private let source: CGEventSource?
    private let lock = NSLock()

    // Mutable state, all under `lock`.
    private var modifiers = ModifierState()
    private var pointer = PointerRouter()

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
        case .requestResize, .requestClose, .requestKeyframe:
            break
        }
    }

    /// Let go of everything the client was holding. Called when a client
    /// disconnects so neither a ⌘ nor a mouse button left held by a dropped
    /// session can wedge into the next one.
    public func reset() {
        lock.withLock {
            for post in pointer.releaseAll() { self.post(post, id: 0, ts: 0) }
            modifiers.reset()
        }
    }

    /// True while the client holds a mouse button down. A drag can be moving or
    /// resizing a window, so the layout guard waits for it to end.
    public var isPointerDown: Bool {
        lock.withLock { pointer.isDragging }
    }

    // MARK: - Injection

    public func inject(id: UInt64, event: InputEvent, ts: UInt64) {
        lock.withLock {
            switch event {
            case .mouseDown, .mouseUp, .mouseMove, .scroll:
                routePointer(id: id, event: event, ts: ts)
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

    /// Route one pointer event through `PointerRouter` and post what it allows.
    /// Assumes `lock` is held.
    private func routePointer(id: UInt64, event: InputEvent, ts: UInt64) {
        // A press decides where the whole drag lands, so it reads the window's
        // frame live rather than trusting a rect that may lag a move by a tick.
        var rect = registry.entry(for: id)?.rect
        if case .mouseDown = event, rect != nil, let live = liveRect(id: id) { rect = live }

        let route = pointer.route(event, id: id, rect: rect)
        for post in route.posts { self.post(post, id: id, ts: ts) }
        if let reason = route.dropped {
            trace("input id=\(id) \(event): \(reason), dropped")
        }
    }

    /// Post one routed event. Assumes `lock` is held.
    private func post(_ post: PointerRouter.Post, id: UInt64, ts: UInt64) {
        let point = Coordinates.axGlobalPoint(
            fromWindowLocalPixels: CGPoint(x: Double(post.x), y: Double(post.y)),
            windowOriginVDS: CGPoint(x: Double(post.rect.x), y: Double(post.rect.y)),
            displayOriginPoints: display.originPoints,
            scale: display.scale)
        let flags = modifiers.flags(using: modifierMap)

        let event: CGEvent?
        let label: String
        var extra = "flags=\(describe(flags))"
        switch post.kind {
        case .down(let button):
            // A click on a window that is not frontmost must raise it *before* the
            // event lands, or the click goes to the wrong place (issue #7).
            if let element = registry.element(for: id) {
                let outcome = raise(element)
                if outcome.activatedApp || outcome.raised {
                    extra += " raised=\(outcome.raised) activatedApp=\(outcome.activatedApp)"
                }
            }
            let types = mouseTypes(button)
            event = CGEvent(
                mouseEventSource: source, mouseType: types.down, mouseCursorPosition: point,
                mouseButton: types.cg)
            label = "mouseDown"
            extra = "button=\(button.rawValue) " + extra
        case .up(let button):
            let types = mouseTypes(button)
            event = CGEvent(
                mouseEventSource: source, mouseType: types.up, mouseCursorPosition: point,
                mouseButton: types.cg)
            label = "mouseUp"
            extra = "button=\(button.rawValue) " + extra
        case .drag(let button):
            // With a button held this is a drag, which apps treat very differently
            // from a hover (text selection, window drags).
            let types = mouseTypes(button)
            event = CGEvent(
                mouseEventSource: source, mouseType: types.drag, mouseCursorPosition: point,
                mouseButton: types.cg)
            label = "mouseDrag"
        case .move:
            event = CGEvent(
                mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point,
                mouseButton: .left)
            label = "mouseMove"
        case .scroll(let dx, let dy):
            // wheel1 = vertical, wheel2 = horizontal (CoreGraphics ordering).
            event = CGEvent(
                scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                wheel1: dy, wheel2: dx, wheel3: 0)
            event?.location = point
            label = "scroll"
            extra = "dx=\(dx) dy=\(dy)"
        }
        guard let event else {
            trace("\(label): CGEvent creation failed")
            return
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        traceChain(id: id, label: label, x: post.x, y: post.y, point: point, extra: extra, ts: ts)
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

    // MARK: - Geometry

    /// The window's frame as AX reports it right now, in VDS pixels, or nil if AX
    /// will not say or the window is not wholly on the display. Assumes `lock` is
    /// held.
    private func liveRect(id: UInt64) -> WireRect? {
        guard let element = registry.element(for: id),
            let frame = AXWindow(element: element, index: -1).frame()
        else { return nil }
        return WindowWatcher.captureRect(
            Coordinates.displayPixels(
                fromAXRect: frame, displayOriginPoints: display.originPoints, scale: display.scale),
            displayWidth: display.pixelWidth, displayHeight: display.pixelHeight)
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
