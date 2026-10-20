import AppKit
import SwiftUI
import TransomKit

/// Owns the main window's trip to and from the menu bar.
///
/// SwiftUI's `Window` scene has no "minimize to the menu bar", so this reaches
/// the `NSWindow` underneath (via `WindowAccessor`) and:
/// - retargets its minimize button to order the window out instead of into the
///   Dock, when `HostDefaults.minimizeToMenuBar` is on;
/// - drops the Dock icon (`.accessory`) while only the menu bar icon is left,
///   and brings it back (`.regular`) when a window is shown again.
///
/// Sharing does not care: the session lives in `HostAppModel`, not the window.
@MainActor
final class MainWindowController: NSObject {
    static let shared = MainWindowController()

    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    /// SwiftUI's way to recreate a closed `Window` scene. Captured from a view
    /// that outlives the window (the menu bar label), so the Dock and
    /// `applicationShouldHandleReopen` can bring a closed window back.
    var openWindowAction: OpenWindowAction?

    private var defaults: UserDefaults { .standard }
    private var menuBarEnabled: Bool { defaults.bool(forKey: HostDefaults.showMenuBarIcon) }
    var minimizesToMenuBar: Bool { menuBarEnabled && defaults.bool(forKey: HostDefaults.minimizeToMenuBar) }
    var keepsRunningWhenClosed: Bool {
        menuBarEnabled && defaults.bool(forKey: HostDefaults.keepRunningWhenClosed)
    }

    /// True while the main window is hidden in the menu bar rather than closed.
    private(set) var isHiddenToMenuBar = false
    private var globalObservers: [NSObjectProtocol] = []

    private override init() {
        super.init()
        // Settings opened from the menu bar needs the Dock icon and menus back
        // while it is up, and closing it may leave only the menu bar again.
        let center = NotificationCenter.default
        globalObservers = [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification].map {
            name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.updateActivationPolicy() }
                }
            }
        }
    }

    /// Set at launch when the window should start in the menu bar. SwiftUI
    /// presents a `Window` scene at launch regardless before macOS 15
    /// (`defaultLaunchBehavior`), so the first window is put away on arrival.
    var startsInMenuBar = false

    func attach(_ window: NSWindow) {
        guard self.window !== window else {
            applyButtonBehaviour()
            return
        }
        self.window = window
        isHiddenToMenuBar = false
        if startsInMenuBar {
            startsInMenuBar = false
            window.orderOut(nil)
            isHiddenToMenuBar = true
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.windowDidGoAway() }
            },
            center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main) {
                _ in
                MainActor.assumeIsolated { HostAppModel.shared.previewVisible = false }
            },
            center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) {
                _ in
                MainActor.assumeIsolated { HostAppModel.shared.previewVisible = true }
            },
        ]
        applyButtonBehaviour()
        HostAppModel.shared.previewVisible = !isHiddenToMenuBar
        updateActivationPolicy()
    }

    /// Point the yellow button at the menu bar or back at the Dock.
    func applyButtonBehaviour() {
        guard let button = window?.standardWindowButton(.miniaturizeButton) else { return }
        if minimizesToMenuBar {
            button.target = self
            button.action = #selector(minimizeButtonClicked(_:))
            button.toolTip = "Hide to the menu bar"
        } else {
            button.target = window
            button.action = #selector(NSWindow.performMiniaturize(_:))
            button.toolTip = nil
        }
        updateActivationPolicy()
    }

    @objc private func minimizeButtonClicked(_ sender: Any?) {
        hideToMenuBar()
    }

    /// ⌘M. The main window goes to the menu bar when that is on; any other
    /// window (Settings) minimizes as usual.
    func minimizeKeyWindow() {
        guard let key = NSApp.keyWindow else { return }
        if key === window && minimizesToMenuBar {
            hideToMenuBar()
        } else {
            key.performMiniaturize(nil)
        }
    }

    func hideToMenuBar() {
        guard let window, menuBarEnabled else {
            window?.performMiniaturize(nil)
            return
        }
        isHiddenToMenuBar = true
        window.orderOut(nil)
        HostAppModel.shared.previewVisible = false
        updateActivationPolicy()
    }

    /// Bring the main window back, from the menu bar or wherever it went. Pass
    /// SwiftUI's `openWindow` so a window that was closed can be recreated.
    func show(openWindow: OpenWindowAction?) {
        NSApp.setActivationPolicy(.regular)
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            (openWindow ?? openWindowAction)?(id: "main")
        }
        isHiddenToMenuBar = false
        HostAppModel.shared.previewVisible = true
        NSApp.activate(ignoringOtherApps: true)
    }

    private func windowDidGoAway() {
        window = nil
        isHiddenToMenuBar = false
        HostAppModel.shared.previewVisible = false
        // Let AppKit finish closing before deciding whether a window is left.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.updateActivationPolicy() }
        }
    }

    /// No Dock icon while the menu bar icon is the only way back, if asked.
    func updateActivationPolicy() {
        let mainVisible = window?.isVisible == true || window?.isMiniaturized == true
        let otherWindows = NSApp.windows.contains { candidate in
            candidate !== window && candidate.isVisible && candidate.canBecomeMain
        }
        let accessory =
            menuBarEnabled && defaults.bool(forKey: HostDefaults.hideDockIconInMenuBar)
            && !mainVisible && !otherWindows
        let policy: NSApplication.ActivationPolicy = accessory ? .accessory : .regular
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if policy == .regular, window?.isVisible == true { NSApp.activate(ignoringOtherApps: true) }
        }
    }
}

/// Hands the hosting `NSWindow` to `MainWindowController` once SwiftUI has
/// created it.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let window = view.window { MainWindowController.shared.attach(window) }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let window = nsView.window { MainWindowController.shared.attach(window) }
            }
        }
    }
}
