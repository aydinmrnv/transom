import AppKit
import SwiftUI
import TransomKit

/// Transom Host — the macOS control panel for sharing app windows with Transom
/// Client on Windows. It is a thin product shell over `TransomKit.HostSession`:
/// setup, permissions, live status, and the stream preview stay visible while
/// the transport and capture implementation remain in the library.
///
/// The window is a thin shell over `TransomKit.HostSession`; the capture, tiling,
/// AX, and wire code is never forked into this target.
@main
struct TransomHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Transom Host", id: "main") {
            ContentView()
                .frame(minWidth: 960, minHeight: 680)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 760)

        // Standard macOS Settings window (Cmd-,). Its knobs persist in UserDefaults
        // via @AppStorage and are read back by ContentView when starting a session.
        Settings {
            HostSettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HostDefaults.migrateLegacyPorts()
        HostDefaults.repairStaleBindAddress()
        // Ensure we are a regular, focusable app even when launched oddly.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Log.app.info("Transom Host launched")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
