import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI
import TransomKit

struct ContentView: View {
    @ObservedObject var host: HostAppModel
    @State private var search = ""
    @AppStorage(HostDefaults.controlPort) private var controlPort = HostDefaults.defaultControlPort
    @AppStorage(HostDefaults.videoPort) private var videoPort = HostDefaults.defaultVideoPort
    @AppStorage(HostDefaults.video) private var videoEnabled = true
    @AppStorage(HostDefaults.automaticAddress) private var automaticAddress = true
    @AppStorage(HostDefaults.bindAddress) private var bindAddress = "127.0.0.1"
    @AppStorage(HostDefaults.showAccessoryApps) private var showAccessoryApps = true
    @AppStorage(HostDefaults.restoreWindows) private var restoreWindows = true
    @AppStorage(HostDefaults.accentColor) private var accentID = AccentChoice.defaultID
    @AppStorage(HostDefaults.cardSize) private var cardSizeRaw = CardSize.regular.rawValue
    @AppStorage(HostDefaults.showSidebar) private var showSidebar = true
    @AppStorage(HostDefaults.tintSidebar) private var tintSidebar = false
    @AppStorage(HostDefaults.showThumbnails) private var showThumbnails = true
    @AppStorage(HostDefaults.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(HostDefaults.minimizeToMenuBar) private var minimizeToMenuBar = true
    @Environment(\.openWindow) private var openWindow

    private var accent: Color { AccentChoice.color(for: accentID) }
    private var cardSize: CardSize { CardSize(rawValue: cardSizeRaw) ?? .regular }

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                sidebar
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if !host.permissionsReady { permissionSetup }
                    if let error = host.startError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if host.running { sharedWindows } else { appSelection }
                    connectionHelp
                    diagnostics
                }
                .padding(32)
                .frame(maxWidth: 1120, alignment: .leading)
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .tint(accent)
        .background(WindowAccessor())
        .onAppear {
            host.refreshAll()
            host.previewVisible = true
            MainWindowController.shared.openWindowAction = openWindow
        }
        .onChange(of: showAccessoryApps) { _, _ in host.refreshApps() }
        .onChange(of: minimizeToMenuBar) { _, _ in MainWindowController.shared.applyButtonBehaviour() }
        .onChange(of: showMenuBarIcon) { _, _ in MainWindowController.shared.applyButtonBehaviour() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label("Transom", systemImage: "rectangle.on.rectangle")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 6) {
                Text(HostDiscovery.computerName).font(.headline)
                Text("Mac host").font(.callout).foregroundStyle(.secondary)
            }
            Label(host.running ? "Sharing windows" : "Not sharing",
                systemImage: host.running ? "circle.inset.filled" : "circle")
                .foregroundStyle(host.running ? .green : .secondary)
                .font(.callout)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Label(host.accessibility ? "Control ready" : "Control permission needed",
                    systemImage: host.accessibility ? "checkmark.circle" : "exclamationmark.circle")
                Label(host.screenRecording ? "Video ready" : "Video permission needed",
                    systemImage: host.screenRecording ? "checkmark.circle" : "exclamationmark.circle")
            }
            .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(showMenuBarIcon
                ? "Sharing keeps running from the menu bar when this window is closed."
                : "Keep this app open while using your Mac windows on Windows.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if showMenuBarIcon {
                Button { MainWindowController.shared.hideToMenuBar() } label: {
                    Label("Hide to menu bar", systemImage: "menubar.arrow.up.rectangle")
                }
                .buttonStyle(.borderless)
                .help("Hide this window. Transom stays in the menu bar (⌃⌘M).")
            }
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .buttonStyle(.borderless)
            Text("Transom \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(sidebarBackground)
    }

    private var sidebarBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if tintSidebar { accent.opacity(0.10) }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(host.running ? "Shared windows" : "Choose your apps")
                    .font(.system(size: 30, weight: .semibold))
                Text(host.running
                    ? "Open any of these windows from Transom on your PC."
                    : "Select the Mac apps you want to use on Windows.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            if host.running {
                Button("Stop sharing") { host.stop() }
                    .controlSize(.large).buttonStyle(.bordered)
                    .help("Stop sharing (⇧⌥⌘D). Your Mac windows stay open.")
            } else {
                Button(host.starting ? "Starting…" : "Start sharing") { host.startSharing() }
                    .controlSize(.large).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(!host.canStart)
                    .help(host.startBlocker ?? "Start sharing (⇧⌥⌘S)")
            }
        }
    }

    private var appSelection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("Sharing display", selection: $host.selectedDisplayID) {
                    Text("Choose a display").tag(CGDirectDisplayID(0))
                    ForEach(host.displays, id: \.id) { display in
                        Text("\(display.pixelWidth) × \(display.pixelHeight)\(display.isMain ? " (main)" : "")")
                            .tag(display.id)
                    }
                }.frame(maxWidth: 330)
                Spacer()
                Button(action: host.refreshAll) { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            Text("Use your virtual display. Shared windows move there while you work on the PC.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("\(host.selectedPIDs.count) apps selected").font(.callout.weight(.medium))
                Spacer()
                TextField("Find an app", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: cardSize.appCardMinWidth), spacing: 14)],
                spacing: 14
            ) {
                ForEach(host.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }, id: \.pid) { app in
                    appCard(app)
                }
            }
            if host.apps.isEmpty {
                ContentUnavailableView("No apps available", systemImage: "macwindow",
                    description: Text("Open an app on this Mac, then choose Refresh."))
            }
        }
        .disabled(host.starting)
    }

    private func appCard(_ app: TargetApp) -> some View {
        let selected = host.isSelected(app)
        return Button {
            host.toggle(app)
        } label: {
            VStack(alignment: .leading, spacing: cardSize == .compact ? 8 : 14) {
                HStack {
                    if let icon = NSRunningApplication(processIdentifier: app.pid)?.icon {
                        Image(nsImage: icon).resizable().frame(width: cardSize.iconSize, height: cardSize.iconSize)
                    } else { Image(systemName: "macwindow").font(.largeTitle) }
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? accent : Color.secondary.opacity(0.5))
                        .font(.title3)
                }
                Text(app.name).font(.headline).lineLimit(1)
                    .foregroundStyle(.primary)
                Text(cardDetail(app, selected: selected))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(cardSize.padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? accent.opacity(0.06) : Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? accent : Color.secondary.opacity(0.18), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.name).accessibilityValue(selected ? "Selected" : "Not selected")
    }

    /// What will happen to this app's windows, so a hidden or minimized app
    /// does not look like it has nothing to share.
    private func cardDetail(_ app: TargetApp, selected: Bool) -> String {
        guard let summary = host.summaries[app.pid] else {
            return selected ? "Ready to share" : "Select app"
        }
        if summary.windows == 0 { return "No windows open" }
        let count = "\(summary.windows) window\(summary.windows == 1 ? "" : "s")"
        if summary.hidden {
            return restoreWindows ? "\(count) · hidden, shown when sharing" : "\(count) · hidden, not shared"
        }
        if summary.offDisplay > 0 {
            let what = summary.fullScreen > 0 && summary.minimized == 0 ? "full screen" : "minimized"
            return restoreWindows
                ? "\(count) · \(summary.offDisplay) \(what), restored when sharing"
                : "\(count) · \(summary.offDisplay) \(what), not shared"
        }
        return selected ? "\(count) · ready to share" : count
    }

    private var sharedWindows: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(host.status.controlClientConnected ? "Windows PC connected" : "Waiting for your Windows PC",
                    systemImage: "desktopcomputer")
                Spacer()
                Text("\(host.previewWindows.count) windows").foregroundStyle(.secondary)
            }.font(.callout)
            ForEach(host.status.notices, id: \.self) { notice in
                Label(notice, systemImage: "info.circle.fill")
                    .font(.callout)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: cardSize.windowCardMinWidth), spacing: 16)],
                spacing: 16
            ) {
                ForEach(host.previewWindows) { window in
                    VStack(alignment: .leading, spacing: 12) {
                        if showThumbnails {
                            ZStack {
                                Color(nsColor: .windowBackgroundColor)
                                if let cg = host.previewImage?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                                    let crop = cg.cropping(to: window.rect) {
                                    Image(decorative: crop, scale: 1).resizable().scaledToFit()
                                } else {
                                    Label(videoEnabled ? "Waiting for video" : "Video is off", systemImage: "macwindow")
                                        .foregroundStyle(.secondary)
                                }
                            }.frame(height: cardSize.thumbnailHeight).clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        Label {
                            Text(window.title.isEmpty ? "Untitled window" : window.title)
                                .font(.headline).lineLimit(1)
                        } icon: {
                            if !showThumbnails { Image(systemName: "macwindow").foregroundStyle(accent) }
                        }
                        Text("Available on your PC").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if host.previewWindows.isEmpty {
                ContentUnavailableView("No shared windows", systemImage: "macwindow",
                    description: Text("Open a window in a selected app to make it available on your PC."))
            }
        }
    }

    private var connectionHelp: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "display.2").font(.title2).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect from Windows").font(.headline)
                Text("Open Transom on your PC and choose \(HostDiscovery.computerName). Select a window preview to open it. No IP address needed.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Use a trusted local network. Connections are not encrypted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 6)
    }

    private var permissionSetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allow Transom to share your windows").font(.headline)
            if !host.screenRecording && videoEnabled {
                permission("Screen Recording", detail: "Lets your PC see the shared app windows.", path: "Privacy_ScreenCapture")
            }
            if !host.accessibility {
                permission("Accessibility", detail: "Lets you control and resize shared windows from your PC.", path: "Privacy_Accessibility")
            }
        }.padding(18).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func permission(_ title: String, detail: String, path: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(path)") { NSWorkspace.shared.open(url) }
            }
        }
    }

    private var diagnostics: some View {
        DisclosureGroup("Connection details and diagnostics") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Address: \(host.effectiveAddress)   Control: \(controlPort)   Video: \(videoPort)")
                    .textSelection(.enabled)
                if !PrivateAddress.isPrivateIPv4(host.effectiveAddress) {
                    Text("Connect this Mac to Ethernet or Wi-Fi, or select a private address in Settings.").foregroundStyle(.red)
                }
                if !host.hostIsAssigned { Text("This address is no longer assigned to the Mac. Choose a current address in Settings.").foregroundStyle(.red) }
                if !host.portsValid { Text("Choose valid, different control and video ports in Settings.").foregroundStyle(.red) }
                if host.running {
                    Text("\(Int(host.status.measuredFPS)) fps   \(String(format: "%.1f", host.status.measuredBitrateMbps)) Mbps")
                    Text(host.status.encoderFormatSummary).textSelection(.enabled)
                    if !host.status.encoderHardwareOK && host.status.videoEnabled { Text("Hardware encoding is unavailable.").foregroundStyle(.orange) }
                    if let error = host.status.tileError { Text(error).foregroundStyle(.orange) }
                }
                let identity = CodeIdentity.current()
                Text("Permission identity: \(identity.identifier ?? "unsigned")").textSelection(.enabled)
                if identity.isAdHoc { Text("This preview build may need permissions granted again after an update.").foregroundStyle(.secondary) }
                SettingsLink { Text("Advanced settings…") }
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
        }.foregroundStyle(.secondary)
    }
}
