import ApplicationServices
import Foundation

/// Brings the shared apps' windows onto the sharing display before the session
/// tiles them.
///
/// AX lists three kinds of window that are not drawn on the display: those of a
/// hidden app (⌘H), minimized ones, and full-screen ones (which live in their own
/// Space). The tiler and the watcher skip them, so before this, sharing an app in
/// one of those states produced no windows on the PC, or a blank crop for a
/// hidden app (architecture.md §8). Choosing an app in the host app is the
/// request to see it, so the session shows it first.
///
/// This activates what it restores, so it runs only at session start, when the
/// person at the Mac has just pressed Start. Mid-session, a window that is hidden
/// or minimized on the Mac leaves the stream instead (`WindowWatcher`).
public enum WindowRestorer {

    public struct Report: Sendable, Equatable {
        public var unhiddenApps = 0
        public var restoredWindows = 0
        public var exitedFullScreen = 0
        /// Still hidden, minimized or full-screen when the wait ran out.
        public var unsettled = 0

        public init() {}

        public var isEmpty: Bool {
            unhiddenApps == 0 && restoredWindows == 0 && exitedFullScreen == 0 && unsettled == 0
        }

        /// One line for the UI and the `serve` log, or nil when nothing happened.
        public var summary: String? {
            var parts: [String] = []
            if unhiddenApps > 0 { parts.append("showed \(Self.count(unhiddenApps, "hidden app"))") }
            if restoredWindows > 0 {
                parts.append("restored \(Self.count(restoredWindows, "minimized window"))")
            }
            if exitedFullScreen > 0 {
                parts.append("took \(Self.count(exitedFullScreen, "window")) out of full screen")
            }
            var line = parts.isEmpty ? nil : "Before sharing, " + parts.joined(separator: ", ") + "."
            if unsettled > 0 {
                let note = "\(Self.count(unsettled, "window")) could not be brought onto the display and will not be shared."
                line = line.map { "\($0) \(note)" } ?? note
            }
            return line
        }

        private static func count(_ n: Int, _ noun: String) -> String {
            "\(n) \(noun)\(n == 1 ? "" : "s")"
        }
    }

    /// Unhide, un-minimize and leave full screen for every window of `pids`, then
    /// wait (up to `timeout`) for macOS to finish, plus a short settle so the
    /// tiler does not write geometry into a window that is still animating.
    public static func restore(pids: [pid_t], timeout: Duration = .seconds(3)) async -> Report {
        var report = Report()
        for pid in pids {
            if AXWindow.isApplicationHidden(pid: pid),
                AXWindow.setApplicationHidden(pid: pid, false) == .success
            {
                report.unhiddenApps += 1
            }
            for win in AXWindow.windows(pid: pid) where win.role == (kAXWindowRole as String) {
                if win.isFullScreen {
                    if win.setFullScreen(false) == .success { report.exitedFullScreen += 1 }
                } else if win.isMinimized {
                    if win.setMinimized(false) == .success { report.restoredWindows += 1 }
                }
            }
        }
        guard !report.isEmpty else { return report }
        Log.ax.notice(
            "restore: unhid \(report.unhiddenApps) app(s), restored \(report.restoredWindows), exited full screen \(report.exitedFullScreen)"
        )

        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if pending(pids: pids) == 0 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // The un-minimize and full-screen exit animations outlast the AX state
        // change; a geometry write that lands mid-animation can be overwritten.
        try? await Task.sleep(for: .milliseconds(report.exitedFullScreen > 0 ? 900 : 400))
        report.unsettled = pending(pids: pids)
        return report
    }

    /// Windows of `pids` still not on the display.
    private static func pending(pids: [pid_t]) -> Int {
        pids.reduce(0) { total, pid in
            let hidden = AXWindow.isApplicationHidden(pid: pid)
            return total
                + AXWindow.windows(pid: pid).filter { win in
                    win.role == (kAXWindowRole as String)
                        && (hidden || win.isMinimized || win.isFullScreen)
                }.count
        }
    }
}
