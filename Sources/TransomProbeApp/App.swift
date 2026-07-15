import AppKit
import SwiftUI
import TransomKit

/// Transom Probe — the diagnostic app (issue Part 2).
///
/// This is **not** the product. It is a one-window instrument whose whole job is
/// to answer OQ-1 visually: open Xcode's Product menu and *see*, live, whether
/// the menu lands in the ScreenCaptureKit capture and whether AX puts a rect
/// around it. It exists as a bundle (not just the CLI) for two reasons: a stable
/// bundle id gets its own TCC identity, and a live view answers a visual
/// question in seconds where PNG dumps are slow and ambiguous.
@main
struct TransomProbeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Transom Probe", id: "main") {
            ContentView()
                .frame(minWidth: 900, minHeight: 640)
        }
        .windowResizability(.contentMinSize)

        // Standard macOS Settings window (Cmd-,).
        Settings {
            SettingsView()
        }
    }
}

/// The Settings window (Cmd-,). Values persist in UserDefaults via @AppStorage
/// and are read back by ContentView when starting the probe.
struct SettingsView: View {
    @AppStorage(ProbeSettings.storageKeys.fps) private var fps = 60
    @AppStorage(ProbeSettings.storageKeys.pollHz) private var pollHz = 10
    @AppStorage(ProbeSettings.storageKeys.showWindowRects) private var showWindowRects = true
    @AppStorage(ProbeSettings.storageKeys.showMenuRects) private var showMenuRects = true
    @AppStorage(ProbeSettings.storageKeys.showLabels) private var showLabels = true

    var body: some View {
        Form {
            Section("Capture") {
                Picker("Capture frame rate", selection: $fps) {
                    ForEach([15, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("AX overlay poll rate", selection: $pollHz) {
                    ForEach([5, 10, 20, 30], id: \.self) { Text("\($0) Hz").tag($0) }
                }
                Text("Frame rate and poll rate apply the next time you press Start.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Overlay") {
                Toggle("Outline app windows", isOn: $showWindowRects)
                Toggle("Outline open menus / popovers (orange)", isOn: $showMenuRects)
                Toggle("Show role/subrole labels", isOn: $showLabels)
                Text("Overlay toggles apply live while the probe is running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 340)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure we are a regular, focusable app even when launched oddly.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Log.app.info("Transom Probe launched")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
