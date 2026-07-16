import AppKit
import SwiftUI
import TransomKit

/// Transom Host — the control panel for the host half (issue #8).
///
/// This is **not** product UI. It is a one-window instrument to launch what the
/// `serve` CLI launches: point it at a display and an app, press Start, and watch
/// permissions, the tile layout, and the live encoder/stream status. It exists as
/// a bundle (not just the CLI) for two reasons the issue spells out: a stable
/// bundle id gets its **own** TCC identity (`one.nullstack.transom.host`, distinct
/// from the probe), and a headless host is a bad fit for a terminal session.
///
/// The window is a thin shell over `TransomKit.HostSession`; the capture, tiling,
/// AX, and wire code is never forked into this target.
@main
struct TransomHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Transom Host", id: "main") {
            ContentView()
                .frame(minWidth: 760, minHeight: 640)
        }
        .windowResizability(.contentMinSize)

        // Standard macOS Settings window (Cmd-,). Its knobs persist in UserDefaults
        // via @AppStorage and are read back by ContentView when starting a session.
        Settings {
            HostSettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure we are a regular, focusable app even when launched oddly.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Log.app.info("Transom Host launched")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
