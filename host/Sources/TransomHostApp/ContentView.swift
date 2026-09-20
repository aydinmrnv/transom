import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI
import TransomKit

struct ContentView: View {
    @StateObject private var host = HostAppModel()
    @State private var displays: [DisplayInfo] = []
    @State private var apps: [TargetApp] = []
    @State private var selectedPIDs: Set<pid_t> = []
    @State private var selectedDisplayID: CGDirectDisplayID = 0
    @State private var screenRecording = false
    @State private var accessibility = false
    @State private var detectedAddress = HostDiscovery.localAddresses().first ?? ""
    @State private var activeAddress: String?
    @State private var search = ""
    @AppStorage("sharedAppBundleIDs") private var savedApps = ""
    @AppStorage(HostDefaults.bindAddress) private var bindAddress = "127.0.0.1"
    @AppStorage(HostDefaults.automaticAddress) private var automaticAddress = true
    @AppStorage(HostDefaults.controlPort) private var controlPort = HostDefaults.defaultControlPort
    @AppStorage(HostDefaults.videoPort) private var videoPort = HostDefaults.defaultVideoPort
    @AppStorage(HostDefaults.bitrateMbps) private var bitrateMbps = 40
    @AppStorage(HostDefaults.fps) private var fps = 60
    @AppStorage(HostDefaults.gutter) private var gutter = Tiler.defaultGutter
    @AppStorage(HostDefaults.video) private var videoEnabled = true
    @AppStorage(HostDefaults.chroma) private var chroma = HEVCEncoder.Format.hevc420_8bit.rawValue
    @AppStorage(HostDefaults.namesakeModifiers) private var namesakeModifiers = false
    @AppStorage(HostDefaults.logInput) private var logInput = false
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    private let accent = Color(red: 0.15, green: 0.36, blue: 0.86)
    private var effectiveAddress: String { activeAddress ?? (automaticAddress ? detectedAddress : bindAddress) }
    private var permissionsReady: Bool { accessibility && (!videoEnabled || screenRecording) }
    private var portsValid: Bool {
        HostDefaults.portRange.contains(controlPort) && HostDefaults.portRange.contains(videoPort)
            && (!videoEnabled || controlPort != videoPort)
    }
    private var canStart: Bool {
        permissionsReady && !selectedPIDs.isEmpty && selectedDisplayID != 0
            && PrivateAddress.isPrivateIPv4(effectiveAddress) && portsValid && !host.starting
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if !permissionsReady { permissionSetup }
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
        .onAppear(perform: refreshAll)
        .onReceive(timer) { _ in
            refreshPermissions()
            if !host.running && !host.starting {
                activeAddress = nil
                detectedAddress = HostDiscovery.localAddresses().first ?? ""
            }
        }
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
                Label(accessibility ? "Control ready" : "Control permission needed",
                    systemImage: accessibility ? "checkmark.circle" : "exclamationmark.circle")
                Label(screenRecording ? "Video ready" : "Video permission needed",
                    systemImage: screenRecording ? "checkmark.circle" : "exclamationmark.circle")
            }
            .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("Keep this app open while using your Mac windows on Windows.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .buttonStyle(.borderless)
            Text("Transom \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
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
            } else {
                Button(host.starting ? "Starting…" : "Start sharing", action: startSharing)
                    .controlSize(.large).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(!canStart)
            }
        }
    }

    private var appSelection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("Sharing display", selection: $selectedDisplayID) {
                    Text("Choose a display").tag(CGDirectDisplayID(0))
                    ForEach(displays, id: \.id) { display in
                        Text("\(display.pixelWidth) × \(display.pixelHeight)\(display.isMain ? " (main)" : "")")
                            .tag(display.id)
                    }
                }.frame(maxWidth: 330)
                Spacer()
                Button(action: refreshAll) { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            Text("Use your virtual display. Shared windows move there while you work on the PC.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("\(selectedPIDs.count) apps selected").font(.callout.weight(.medium))
                Spacer()
                TextField("Find an app", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                ForEach(apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }, id: \.pid) { app in
                    appCard(app)
                }
            }
            if apps.isEmpty {
                ContentUnavailableView("No apps available", systemImage: "macwindow",
                    description: Text("Open an app on this Mac, then choose Refresh."))
            }
        }
        .disabled(host.starting)
    }

    private func appCard(_ app: TargetApp) -> some View {
        let selected = selectedPIDs.contains(app.pid)
        return Button {
            if selected { selectedPIDs.remove(app.pid) } else { selectedPIDs.insert(app.pid) }
            savedApps = apps.filter { selectedPIDs.contains($0.pid) }.compactMap(\.bundleID).joined(separator: "\n")
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    if let icon = NSRunningApplication(processIdentifier: app.pid)?.icon {
                        Image(nsImage: icon).resizable().frame(width: 44, height: 44)
                    } else { Image(systemName: "macwindow").font(.largeTitle) }
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? accent : Color.secondary.opacity(0.5))
                        .font(.title3)
                }
                Text(app.name).font(.headline).lineLimit(1)
                    .foregroundStyle(.primary)
                Text(selected ? "Ready to share" : "Select app")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? accent.opacity(0.06) : Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? accent : Color.secondary.opacity(0.18), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.name).accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private var sharedWindows: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(host.status.controlClientConnected ? "Windows PC connected" : "Waiting for your Windows PC",
                    systemImage: "desktopcomputer")
                Spacer()
                Text("\(host.previewWindows.count) windows").foregroundStyle(.secondary)
            }.font(.callout)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                ForEach(host.previewWindows) { window in
                    VStack(alignment: .leading, spacing: 12) {
                        ZStack {
                            Color(nsColor: .windowBackgroundColor)
                            if let cg = host.previewImage?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                                let crop = cg.cropping(to: window.rect) {
                                Image(decorative: crop, scale: 1).resizable().scaledToFit()
                            } else {
                                Label(videoEnabled ? "Waiting for video" : "Video is off", systemImage: "macwindow")
                                    .foregroundStyle(.secondary)
                            }
                        }.frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 6))
                        Text(window.title.isEmpty ? "Untitled window" : window.title)
                            .font(.headline).lineLimit(1)
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
            if !screenRecording && videoEnabled {
                permission("Screen Recording", detail: "Lets your PC see the shared app windows.", path: "Privacy_ScreenCapture")
            }
            if !accessibility {
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
                Text("Address: \(effectiveAddress)   Control: \(controlPort)   Video: \(videoPort)")
                    .textSelection(.enabled)
                if !PrivateAddress.isPrivateIPv4(effectiveAddress) {
                    Text("Connect this Mac to Ethernet or Wi-Fi, or select a private address in Settings.").foregroundStyle(.red)
                }
                if !portsValid { Text("Choose valid, different control and video ports in Settings.").foregroundStyle(.red) }
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

    private func refreshAll() {
        displays = Displays.all()
        apps = AppResolver.runningApps().filter { $0.pid != ProcessInfo.processInfo.processIdentifier }
        if selectedPIDs.isEmpty {
            let saved = Set(savedApps.split(separator: "\n").map(String.init))
            selectedPIDs = Set(apps.filter { saved.contains($0.bundleID ?? "") }.map(\.pid))
        } else { selectedPIDs.formIntersection(Set(apps.map(\.pid))) }
        if selectedDisplayID == 0 || !displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = displays.first(where: { $0.isMain })?.id ?? displays.first?.id ?? 0
        }
        refreshPermissions()
    }
    private func refreshPermissions() {
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
    }
    private func startSharing() {
        let targets = apps.filter { selectedPIDs.contains($0.pid) }
        guard let first = targets.first, let display = displays.first(where: { $0.id == selectedDisplayID }) else { return }
        let address = automaticAddress ? (HostDiscovery.localAddresses().first ?? "") : bindAddress
        guard PrivateAddress.isPrivateIPv4(address) else {
            host.startError = "Connect this Mac to Ethernet or Wi-Fi before sharing."
            return
        }
        activeAddress = address
        host.start(config: HostConfig(target: first, additionalTargets: Array(targets.dropFirst()),
            display: display, host: address, controlPort: UInt16(clamping: controlPort),
            videoPort: UInt16(clamping: videoPort), gutter: gutter, tile: true,
            video: videoEnabled, bitrateMbps: bitrateMbps, fps: fps,
            videoFormat: HEVCEncoder.Format(rawValue: chroma) ?? .hevc420_8bit,
            namesakeModifiers: namesakeModifiers, logInput: logInput))
    }
}
