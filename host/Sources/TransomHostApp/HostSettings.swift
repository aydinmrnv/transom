import ServiceManagement
import SwiftUI
import TransomKit

/// The `UserDefaults` keys the host control panel persists its settings under.
///
/// One list, referenced by both the main window (which reads them at Start to
/// build the `HostConfig`) and the Settings window (which edits them). Keeping the
/// literals here means the two views can never drift onto different keys — the bug
/// that silently splits a setting into two.
enum HostDefaults {
    static let automaticAddress = "host.automaticAddress"
    static let bindAddress = "host.bindAddress"
    static let controlPort = "host.controlPort"
    static let videoPort = "host.videoPort"
    static let bitrateMbps = "host.bitrateMbps"
    static let fps = "host.fps"
    static let gutter = "host.gutter"
    static let video = "host.video"
    static let chroma = "host.chroma"
    static let namesakeModifiers = "host.namesakeModifiers"
    static let logInput = "host.logInput"
    static let foregroundInput = "host.foregroundInput"
    static let previewOutlines = "host.previewOutlines"
    static let previewLabels = "host.previewLabels"
    static let restoreWindows = "host.restoreWindows"
    static let showAccessoryApps = "host.showAccessoryApps"
    /// Newline-separated bundle ids of the apps chosen for sharing.
    static let sharedApps = "sharedAppBundleIDs"

    // App behaviour: the menu bar, the Dock icon, launch.
    static let showMenuBarIcon = "app.showMenuBarIcon"
    static let minimizeToMenuBar = "app.minimizeToMenuBar"
    static let keepRunningWhenClosed = "app.keepRunningWhenClosed"
    static let hideDockIconInMenuBar = "app.hideDockIconInMenuBar"
    static let openWindowOnLaunch = "app.openWindowOnLaunch"
    static let startSharingOnLaunch = "app.startSharingOnLaunch"
    static let confirmQuitWhileSharing = "app.confirmQuitWhileSharing"

    // Appearance. See `Appearance.swift`.
    static let accentColor = "appearance.accentColor"
    static let theme = "appearance.theme"
    static let cardSize = "appearance.cardSize"
    static let menuBarSymbol = "appearance.menuBarSymbol"
    static let menuBarShowsCount = "appearance.menuBarShowsCount"
    static let showSidebar = "appearance.showSidebar"
    static let tintSidebar = "appearance.tintSidebar"
    static let showThumbnails = "appearance.showThumbnails"

    static let defaultBitrateMbps = 40
    static let defaultFPS = 60

    /// The one place defaults live. Registered at launch, so `UserDefaults`
    /// reads in the model and `@AppStorage` in the views agree on an unset key.
    static func register() {
        UserDefaults.standard.register(defaults: [
            automaticAddress: true,
            bindAddress: "127.0.0.1",
            controlPort: defaultControlPort,
            videoPort: defaultVideoPort,
            bitrateMbps: defaultBitrateMbps,
            fps: defaultFPS,
            gutter: Tiler.defaultGutter,
            video: true,
            chroma: HEVCEncoder.Format.hevc420_8bit.rawValue,
            namesakeModifiers: false,
            logInput: false,
            foregroundInput: false,
            previewOutlines: true,
            previewLabels: true,
            restoreWindows: true,
            showAccessoryApps: true,
            showMenuBarIcon: true,
            minimizeToMenuBar: true,
            keepRunningWhenClosed: true,
            hideDockIconInMenuBar: true,
            openWindowOnLaunch: true,
            startSharingOnLaunch: false,
            confirmQuitWhileSharing: true,
            accentColor: AccentChoice.defaultID,
            theme: AppTheme.system.rawValue,
            cardSize: CardSize.regular.rawValue,
            menuBarSymbol: MenuBarSymbol.defaultSymbol,
            menuBarShowsCount: true,
            showSidebar: true,
            tintSidebar: false,
            showThumbnails: true,
        ])
    }

    /// Valid TCP port range. Start is gated on both ports falling inside it so a
    /// value never gets silently clamped into a different endpoint at serve time.
    static let portRange = 1...65535
    static let defaultControlPort = Int(TransomPorts.control)
    static let defaultVideoPort = Int(TransomPorts.video)

    /// Upgrade the old prototype defaults once. Existing custom port choices
    /// are preserved; only the untouched 7000/7001 pair is migrated.
    static func migrateLegacyPorts() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: automaticAddress) == nil,
            defaults.object(forKey: bindAddress) != nil {
            defaults.set(false, forKey: automaticAddress)
        }
        guard defaults.bool(forKey: "host.portDefaultsMigrated") == false else { return }
        let oldControl = defaults.object(forKey: controlPort) as? Int ?? 7000
        let oldVideo = defaults.object(forKey: videoPort) as? Int ?? 7001
        if oldControl == 7000 && oldVideo == 7001 {
            defaults.set(defaultControlPort, forKey: controlPort)
            defaults.set(defaultVideoPort, forKey: videoPort)
        }
        defaults.set(true, forKey: "host.portDefaultsMigrated")
    }

    /// Exact-interface binding is safer than 0.0.0.0, but it means a DHCP or
    /// VPN change can leave a previously valid address unusable. Repair only a
    /// stale private address; keep an invalid/public value visible so the user
    /// can correct the security setting instead of silently changing intent.
    static func repairStaleBindAddress() {
        let defaults = UserDefaults.standard
        guard let saved = defaults.string(forKey: bindAddress),
            PrivateAddress.isPrivateIPv4(saved),
            !saved.hasPrefix("127."),
            !HostDiscovery.localAddresses().contains(saved),
            let replacement = HostDiscovery.localAddresses().first
        else { return }
        defaults.set(replacement, forKey: bindAddress)
    }
}

/// The standard macOS Settings window (Cmd-,). Every control binds to a
/// `HostDefaults` key via `@AppStorage`, so edits persist and the main window
/// picks them up — connection/video/layout changes at the next Start, preview
/// toggles live. This is where the knobs that used to crowd the main window now
/// live, leaving the main window to the act of *starting a session*.
struct HostSettingsView: View {
    @AppStorage(HostDefaults.accentColor) private var accentID = AccentChoice.defaultID

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            ConnectionSettings()
                .tabItem { Label("Connection", systemImage: "network") }
            VideoSettings()
                .tabItem { Label("Video", systemImage: "video") }
            LayoutSettings()
                .tabItem { Label("Windows", systemImage: "rectangle.3.group") }
            InputSettings()
                .tabItem { Label("Input", systemImage: "keyboard") }
        }
        .frame(width: 520, height: 500)
        .tint(AccentChoice.color(for: accentID))
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(HostDefaults.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(HostDefaults.minimizeToMenuBar) private var minimizeToMenuBar = true
    @AppStorage(HostDefaults.keepRunningWhenClosed) private var keepRunningWhenClosed = true
    @AppStorage(HostDefaults.hideDockIconInMenuBar) private var hideDockIcon = true
    @AppStorage(HostDefaults.openWindowOnLaunch) private var openWindowOnLaunch = true
    @AppStorage(HostDefaults.startSharingOnLaunch) private var startSharingOnLaunch = false
    @AppStorage(HostDefaults.confirmQuitWhileSharing) private var confirmQuit = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("Menu bar") {
                Toggle("Show Transom in the menu bar", isOn: $showMenuBarIcon)
                Group {
                    Toggle("Minimize the window to the menu bar", isOn: $minimizeToMenuBar)
                    Toggle("Keep running in the menu bar when the window is closed", isOn: $keepRunningWhenClosed)
                    Toggle("Hide the Dock icon while only in the menu bar", isOn: $hideDockIcon)
                }
                .disabled(!showMenuBarIcon)
                Text(
                    "The menu bar icon starts and stops sharing and shows what your PC can see, "
                        + "so the window can stay out of the way."
                )
                .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Launch") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if loginItemStatus == .requiresApproval {
                    HStack {
                        Text("Approve Transom Host in Login Items to finish.")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Show the window at launch", isOn: $openWindowOnLaunch)
                    .disabled(!showMenuBarIcon)
                Toggle("Start sharing the chosen apps at launch", isOn: $startSharingOnLaunch)
                Text(
                    "Starts as soon as the apps you last chose are running and permissions and "
                        + "the network are ready."
                )
                .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Quit") {
                Toggle("Ask before quitting while sharing", isOn: $confirmQuit)
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItemStatus = SMAppService.mainApp.status }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        loginItemError = nil
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            loginItemError = "Could not change the login item: \(error.localizedDescription)"
        }
        loginItemStatus = service.status
        let effective = service.status == .enabled || service.status == .requiresApproval
        if effective != enabled { launchAtLogin = effective }
    }
}

// MARK: - Connection

private struct ConnectionSettings: View {
    @AppStorage(HostDefaults.bindAddress) private var bindAddress = "127.0.0.1"
    @AppStorage(HostDefaults.automaticAddress) private var automaticAddress = true
    @AppStorage(HostDefaults.controlPort) private var controlPort = HostDefaults.defaultControlPort
    @AppStorage(HostDefaults.videoPort) private var videoPort = HostDefaults.defaultVideoPort

    private var effectiveAddress: String { automaticAddress ? (HostDiscovery.localAddresses().first ?? "") : bindAddress }
    private var isPrivate: Bool { PrivateAddress.isPrivateIPv4(effectiveAddress) }
    private func portValid(_ p: Int) -> Bool { HostDefaults.portRange.contains(p) }

    var body: some View {
        Form {
            Section("Bind") {
                Toggle("Choose a LAN address automatically", isOn: $automaticAddress)
                if automaticAddress {
                    Text(effectiveAddress.isEmpty ? "No active private network. Connect to Ethernet or Wi-Fi." : "Sharing on \(effectiveAddress)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("Address", text: $bindAddress)
                }
                TextField("Control port", value: $controlPort, format: .number.grouping(.never))
                TextField("Video port", value: $videoPort, format: .number.grouping(.never))
                if !portValid(controlPort) || !portValid(videoPort) {
                    Label(
                        "Ports must be between 1 and 65535 — Start is refused until they are.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if controlPort == videoPort, portValid(controlPort) {
                    Label(
                        "Control and video ports must be different.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption).foregroundStyle(.red)
                }
            }
            Section {
                Label {
                    Text(
                        isPrivate
                            ? "Private address — allowed (no auth or encryption; LAN only)."
                            : "Not a private address — Start is refused. Use 127/8, 10/8, "
                                + "172.16/12, 192.168/16, or 169.254/16."
                    )
                    .font(.caption)
                    .foregroundStyle(isPrivate ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: isPrivate ? "network" : "exclamationmark.triangle.fill")
                        .foregroundStyle(isPrivate ? .green : .red)
                }
                Text("Connection changes apply the next time you press Start.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Video

private struct VideoSettings: View {
    @AppStorage(HostDefaults.video) private var videoEnabled = true
    @AppStorage(HostDefaults.chroma) private var chroma = HEVCEncoder.Format.hevc420_8bit.rawValue
    @AppStorage(HostDefaults.fps) private var fps = HostDefaults.defaultFPS
    @AppStorage(HostDefaults.bitrateMbps) private var bitrateMbps = HostDefaults.defaultBitrateMbps

    var body: some View {
        Form {
            Section {
                Toggle("Stream video", isOn: $videoEnabled)
                Text(
                    "Off streams the control channel only — window geometry and input, no pixels "
                        + "and no encoder."
                )
                .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Encoder") {
                Picker("Chroma", selection: $chroma) {
                    Text("4:2:0 8-bit — decodable everywhere")
                        .tag(HEVCEncoder.Format.hevc420_8bit.rawValue)
                    Text("4:4:4 10-bit — crisp text")
                        .tag(HEVCEncoder.Format.hevc444_10bit.rawValue)
                }
                Text(
                    "4:2:0 is what the Windows in-box decoder can show. 4:4:4 is crisper but needs "
                        + "a 4:4:4-capable client decoder (protocol.md §6-7)."
                )
                .font(.caption2).foregroundStyle(.secondary)
                Picker("Frame rate", selection: $fps) {
                    ForEach([30, 60, 120], id: \.self) { Text("\($0) fps").tag($0) }
                }
                TextField("Bitrate (Mbps)", value: $bitrateMbps, format: .number.grouping(.never))
            }
            .disabled(!videoEnabled)
            Section {
                Text("Video changes apply the next time you press Start.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Layout

private struct LayoutSettings: View {
    @AppStorage(HostDefaults.gutter) private var gutter = Tiler.defaultGutter
    @AppStorage(HostDefaults.previewOutlines) private var previewOutlines = true
    @AppStorage(HostDefaults.previewLabels) private var previewLabels = true
    @AppStorage(HostDefaults.restoreWindows) private var restoreWindows = true
    @AppStorage(HostDefaults.showAccessoryApps) private var showAccessoryApps = true

    var body: some View {
        Form {
            Section("Which windows") {
                Toggle("Bring hidden, minimized and full-screen windows to the display", isOn: $restoreWindows)
                Text(
                    "When sharing starts, hidden apps are shown and their minimized and full-screen "
                        + "windows are restored, so every window of a chosen app reaches your PC. "
                        + "Off shares only windows already on the display."
                )
                .font(.caption2).foregroundStyle(.secondary)
                Toggle("List menu bar apps that have a window open", isOn: $showAccessoryApps)
                Text("Utilities that live in the menu bar can be shared while one of their windows is open.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Tiling") {
                TextField("Gutter (px)", value: $gutter, format: .number.grouping(.never))
                Text(
                    "Space left between tiled windows, so menus and popovers that overhang a window "
                        + "do not land on its neighbour. A smaller gutter fits more windows; any that "
                        + "do not fit are minimized and listed. Applies at the next Start."
                )
                .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Stream preview") {
                Toggle("Outline tracked windows", isOn: $previewOutlines)
                Toggle("Show window labels", isOn: $previewLabels)
                Text("These apply live to the preview panel.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Input

private struct InputSettings: View {
    @AppStorage(HostDefaults.namesakeModifiers) private var namesakeModifiers = false
    @AppStorage(HostDefaults.logInput) private var logInput = false
    @AppStorage(HostDefaults.foregroundInput) private var foregroundInput = false

    var body: some View {
        Form {
            Section("Delivery") {
                Picker("Client input goes to", selection: $foregroundInput) {
                    Text("The shared window, in the background (default)").tag(false)
                    Text("The frontmost window, after raising it").tag(true)
                }
                .pickerStyle(.radioGroup)
                Text(
                    "In the background, clicks and keys reach the shared window even when "
                        + "another window is on top of it: nothing is raised and this Mac's "
                        + "cursor does not move, so you can keep working here. Raising "
                        + "behaves like a person at the Mac and takes the cursor and focus. "
                        + "Applies at the next Start."
                )
                .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Modifier mapping") {
                Picker("Windows Ctrl maps to", selection: $namesakeModifiers) {
                    Text("⌘ Command (swap — default)").tag(false)
                    Text("⌃ Control (namesake)").tag(true)
                }
                .pickerStyle(.radioGroup)
                Text(
                    "The Cmd-vs-Ctrl decision for injected input (issue #7). Swap makes Windows "
                        + "Ctrl-C act as ⌘C on the Mac; namesake keeps it as Control."
                )
                .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                Toggle("Log the full coordinate/keycode chain per event", isOn: $logInput)
                Text("Verbose — for debugging input translation. Applies at the next Start.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
