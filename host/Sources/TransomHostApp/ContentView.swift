import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI
import TransomKit

struct ContentView: View {
    @ObservedObject var host: HostAppModel
    @State private var displays: [DisplayInfo] = []
    @State private var apps: [TargetApp] = []
    @State private var selectedDisplayID: CGDirectDisplayID = 0
    @State private var screenRecording = false
    @State private var accessibility = false
    @State private var detectedAddress = HostDiscovery.localAddresses().first ?? ""
    @State private var activeAddress: String?
    @AppStorage(HostDefaults.bindAddress) private var bindAddress = "127.0.0.1"
    @AppStorage(HostDefaults.automaticAddress) private var automaticAddress = true
    @AppStorage(HostDefaults.controlPort) private var controlPort = HostDefaults.defaultControlPort
    @AppStorage(HostDefaults.videoPort) private var videoPort = HostDefaults.defaultVideoPort
    @AppStorage(HostDefaults.bitrateMbps) private var bitrateMbps = 40
    @AppStorage(HostDefaults.fps) private var fps = 60
    @AppStorage(HostDefaults.video) private var videoEnabled = true
    @AppStorage(HostDefaults.chroma) private var chroma = HEVCEncoder.Format.hevc420_8bit.rawValue
    @AppStorage(HostDefaults.namesakeModifiers) private var namesakeModifiers = false
    @AppStorage(HostDefaults.logInput) private var logInput = false
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    private let accent = Color(red: 0.15, green: 0.36, blue: 0.86)
    private var effectiveAddress: String { activeAddress ?? (automaticAddress ? detectedAddress : bindAddress) }
    private var hostIsAssigned: Bool {
        effectiveAddress.hasPrefix("127.") || HostDiscovery.localAddresses().contains(effectiveAddress)
    }
    private var permissionsReady: Bool { accessibility && (!videoEnabled || screenRecording) }
    private var portsValid: Bool {
        HostDefaults.portRange.contains(controlPort) && HostDefaults.portRange.contains(videoPort)
            && (!videoEnabled || controlPort != videoPort)
    }
    private var canStart: Bool {
        permissionsReady && !apps.isEmpty && selectedDisplayID != 0
            && PrivateAddress.isPrivateIPv4(effectiveAddress) && hostIsAssigned && portsValid && !host.starting
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
        .onAppear {
            refreshAll()
            // An installer can explicitly resume an already authorized session
            // after replacing the bundle. Normal launches still require Start.
            if ProcessInfo.processInfo.arguments.contains("--start-sharing"), canStart, !host.running {
                startSharing()
            }
        }
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
                Text(host.running ? "Shared windows" : "Share your Mac windows")
                    .font(.system(size: 30, weight: .semibold))
                Text(host.running
                    ? "These windows are in use on your PC. Browse all windows in the Windows app."
                    : "Connect from Windows and choose the windows you want to use.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            if host.running {
                Button("Stop sharing") { host.stop() }
                    .controlSize(.large).buttonStyle(.bordered)
                    .help("Stop sharing (⇧⌥⌘D). Your Mac windows stay open.")
            } else {
                Button(host.starting ? "Starting…" : "Start sharing", action: startSharing)
                    .controlSize(.large).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(!canStart)
            }
        }
    }

    private var appSelection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Choose windows on your PC", systemImage: "macwindow.on.rectangle")
                .font(.title3.weight(.semibold))
            Text("All open Mac windows appear in Transom on Windows. Open a preview to start using it. Apps you open later appear automatically.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Sharing display", selection: $selectedDisplayID) {
                ForEach(displays, id: \.id) { display in
                    Text("\(display.pixelWidth) × \(display.pixelHeight)\(display.isMain ? " · Main display" : "")").tag(display.id)
                }
            }
            Text("Windows you open from the PC move onto this display while shared.")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(host.starting)
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
                            if let image = host.windowImages[window.id] {
                                Image(decorative: image, scale: 1).resizable().scaledToFit()
                            } else if let cg = host.previewImage?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                                let crop = cg.cropping(to: window.rect.applying(CGAffineTransform(
                                    scaleX: CGFloat(cg.width) / max(host.displayPixelSize.width, 1),
                                    y: CGFloat(cg.height) / max(host.displayPixelSize.height, 1)))) {
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
                    description: Text("Choose a window in Transom on your PC to start sharing it."))
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
                if !hostIsAssigned { Text("This address is no longer assigned to the Mac. Choose a current address in Settings.").foregroundStyle(.red) }
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
        HostDefaults.repairStaleBindAddress()
        displays = Displays.all()
        apps = AppResolver.runningApps().filter { $0.pid != ProcessInfo.processInfo.processIdentifier }
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
        let targets = AppResolver.runningApps().filter { $0.pid != ProcessInfo.processInfo.processIdentifier }
        guard let first = targets.first, let display = displays.first(where: { $0.id == selectedDisplayID }) else { return }
        let address = automaticAddress ? (HostDiscovery.localAddresses().first ?? "") : bindAddress
        guard PrivateAddress.isPrivateIPv4(address) else {
            host.startError = "Connect this Mac to Ethernet or Wi-Fi before sharing."
            return
        }
        activeAddress = address
        host.start(config: HostConfig(target: first, clientWindowSelection: true,
            display: display, host: address, controlPort: UInt16(clamping: controlPort),
            videoPort: UInt16(clamping: videoPort), gutter: 0, tile: false,
            video: videoEnabled, bitrateMbps: bitrateMbps, fps: fps,
            videoFormat: HEVCEncoder.Format(rawValue: chroma) ?? .hevc420_8bit,
            namesakeModifiers: namesakeModifiers, logInput: logInput))
    }
}
