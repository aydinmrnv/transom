import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// How injected input reaches the Mac (protocol.md §4 "Focus and delivery").
public enum InputDelivery: String, Sendable, CaseIterable {
    /// Post each event straight to the owning app, addressed to the target
    /// window. The window is never raised, its app is never brought frontmost,
    /// and the Mac's real cursor does not move — so someone can keep working at
    /// the Mac, even in a window lying on top of the shared one.
    case background
    /// Post at the HID tap, raising the window and activating its app first.
    /// Indistinguishable from a person at the Mac, and exactly as intrusive: it
    /// takes the cursor and the frontmost app.
    case foreground
}

/// Turns client `Input` / `RequestFocus` messages into real macOS events (issue
/// #7, Phase 5). This is the impure half of input: the coordinate math
/// (`Coordinates.axGlobalPoint`), the keycode table (`Keymap`) and the modifier
/// tracking (`ModifierState`) are all pure and tested elsewhere — this type wires
/// them to `CGEventPost` and `AXRaise`, which can only be exercised on the Mac
/// (I-7).
///
/// **Background delivery** (`InputDelivery.background`, architecture.md §8) uses
/// public API only: `CGEvent.postToPid` carries the event to the app, and building
/// the mouse event through `NSEvent.mouseEvent(…windowNumber:)` is what addresses
/// it to one window. An app that is not frontmost ignores clicks in web content,
/// so the app is first told it is active (an `.appKitDefined` /
/// `.applicationActivated` event) and the window is made key with a click just
/// outside its bounds — neither changes the real frontmost app or the z-order.
///
/// **Threading.** `ControlServer` calls `handle` from its per-connection receive
/// loop, in message order. A lock serialises the mutable state (modifier + pointer
/// tracking) and the posting so events land in the order the client sent
/// them; `@unchecked Sendable` is on that confinement, not to hide a race.
public final class InputInjector: @unchecked Sendable {

    private let display: DisplayInfo
    private let registry: WindowRegistry
    private let modifierMap: ModifierMap
    private let delivery: InputDelivery
    private let source: CGEventSource?
    private let lock = NSLock()

    // Mutable state, all under `lock`.
    private var modifiers = ModifierState()
    private var pointer = PointerRouter()
    // Background-delivery state, all under `lock`.

    /// The window a background mouse event is addressed to. `origin` is its
    /// top-left in AX global points, to turn the event's point window-local.
    private struct BackgroundTarget {
        let pid: pid_t
        let windowID: CGWindowID
        let origin: CGPoint
    }
    /// A button that went down, and where: its drags and its up go to the same
    /// window with the same event number, as they would for a real mouse.
    private struct HeldButton {
        let target: BackgroundTarget
        let eventNumber: Int
        let clickCount: Int
    }
    private var heldButtons: [MouseButton: HeldButton] = [:]
    private var clicks = ClickCounter()
    private var eventNumber = 0
    private var windowCache: (time: TimeInterval, windows: [WindowServerWindow])?
    /// The WindowServer window behind each shared window id (OQ-3), once matched.
    private var primaryIDs: [UInt64: CGWindowID] = [:]
    /// The shared window that last took client focus.
    private var focus: (id: UInt64, pid: pid_t)?
    /// The window of the focused app this injector last made (or found) key.
    private var keyWindowID: CGWindowID?
    /// Apps this injector told they were active, to be told otherwise later.
    private var activatedPIDs: Set<pid_t> = []

    /// How stale the window list may be for hover and scroll. A mouse-down always
    /// takes a fresh one.
    private static let windowCacheMaxAge: TimeInterval = 0.1

    /// How long to wait for an app to act on a posted activation before sending
    /// the click anyway.
    private static let activationDeadline: TimeInterval = 0.3

    /// How far up-left of a window (points) the click that makes it key lands.
    /// It must clear the window's resize band: a click just outside the frame
    /// (measured at -1,-1) is held by AppKit's edge-resize gesture and replayed
    /// half a second later into whatever view was clicked last — a stray click.
    private static let keyClickOffset: CGFloat = 10_000

    /// Optional human-readable trace of the full translation chain, one line per
    /// event. `serve --log-input` and the `inject` command wire this to `print`;
    /// otherwise the same detail still goes to `Log.input`.
    public var onTrace: (@Sendable (String) -> Void)?

    public init(
        display: DisplayInfo, registry: WindowRegistry, modifierMap: ModifierMap = .swap,
        delivery: InputDelivery = .background
    ) {
        self.display = display
        self.registry = registry
        self.modifierMap = modifierMap
        self.delivery = delivery
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

    /// Undo what background delivery told the shared apps: an app this injector
    /// marked active is marked inactive again, unless the user has since really
    /// brought it forward. Called when the client disconnects and when the
    /// session stops.
    public func releaseFocus() {
        lock.withLock {
            guard delivery == .background else { return }
            for pid in activatedPIDs { resignActivation(pid: pid) }
            focus = nil
            keyWindowID = nil
            primaryIDs.removeAll()
            heldButtons.removeAll()
            windowCache = nil
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
                postKey(id: id, vk: vk, down: true, ts: ts)
            case .keyUp(let vk):
                postKey(id: id, vk: vk, down: false, ts: ts)
            }
        }
    }

    /// Give the window behind `id` focus (client `RequestFocus`, protocol.md §4).
    /// Foreground delivery raises it; background delivery makes it key in place.
    public func requestFocus(id: UInt64) {
        lock.withLock {
            guard let element = registry.element(for: id) else {
                trace("requestFocus id=\(id): unknown window id")
                return
            }
            if delivery == .background {
                guard let pid = pid(of: element) else {
                    trace("requestFocus id=\(id): no pid for window")
                    return
                }
                let note = ensureBackgroundFocus(
                    id: id, element: element, pid: pid, clicked: nil, in: windowList(maxAge: 0))
                trace("requestFocus id=\(id): background pid=\(pid)\(note)")
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
        if delivery == .background {
            postBackground(post, point: point, id: id, ts: ts)
            return
        }
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
    private func postKey(id: UInt64, vk: UInt32, down: Bool, ts: UInt64) {
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
        var route = ""
        if delivery == .background {
            // Keys go to the app that owns the client-focused window; its key
            // window takes them whether or not the app is really frontmost.
            guard let pid = backgroundKeyTarget(id: id) else {
                trace("key vk=0x\(hex(vk)): no shared window has focus, dropped")
                return
            }
            event.postToPid(pid)
            route = " -> pid=\(pid)"
        } else {
            event.post(tap: .cghidEventTap)
        }
        traceChain(
            id: 0, label: down ? "keyDown" : "keyUp", x: 0, y: 0, point: nil,
            extra:
                "vk=0x\(hex(vk)) -> mac=0x\(hex(UInt32(keyCode))) flags=\(describe(flags))\(route)",
            ts: ts)
    }

    // MARK: - Background delivery

    /// Post one routed event straight to the app that owns the window
    /// (`InputDelivery.background`). Assumes `lock` is held.
    private func postBackground(
        _ post: PointerRouter.Post, point: CGPoint, id: UInt64, ts: UInt64
    ) {
        let flags = modifiers.flags(using: modifierMap)
        var extra = "flags=\(describe(flags))"
        let label: String
        let target: BackgroundTarget
        switch post.kind {
        case .down(let button):
            label = "mouseDown"
            let windows = windowList(maxAge: 0)
            guard let element = registry.element(for: id), let pid = pid(of: element),
                let hit = receivingWindow(
                    id: id, element: element, pid: pid, at: point, in: windows)
            else {
                trace("mouseDown id=\(id): no on-screen window of the app at the point, dropped")
                return
            }
            // Focus first, so the click lands as a click and not as the one that
            // merely makes the window key.
            let focusNote = ensureBackgroundFocus(
                id: id, element: element, pid: pid, clicked: hit, in: windows)
            target = BackgroundTarget(pid: pid, windowID: hit.id, origin: hit.bounds.origin)
            eventNumber += 1
            let count = clicks.down(
                button: button, windowID: hit.id, at: point,
                time: ProcessInfo.processInfo.systemUptime, interval: NSEvent.doubleClickInterval)
            heldButtons[button] = HeldButton(
                target: target, eventNumber: eventNumber, clickCount: count)
            postBackgroundMouse(
                backgroundTypes(button).down, to: target, at: point, flags: flags,
                eventNumber: eventNumber, clickCount: count, pressure: 1, button: button)
            extra = "button=\(button.rawValue) \(extra) clicks=\(count)\(focusNote)"

        case .up(let button):
            label = "mouseUp"
            let held = heldButtons.removeValue(forKey: button)
            guard let found = held?.target ?? backgroundTarget(id: id, at: point, maxAge: 0) else {
                trace("mouseUp id=\(id): no on-screen window of the app at the point, dropped")
                return
            }
            target = found
            postBackgroundMouse(
                backgroundTypes(button).up, to: target, at: point, flags: flags,
                eventNumber: held?.eventNumber ?? eventNumber, clickCount: held?.clickCount ?? 1,
                pressure: 0, button: button)
            extra = "button=\(button.rawValue) \(extra)"

        case .drag(let button):
            label = "mouseDrag"
            let held = heldButtons[button]
            guard let found = held?.target ?? backgroundTarget(id: id, at: point, maxAge: 0) else {
                return
            }
            target = found
            postBackgroundMouse(
                backgroundTypes(button).drag, to: target, at: point, flags: flags,
                eventNumber: held?.eventNumber ?? eventNumber, clickCount: held?.clickCount ?? 1,
                pressure: 1, button: button)

        case .move:
            label = "mouseMove"
            guard let found = backgroundTarget(id: id, at: point, maxAge: Self.windowCacheMaxAge)
            else { return }
            target = found
            postBackgroundMouse(
                .mouseMoved, to: target, at: point, flags: flags, eventNumber: 0, clickCount: 0,
                pressure: 0, button: .left)

        case .scroll(let dx, let dy):
            label = "scroll"
            guard let found = backgroundTarget(id: id, at: point, maxAge: Self.windowCacheMaxAge)
            else {
                trace("scroll id=\(id): no on-screen window of the app at the point, dropped")
                return
            }
            target = found
            postBackgroundScroll(to: target, at: point, flags: flags, dx: dx, dy: dy)
            extra = "dx=\(dx) dy=\(dy)"
        }
        traceChain(
            id: id, label: label, x: post.x, y: post.y, point: point,
            extra: extra + describe(target, at: point), ts: ts)
    }

    /// Assumes `lock` is held.
    private func postBackgroundScroll(
        to target: BackgroundTarget, at point: CGPoint, flags: CGEventFlags, dx: Int32, dy: Int32
    ) {
        // `NSEvent` has no scroll constructor, and a scroll made by `CGEvent`
        // cannot be addressed to a window. So build an addressed mouse-moved
        // event and retype it: the window stamp survives, and the scroll fields
        // are then written through the public field setters.
        guard
            let event = backgroundMouseEvent(
                .mouseMoved, to: target, at: point, flags: flags, eventNumber: 0, clickCount: 0,
                pressure: 0)
        else {
            trace("scroll: NSEvent creation failed")
            return
        }
        let pixelsPerLine = Int64((source?.pixelsPerLine ?? 10).rounded())
        event.type = .scrollWheel
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        // Axis 1 = vertical, axis 2 = horizontal (CoreGraphics ordering).
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(dy))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(dx))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis3, value: 0)
        event.setIntegerValueField(
            .scrollWheelEventPointDeltaAxis1, value: Int64(dy) * pixelsPerLine)
        event.setIntegerValueField(
            .scrollWheelEventPointDeltaAxis2, value: Int64(dx) * pixelsPerLine)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis3, value: 0)
        event.postToPid(target.pid)
    }

    /// Assumes `lock` is held.
    private func postBackgroundMouse(
        _ type: NSEvent.EventType, to target: BackgroundTarget, at point: CGPoint,
        flags: CGEventFlags, eventNumber: Int, clickCount: Int, pressure: Float,
        button: MouseButton
    ) {
        guard
            let event = backgroundMouseEvent(
                type, to: target, at: point, flags: flags, eventNumber: eventNumber,
                clickCount: clickCount, pressure: pressure)
        else {
            trace("mouse: NSEvent creation failed")
            return
        }
        if button == .middle {
            event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        }
        event.postToPid(target.pid)
    }

    /// A mouse event addressed to `target`'s window at the AX global `point`.
    ///
    /// Do not set `location` on the result: `CGEventSetLocation` discards the
    /// window-local position this constructor is the only public way to set.
    private func backgroundMouseEvent(
        _ type: NSEvent.EventType, to target: BackgroundTarget, at point: CGPoint,
        flags: CGEventFlags, eventNumber: Int, clickCount: Int, pressure: Float
    ) -> CGEvent? {
        let local = CGPoint(x: point.x - target.origin.x, y: point.y - target.origin.y)
        let location = Coordinates.foreignWindowEventLocation(
            fromWindowLocalPoints: local,
            mainDisplayHeightPoints: CGDisplayBounds(CGMainDisplayID()).height)
        return NSEvent.mouseEvent(
            with: type, location: location,
            // The device-independent modifier bits are the same in both types.
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: Int(target.windowID), context: nil, eventNumber: eventNumber,
            clickCount: clickCount, pressure: pressure)?.cgEvent
    }

    private func backgroundTypes(_ button: MouseButton)
        -> (down: NSEvent.EventType, up: NSEvent.EventType, drag: NSEvent.EventType)
    {
        switch button {
        case .left: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged)
        case .right: return (.rightMouseDown, .rightMouseUp, .rightMouseDragged)
        case .middle: return (.otherMouseDown, .otherMouseUp, .otherMouseDragged)
        }
    }

    /// The window of `pid` that should receive an event at `point`: the app's
    /// frontmost window there (an open menu or sheet beats the shared window
    /// under it), else the shared window itself. Assumes `lock` is held.
    private func receivingWindow(
        id: UInt64, element: AXUIElement, pid: pid_t, at point: CGPoint,
        in windows: [WindowServerWindow]
    ) -> WindowServerWindow? {
        WindowServerWindows.topmost(at: point, pid: pid, in: windows)
            ?? primaryWindow(id: id, element: element, pid: pid, in: windows)
    }

    /// Assumes `lock` is held.
    private func backgroundTarget(id: UInt64, at point: CGPoint, maxAge: TimeInterval)
        -> BackgroundTarget?
    {
        guard let element = registry.element(for: id), let pid = pid(of: element) else {
            return nil
        }
        return receivingWindow(
            id: id, element: element, pid: pid, at: point, in: windowList(maxAge: maxAge)
        ).map { BackgroundTarget(pid: pid, windowID: $0.id, origin: $0.bounds.origin) }
    }

    /// The WindowServer window behind a shared AX window (OQ-3). The match costs
    /// AX round trips, so it is kept per id and reused while that window still
    /// exists. Assumes `lock` is held.
    private func primaryWindow(
        id: UInt64, element: AXUIElement, pid: pid_t, in windows: [WindowServerWindow]
    ) -> WindowServerWindow? {
        if let known = primaryIDs[id],
            let window = windows.first(where: { $0.id == known && $0.pid == pid })
        {
            return window
        }
        let window = AXWindow(element: element, index: 0)
        let match = window.frame().flatMap {
            WindowServerWindows.match(frame: $0, title: window.title, pid: pid, in: windows)
        }
        primaryIDs[id] = match?.id
        return match
    }

    /// Assumes `lock` is held.
    private func windowList(maxAge: TimeInterval) -> [WindowServerWindow] {
        let now = ProcessInfo.processInfo.systemUptime
        if let cache = windowCache, now - cache.time <= maxAge { return cache.windows }
        let windows = WindowServerWindows.onScreen()
        windowCache = (now, windows)
        return windows
    }

    /// The pid key events for `id` go to, moving client focus there if it was
    /// elsewhere. Falls back to the last focused window for an unknown id.
    /// Assumes `lock` is held.
    private func backgroundKeyTarget(id: UInt64) -> pid_t? {
        guard let element = registry.element(for: id), let pid = pid(of: element) else {
            return focus?.pid
        }
        if focus?.id != id {
            let note = ensureBackgroundFocus(
                id: id, element: element, pid: pid, clicked: nil, in: windowList(maxAge: 0))
            trace("key focus id=\(id): background pid=\(pid)\(note)")
        }
        return pid
    }

    /// Make the app behind `id` treat itself as active and the right window as
    /// key, without raising anything or changing the real frontmost app. The
    /// window that must be key is the one `clicked`, or the shared window itself
    /// for a focus request or a key press. Returns a trace note.
    /// Assumes `lock` is held.
    private func ensureBackgroundFocus(
        id: UInt64, element: AXUIElement, pid: pid_t, clicked: WindowServerWindow?,
        in windows: [WindowServerWindow]
    ) -> String {
        if let previous = focus, previous.pid != pid {
            resignActivation(pid: previous.pid)
            keyWindowID = nil
        }
        focus = (id, pid)

        // `AXFrontmost` is the app's *own* belief about being active, which is
        // what decides whether it accepts the click. If AX will not answer, post
        // nothing extra: a second activation is not idempotent (the app sees
        // didBecomeActive again).
        guard let appActive = boolAttribute(applicationElement(pid: pid), kAXFrontmostAttribute)
        else { return " focus=unknown" }

        let primary = primaryWindow(id: id, element: element, pid: pid, in: windows)
        // A menu or popover (layer > 0) looks after its own key status.
        let keyTarget = (clicked ?? primary).flatMap { $0.layer == 0 ? $0 : nil }
        var needsKey = false
        if let keyTarget {
            if !appActive {
                needsKey = true
            } else if keyTarget.id == primary?.id {
                needsKey = boolAttribute(element, kAXMainAttribute) == false
            } else {
                // A sheet or dialog of the app: AX cannot be asked cheaply, so
                // go by what this injector last made key.
                needsKey = keyTarget.id != keyWindowID
            }
            keyWindowID = keyTarget.id
        }
        guard !appActive || needsKey else { return "" }

        var settled = true
        if !appActive {
            postAppKitDefined(.applicationActivated, pid: pid, windowID: keyTarget?.id)
            activatedPIDs.insert(pid)
            settled = waitUntilActive(pid: pid)
        }
        // Activation alone leaves no key window, and the first click on a window
        // that is not key is swallowed making it key. Spend that click here, far
        // outside the window, where it hits no view.
        if needsKey, let keyTarget {
            let target = BackgroundTarget(
                pid: pid, windowID: keyTarget.id, origin: keyTarget.bounds.origin)
            let outside = CGPoint(
                x: keyTarget.bounds.minX - Self.keyClickOffset,
                y: keyTarget.bounds.minY - Self.keyClickOffset)
            eventNumber += 1
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                postBackgroundMouse(
                    type, to: target, at: outside, flags: [], eventNumber: eventNumber,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0, button: .left)
            }
        }
        return " activated=\(!appActive)\(settled ? "" : "(unconfirmed)") madeKey=\(needsKey)"
    }

    /// Block until the app has processed the activation just posted, or a short
    /// deadline passes. Posting order is not delivery order across event kinds:
    /// measured on the Mac, mouse events posted *after* the activation were
    /// handled *before* it, so the click arrived at a still-inactive app and was
    /// swallowed. Only the app's own answer says the activation has landed.
    private func waitUntilActive(pid: pid_t) -> Bool {
        let app = applicationElement(pid: pid)
        let deadline = ProcessInfo.processInfo.systemUptime + Self.activationDeadline
        repeat {
            if boolAttribute(app, kAXFrontmostAttribute) == true { return true }
            usleep(2_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    /// Tell an app this injector marked active that it no longer is — unless the
    /// user has really brought it forward since, in which case the WindowServer
    /// owns that state and it must be left alone. Assumes `lock` is held.
    private func resignActivation(pid: pid_t) {
        guard activatedPIDs.remove(pid) != nil, !isReallyFrontmost(pid: pid),
            boolAttribute(applicationElement(pid: pid), kAXFrontmostAttribute) == true
        else { return }
        postAppKitDefined(.applicationDeactivated, pid: pid, windowID: nil)
    }

    private func isReallyFrontmost(pid: pid_t) -> Bool {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
        // NSWorkspace can lag in a process whose main run loop is not turning;
        // the WindowServer's z-order cannot.
        return WindowServerWindows.onScreen().first { $0.layer == 0 && $0.alpha > 0 }?.pid == pid
    }

    /// Post the event AppKit takes as "the WindowServer says you are (in)active".
    private func postAppKitDefined(
        _ subtype: NSEvent.EventSubtype, pid: pid_t, windowID: CGWindowID?
    ) {
        guard
            let event = NSEvent.otherEvent(
                with: .appKitDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: Int(windowID ?? 0), context: nil, subtype: subtype.rawValue,
                data1: 0, data2: 0)?.cgEvent
        else {
            trace("focus: NSEvent creation failed for pid=\(pid)")
            return
        }
        event.postToPid(pid)
    }

    private func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    /// The app element, with a short messaging timeout: a focus check must not
    /// stall the input stream behind an app that is busy.
    private func applicationElement(pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        return app
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? Bool
    }

    private func describe(_ target: BackgroundTarget, at point: CGPoint) -> String {
        " -> pid=\(target.pid) win=#\(target.windowID) "
            + "winLocal=(\(fmt(point.x - target.origin.x)),\(fmt(point.y - target.origin.y)))pt"
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
            // Compare the apps, not their pids: macOS reports pid -1 for some
            // running apps (see `LivePIDs`), which would activate on every click.
            let app = NSRunningApplication(processIdentifier: pid)
            if let app, NSWorkspace.shared.frontmostApplication != app {
                app.activate()
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
