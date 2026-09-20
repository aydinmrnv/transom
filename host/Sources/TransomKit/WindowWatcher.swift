import ApplicationServices
import CoreGraphics
import Foundation

/// Watches one application's windows via `AXObserver` and emits lifecycle events
/// with geometry already converted to **VDS physical pixels** (issue #3 Phase 3).
///
/// This is the source of the rect stream the client consumes. It reports the
/// window's **actual** AX geometry (I-4) — the events carry what macOS says a
/// window *is*, never what anyone asked it to be.
///
/// Threading: `AXObserver` delivers its callback as a C function on whatever
/// run-loop the observer source is added to. `start()` adds it to the **current**
/// run-loop, so call it from the thread that will run that loop (the CLI spins a
/// dedicated one). `onEvent` fires on that thread; make it thread-safe.
///
/// `@unchecked Sendable` on a confinement invariant, not to hide a race: after
/// construction this object is used only from its one run-loop thread (both
/// `start()` and every `AXObserver` callback), and the shared state it touches —
/// the `WindowRegistry` — is itself lock-protected. It is `@unchecked` only so it
/// can be handed to the `Thread` that will own it.
public final class WindowWatcher: @unchecked Sendable {

    public enum WindowEvent: Sendable, Equatable {
        case created(id: UInt64, rect: WireRect, title: String)
        case moved(id: UInt64, rect: WireRect)
        case destroyed(id: UInt64)
        case titleChanged(id: UInt64, title: String)
        case focused(id: UInt64)
        case sharingFailed(message: String)
    }

    /// Called before a newly created/restored standard window enters the stream.
    /// All watchers share one run-loop, so global admission is serialized.
    public var prepareNewWindow: (@Sendable (AXUIElement) -> Bool)?
    private var seeding = false
    public var onEvent: (@Sendable (WindowEvent) -> Void)?

    private let appName: String?
    private let pid: pid_t
    private let display: DisplayInfo
    private let registry: WindowRegistry
    private let appElement: AXUIElement
    private var observer: AXObserver?

    /// Registered on the app element: these are app-wide.
    private static let appNotifications = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
    ]
    /// Registered per window element: these are about a specific window.
    private static let windowNotifications = [
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXTitleChangedNotification,
        kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
    ]

    public init(pid: pid_t, display: DisplayInfo, registry: WindowRegistry, appName: String? = nil) {
        self.appName = appName
        self.pid = pid
        self.display = display
        self.registry = registry
        self.appElement = AXWindow.application(pid: pid)
    }

    /// Create the observer, register notifications, and add it to the current
    /// run-loop. Also emits a `created` event for every window that already
    /// exists, so a caller gets the full initial state.
    public func start() throws {
        var obs: AXObserver?
        let err = AXObserverCreate(pid, windowWatchCallback, &obs)
        guard err == .success, let obs else {
            throw ProbeError("AXObserverCreate failed: \(err.rawValue)")
        }
        self.observer = obs

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.appNotifications {
            let addErr = AXObserverAddNotification(obs, appElement, name as CFString, refcon)
            if addErr != .success && addErr != .notificationAlreadyRegistered {
                Log.ax.notice(
                    "watch: could not register \(name, privacy: .public): \(addErr.rawValue)")
            }
        }

        CFRunLoopAddSource(
            CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)

        seeding = true
        defer { seeding = false }
        // Seed with the windows that already exist.
        for win in AXWindow.windows(pid: pid) where win.role == (kAXWindowRole as String) {
            registerAndAnnounce(win.element)
        }
    }

    public func stop() {
        guard let observer else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
    }

    // MARK: - Callback handling

    /// Dispatch one AX notification. Called on the run-loop thread.
    func handle(element: AXUIElement, notification: String) {
        switch notification {
        case kAXWindowCreatedNotification:
            registerAndAnnounce(element)
        case kAXFocusedWindowChangedNotification:
            let (id, isNew) = registry.id(for: element)
            if isNew { registerAndAnnounce(element, alreadyMinted: id) }
            if registry.entry(for: id) != nil { emit(.focused(id: id)) }
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            let (id, _) = registry.id(for: element)
            if let rect = rect(of: element) {
                registry.updateRect(id: id, rect: rect)
                emit(.moved(id: id, rect: rect))
            }
        case kAXTitleChangedNotification:
            let (id, _) = registry.id(for: element)
            let title = displayTitle(AXWindow(element: element, index: -1).title)
            registry.updateTitle(id: id, title: title)
            emit(.titleChanged(id: id, title: title))
        case kAXWindowDeminiaturizedNotification:
            registerAndAnnounce(element)
        case kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification:
            if let id = registry.remove(element: element) {
                emit(.destroyed(id: id))
            }
        default:
            break
        }
    }

    /// Mint an id (if needed), register per-window notifications, record initial
    /// geometry, and emit `created`.
    private func registerAndAnnounce(_ element: AXUIElement, alreadyMinted: UInt64? = nil) {
        let id = alreadyMinted ?? registry.id(for: element).id
        if let observer {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for name in Self.windowNotifications {
                let addErr = AXObserverAddNotification(observer, element, name as CFString, refcon)
                if addErr != .success && addErr != .notificationAlreadyRegistered {
                    Log.ax.notice(
                        "watch: window \(name, privacy: .public) reg failed: \(addErr.rawValue)")
                }
            }
        }
        let win = AXWindow(element: element, index: -1)
        guard !win.isMinimized else { return }
        if !seeding && registry.entry(for: id) == nil && win.subrole == (kAXStandardWindowSubrole as String) {
            guard prepareNewWindow?(element) ?? true else {
                _ = registry.remove(element: element)
                return
            }
        }
        let title = displayTitle(win.title)
        let r = rect(of: element) ?? WireRect(x: 0, y: 0, w: 0, h: 0)
        registry.record(id: id, rect: r, title: title)
        emit(.created(id: id, rect: r, title: title))
    }

    /// The window's actual AX frame converted to VDS physical pixels (I-3),
    /// clamped to the unsigned wire range.
    private func rect(of element: AXUIElement) -> WireRect? {
        guard let frame = AXWindow(element: element, index: -1).frame() else { return nil }
        let vds = Coordinates.displayPixels(
            fromAXRect: frame, displayOriginPoints: display.originPoints, scale: display.scale)
        return WireRect(clampingVDSPixels: vds)
    }

    private func displayTitle(_ title: String) -> String {
        guard let appName, !appName.isEmpty else { return title }
        return title.isEmpty || title == appName ? appName : "\(appName) — \(title)"
    }

    private func emit(_ event: WindowEvent) {
        onEvent?(event)
    }
}

extension WireRect {
    /// Clamp a VDS-pixel rect (which may have off-display negatives) into the
    /// unsigned wire range. A window nudged above/left of the display origin gets
    /// pinned to 0 rather than wrapping to a huge `u32`.
    public init(clampingVDSPixels r: CGRect) {
        func u32(_ v: CGFloat) -> UInt32 {
            guard v > 0 else { return 0 }
            return UInt32(min(v.rounded(), CGFloat(UInt32.max)))
        }
        self.init(
            x: u32(r.origin.x), y: u32(r.origin.y), w: u32(r.size.width), h: u32(r.size.height))
    }
}

/// C trampoline: cannot capture context, so `refcon` carries the `WindowWatcher`.
private func windowWatchCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let watcher = Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.handle(element: element, notification: notification as String)
}
