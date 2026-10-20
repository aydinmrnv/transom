import AppKit
import SwiftUI
import TransomKit

/// Transom Host — the macOS control panel for sharing app windows with Transom
/// Client on Windows. It is a thin product shell over `TransomKit.HostSession`:
/// setup, permissions, live status, and the stream preview stay visible while
/// the transport and capture implementation remain in the library.
///
/// It can live in the menu bar: the icon starts and stops sharing, and the main
/// window minimizes or closes into it (`MainWindowController`).
///
/// The window is a thin shell over `TransomKit.HostSession`; the capture, tiling,
/// AX, and wire code is never forked into this target.
@main
struct TransomHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var host = HostAppModel.shared
    @AppStorage(HostDefaults.showMenuBarIcon) private var showMenuBarIcon = true

    init() {
        HostDefaults.register()
    }

    /// `MenuBarExtra` writes `isInserted` back on every scene update. Straight
    /// into `@AppStorage`, each write posts a defaults change that re-runs this
    /// body, which writes again: a main-thread loop. Only real changes go through.
    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { showMenuBarIcon },
            set: { inserted in
                if inserted != showMenuBarIcon { showMenuBarIcon = inserted }
            })
    }

    var body: some Scene {
        Window("Transom Host", id: "main") {
            ContentView(host: host)
                .frame(minWidth: 960, minHeight: 680)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandMenu("Sharing") {
                Button("Start Sharing") { host.startSharing() }
                    .keyboardShortcut("s", modifiers: [.command, .option, .shift])
                    .disabled(!host.canStart)
                Button("Stop Sharing") { host.stop() }
                    .keyboardShortcut("d", modifiers: [.command, .option, .shift])
                    .disabled(!host.running)
            }
            CommandGroup(replacing: .windowSize) {
                Button("Minimize") { MainWindowController.shared.minimizeKeyWindow() }
                    .keyboardShortcut("m")
                Button("Zoom") { NSApp.keyWindow?.zoom(nil) }
                if showMenuBarIcon {
                    Button("Hide to Menu Bar") { MainWindowController.shared.hideToMenuBar() }
                        .keyboardShortcut("m", modifiers: [.command, .control])
                }
            }
        }

        // Standard macOS Settings window (Cmd-,). Its knobs persist in UserDefaults
        // via @AppStorage and are read back by the model when starting a session.
        Settings {
            HostSettingsView()
        }

        MenuBarExtra(isInserted: menuBarInserted) {
            MenuBarPanel(host: host)
        } label: {
            MenuBarLabel(host: host)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Launch straight into the menu bar when asked to (useful with Open at
    /// login). Without a menu bar icon there would be no way in, so the window
    /// always opens then.
    static var opensWindowAtLaunch: Bool {
        let d = UserDefaults.standard
        return !d.bool(forKey: HostDefaults.showMenuBarIcon) || d.bool(forKey: HostDefaults.openWindowOnLaunch)
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        HostDefaults.register()
        HostDefaults.migrateLegacyPorts()
        HostDefaults.repairStaleBindAddress()
        AppTheme.apply(UserDefaults.standard.string(forKey: HostDefaults.theme) ?? "")
        if Self.opensWindowAtLaunch {
            // Ensure we are a regular, focusable app even when launched oddly.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            HostAppModel.shared.previewVisible = false
            MainWindowController.shared.startsInMenuBar = true
            NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
                .map(MainWindowController.shared.attach)
        }
        HostAppModel.shared.activate()
        HostAppModel.shared.scheduleAutoStart()
        Log.app.info("Transom Host launched")
    }

    @MainActor
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // A window hidden in the menu bar was put away, not closed: closing
        // Settings meanwhile must not quit the app out from under it.
        let controller = MainWindowController.shared
        return !controller.keepsRunningWhenClosed && !controller.isHiddenToMenuBar
    }

    /// Clicking the Dock icon with no window open brings the window back.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindowController.shared.show(openWindow: nil) }
        return !flag
    }

    /// Stop sharing cleanly before quitting, after asking if that is wanted.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let host = HostAppModel.shared
        guard host.running || host.starting else { return .terminateNow }
        if UserDefaults.standard.bool(forKey: HostDefaults.confirmQuitWhileSharing) {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Stop sharing and quit?"
            alert.informativeText =
                "Your PC loses its Transom windows. The apps keep running on this Mac."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don’t ask again"
            let response = alert.runModal()
            if alert.suppressionButton?.state == .on {
                UserDefaults.standard.set(false, forKey: HostDefaults.confirmQuitWhileSharing)
            }
            guard response == .alertFirstButtonReturn else { return .terminateCancel }
        }
        Task { @MainActor in
            await host.stopAndWait()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
