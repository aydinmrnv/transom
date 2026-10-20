import CoreGraphics
import Foundation

/// One WindowServer window as `CGWindowListCopyWindowInfo` reports it.
///
/// `bounds` is in **CoreGraphics global space**: points, top-left origin of the
/// main display, Y down — the same space as AX frames (I-3), so the two compare
/// directly with no conversion.
public struct WindowServerWindow: Sendable, Equatable {
    public let id: CGWindowID
    public let pid: pid_t
    /// `kCGWindowLayer`: 0 for normal windows, >0 for menus, popovers, panels.
    public let layer: Int
    public let bounds: CGRect
    public let alpha: Double
    /// `kCGWindowName`. Only present with Screen Recording permission.
    public let title: String?

    public init(
        id: CGWindowID, pid: pid_t, layer: Int, bounds: CGRect, alpha: Double = 1,
        title: String? = nil
    ) {
        self.id = id
        self.pid = pid
        self.layer = layer
        self.bounds = bounds
        self.alpha = alpha
        self.title = title
    }
}

/// Which WindowServer window a background input event must be addressed to
/// (`InputDelivery.background`).
///
/// An event posted to a pid is not hit-tested by the WindowServer, so the host
/// has to name the receiving window itself. Hit-testing only the **target app's**
/// windows is the input mirror of the app-filtered capture: a window from some
/// other app lying on top is invisible to both the stream and the click.
///
/// The selection logic is pure (a list in, a window out) so it is unit-tested with
/// no Mac; only `onScreen()` touches the WindowServer.
public enum WindowServerWindows {

    /// Every on-screen window, **front to back**.
    public static func onScreen() -> [WindowServerWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return raw.compactMap { info in
            guard
                let id = info[kCGWindowNumber as String] as? CGWindowID,
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            return WindowServerWindow(
                id: id, pid: pid,
                layer: info[kCGWindowLayer as String] as? Int ?? 0,
                bounds: bounds,
                alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                title: info[kCGWindowName as String] as? String)
        }
    }

    /// The frontmost visible window owned by `pid` that contains `point`.
    ///
    /// Any layer counts: an open `NSMenu`, popover or sheet is a separate window
    /// of the same app sitting above the shared one, and a click on it must be
    /// addressed to *it* or the app treats the click as "outside" and dismisses
    /// the menu.
    public static func topmost(
        at point: CGPoint, pid: pid_t, in windows: [WindowServerWindow]
    ) -> WindowServerWindow? {
        windows.first { $0.pid == pid && $0.alpha > 0 && $0.bounds.contains(point) }
    }

    /// The WindowServer window behind an AX window, matched by owner and frame.
    ///
    /// There is no public AX → `CGWindowID` call (OQ-3; `_AXUIElementGetWindow`
    /// is private), so this matches the AX frame against the normal-layer windows
    /// of the same pid. A title match breaks a tie between identically-framed
    /// windows; otherwise the frontmost wins. Under I-5 two shared windows never
    /// share a frame, so the tie only arises with an app's own overlay windows.
    public static func match(
        frame: CGRect, title: String?, pid: pid_t, in windows: [WindowServerWindow],
        tolerance: CGFloat = 1
    ) -> WindowServerWindow? {
        let candidates = windows.filter {
            $0.pid == pid && $0.layer == 0
                && abs($0.bounds.minX - frame.minX) <= tolerance
                && abs($0.bounds.minY - frame.minY) <= tolerance
                && abs($0.bounds.width - frame.width) <= tolerance
                && abs($0.bounds.height - frame.height) <= tolerance
        }
        if candidates.count > 1, let title, !title.isEmpty,
            let titled = candidates.first(where: { $0.title == title })
        {
            return titled
        }
        return candidates.first
    }
}

/// Counts consecutive clicks so a background mouse event can carry the
/// `clickCount` AppKit expects (a double-click is two downs with counts 1, 2).
/// The WindowServer does this for real HID input; an event posted to a pid has to
/// bring its own.
public struct ClickCounter: Sendable {

    private struct Last: Sendable {
        var button: MouseButton
        var windowID: CGWindowID
        var point: CGPoint
        var time: TimeInterval
        var count: Int
    }

    /// How far (points) a click may drift and still extend a multi-click.
    public static let slop: CGFloat = 4

    private var last: Last?

    public init() {}

    /// Register a mouse-down and return its click count (1, 2, 3, …).
    public mutating func down(
        button: MouseButton, windowID: CGWindowID, at point: CGPoint, time: TimeInterval,
        interval: TimeInterval
    ) -> Int {
        var count = 1
        if let last, last.button == button, last.windowID == windowID,
            time - last.time <= interval,
            abs(point.x - last.point.x) <= Self.slop, abs(point.y - last.point.y) <= Self.slop
        {
            count = last.count + 1
        }
        last = Last(button: button, windowID: windowID, point: point, time: time, count: count)
        return count
    }
}
