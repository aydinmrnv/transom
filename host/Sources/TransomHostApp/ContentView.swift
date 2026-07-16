import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI
import TransomKit

struct ContentView: View {
    @StateObject private var host = HostAppModel()

    @State private var displays: [DisplayInfo] = []
    @State private var apps: [TargetApp] = []
    @State private var selectedAppPID: pid_t = 0
    @State private var selectedDisplayID: CGDirectDisplayID = 0

    // Live permission state, refreshed on a slow timer.
    @State private var screenRecording = false
    @State private var accessibility = false
    private let identity = CodeIdentity.current()
    private let permTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    // Persisted connection config (edited inline; this is a control panel).
    @AppStorage("host.bindAddress") private var bindAddress = "127.0.0.1"
    @AppStorage("host.controlPort") private var controlPort = 7000
    @AppStorage("host.videoPort") private var videoPort = 7001
    @AppStorage("host.bitrateMbps") private var bitrateMbps = 40
    @AppStorage("host.fps") private var fps = 60
    @AppStorage("host.gutter") private var gutter = Tiler.defaultGutter
    @AppStorage("host.video") private var videoEnabled = true
    /// Encoder chroma. Default 4:2:0 8-bit: the Windows client's in-box decoder can
    /// decode it, so pixels actually appear. 4:4:4 10-bit is crisper but needs a
    /// 4:4:4-capable client decoder (protocol.md §6-7).
    @AppStorage("host.chroma") private var chroma = HEVCEncoder.Format.hevc420_8bit.rawValue

    private var videoFormat: HEVCEncoder.Format {
        HEVCEncoder.Format(rawValue: chroma) ?? .hevc420_8bit
    }

    private var hostIsPrivate: Bool { PrivateAddress.isPrivateIPv4(bindAddress) }
    private var permissionsReady: Bool { accessibility && (!videoEnabled || screenRecording) }
    private var canStart: Bool {
        permissionsReady && selectedAppPID != 0 && selectedDisplayID != 0 && hostIsPrivate
            && !host.running && !host.starting
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                permissionsSection
                Divider()
                configurationSection
                if host.running {
                    Divider()
                    statusSection
                }
            }
            .padding(22)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .onAppear(perform: refreshAll)
        .onReceive(permTimer) { _ in refreshPermissions() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Transom Host").font(.largeTitle).bold()
            Text(
                "Control panel for the host half — the same thing `transom-host serve` runs. "
                    + "Point it at a display and an app, then Start. Not a product; a thing that runs."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 1. Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Permissions", nil)

            permissionRow(
                "Screen Recording", granted: screenRecording,
                help:
                    "Required to capture the display for video. Attributed to THIS app's identity."
            ) {
                open(
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
            permissionRow(
                "Accessibility", granted: accessibility,
                help: "Required to tile and move windows via the AX API."
            ) {
                open(
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }

            identityFootnote
        }
        .padding(16)
        .background(Color.secondary.opacity(0.07))
        .cornerRadius(10)
    }

    private func permissionRow(
        _ title: String, granted: Bool, help: String, openSettings: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title): \(granted ? "granted" : "not granted")").bold()
                Text(help).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Settings", action: openSettings)
        }
    }

    private var identityFootnote: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("This app's TCC identity — which identity actually holds the grants above:")
                .font(.caption2).foregroundStyle(.secondary)
            Text("bundle id  \(identity.identifier ?? "— (unsigned)")")
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("cdhash     \(identity.cdhash ?? "—")")
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled)
            if identity.isAdHoc {
                Text(
                    "Ad-hoc / unsigned — macOS re-prompts for permissions on every rebuild. "
                        + "Run the signed Transom Host.app for a stable grant."
                )
                .font(.caption2).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - 2. Configuration

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Configuration", nil)

            HStack {
                Picker("Display", selection: $selectedDisplayID) {
                    Text("Choose…").tag(CGDirectDisplayID(0))
                    ForEach(displays, id: \.id) { d in
                        Text(
                            "\(d.id)  \(d.pixelWidth)×\(d.pixelHeight)\(d.isMain ? "  (main)" : "")"
                        )
                        .tag(d.id)
                    }
                }
                .frame(maxWidth: 320)
                Button("Refresh", action: refreshAll)
                    .disabled(host.running)
            }

            HStack {
                Picker("App", selection: $selectedAppPID) {
                    Text("Choose…").tag(pid_t(0))
                    ForEach(apps, id: \.pid) { Text($0.name).tag($0.pid) }
                }
                .frame(maxWidth: 320)
                Button("Reload apps") { apps = AppResolver.runningApps() }
                    .disabled(host.running)
            }

            bindRow
            tuningRow

            HStack(spacing: 12) {
                if host.running {
                    Button("Stop", role: .destructive) { host.stop() }
                } else {
                    Button(host.starting ? "Starting…" : "Start") { startServing() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canStart)
                }
                if !permissionsReady {
                    Text("Grant the permissions above first.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            if let err = host.startError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var bindRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("Bind").frame(width: 44, alignment: .leading)
                TextField("127.0.0.1", text: $bindAddress)
                    .frame(width: 140)
                    .disabled(host.running)
                Text("control").foregroundStyle(.secondary).font(.caption)
                intField($controlPort, width: 64)
                Text("video").foregroundStyle(.secondary).font(.caption)
                intField($videoPort, width: 64)
            }
            // The private-address gate from #5, made visible (and enforced at Start).
            HStack(spacing: 6) {
                Image(systemName: hostIsPrivate ? "lock.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(hostIsPrivate ? .green : .red)
                Text(
                    hostIsPrivate
                        ? "Private address — allowed (no auth/encryption; LAN only)."
                        : "Not a private address — Start is refused. Use 127/8, 10/8, 172.16/12, 192.168/16, or 169.254/16."
                )
                .font(.caption)
                .foregroundStyle(hostIsPrivate ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
            }
            if controlPort == 7000 {
                Label(
                    "Port 7000 is used by AirPlay Receiver on many Macs — if the control client "
                        + "never connects, pick another port or turn AirPlay Receiver off in "
                        + "System Settings › General › AirDrop & Handoff.",
                    systemImage: "info.circle"
                )
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var tuningRow: some View {
        HStack(spacing: 12) {
            Toggle("Stream video", isOn: $videoEnabled).disabled(host.running)
            if videoEnabled {
                Picker("chroma", selection: $chroma) {
                    Text("4:2:0 8-bit (decodable)").tag(HEVCEncoder.Format.hevc420_8bit.rawValue)
                    Text("4:4:4 10-bit (crisp)").tag(HEVCEncoder.Format.hevc444_10bit.rawValue)
                }
                .labelsHidden()
                .fixedSize()
                .disabled(host.running)
            }
            Divider().frame(height: 16)
            Text("fps").foregroundStyle(.secondary).font(.caption)
            intField($fps, width: 48)
            Text("bitrate").foregroundStyle(.secondary).font(.caption)
            intField($bitrateMbps, width: 48)
            Text("Mbps").foregroundStyle(.secondary).font(.caption)
            Text("gutter").foregroundStyle(.secondary).font(.caption)
            intField($gutter, width: 56)
            Text("px").foregroundStyle(.secondary).font(.caption)
        }
    }

    // MARK: - 3. Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Status", "live")

            clientRow
            encoderModeBanner
            if host.status.videoEnabled {
                statTiles
            }
            tileLayoutView
        }
    }

    private var clientRow: some View {
        HStack(spacing: 10) {
            clientBadge("control client", connected: host.status.controlClientConnected)
            if host.status.videoEnabled {
                clientBadge("video client", connected: host.status.videoClientConnected)
            }
            Spacer()
            Text("\(host.status.liveWindowCount) window(s) tracked")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func clientBadge(_ label: String, connected: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(connected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)
            Text(connected ? "\(label): connected" : "\(label): waiting")
                .font(.caption)
                .foregroundStyle(connected ? .primary : .secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.secondary.opacity(0.08)).cornerRadius(6)
    }

    /// The encoder headline. Two independent things matter, and conflating them is
    /// what the old "FALLBACK — NOT 4:4:4" banner got wrong:
    ///   1. **Hardware path** — a silent fall to *software* can't hold 60fps. That
    ///      is the real failure, and it turns the banner red.
    ///   2. **Chroma choice** — 4:2:0 (in-box decodable) vs 4:4:4 (crisp text) is a
    ///      deliberate selection, shown as info, not an alarm.
    @ViewBuilder
    private var encoderModeBanner: some View {
        if host.status.videoEnabled {
            let hwOK = host.status.encoderHardwareOK
            let format = host.status.videoFormat
            let decodeNote =
                format.inBoxDecodable
                ? "the Windows in-box decoder can decode this"
                : "needs a 4:4:4-capable client decoder to display"
            HStack(spacing: 10) {
                Image(systemName: hwOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        hwOK
                            ? "HEVC \(format.chromaTag) · hardware"
                            : "SOFTWARE FALLBACK — HEVC \(format.chromaTag)"
                    )
                    .font(.title3).bold()
                    Text(decodeNote)
                        .font(.caption).foregroundStyle(.secondary)
                    Text(
                        "encoder read-back: hardware=\(host.status.usingHardware ? "yes" : "no")  ·  \(host.status.encoderFormatSummary)"
                    )
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
                Spacer()
            }
            .padding(12)
            .background((hwOK ? Color.green : Color.red).opacity(0.15))
            .overlay(
                RoundedRectangle(cornerRadius: 8).stroke(
                    hwOK ? Color.green : Color.red, lineWidth: 1)
            )
            .cornerRadius(8)
        } else {
            Text("Video streaming is off — control channel only (no encoder).")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var statTiles: some View {
        HStack(spacing: 12) {
            statTile("fps", String(format: "%.0f", host.status.measuredFPS))
            statTile(
                "bitrate", String(format: "%.1f", host.status.measuredBitrateMbps), unit: "Mbps")
            statTile(
                "encode latency", String(format: "%.1f", host.status.encodeLatencyMillis),
                unit: "ms")
            statTile("frames", "\(host.status.totalFramesEncoded)")
        }
    }

    private func statTile(_ label: String, _ value: String, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(.title2, design: .rounded)).bold().monospacedDigit()
                if let unit { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08)).cornerRadius(8)
    }

    // MARK: Tile layout (post-clamp actual rects, I-4 / OQ-2)

    @ViewBuilder
    private var tileLayoutView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tile layout — requested vs. actual (post-clamp, I-4)")
                .font(.headline)
            if let err = host.status.tileError {
                Label("tiling failed: \(err)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } else if host.status.tilePlacements.isEmpty {
                Text("No sizable windows were tiled.").font(.caption).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
                    GridRow {
                        Text("win").gridHeader()
                        Text("requested (VDS px)").gridHeader()
                        Text("actual (VDS px)").gridHeader()
                        Text("Δ").gridHeader()
                    }
                    ForEach(host.status.tilePlacements, id: \.index) { placementRow($0) }
                }
                Text("Deltas are AX clamping/rounding (OQ-2) — reported, never hidden.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func placementRow(_ p: TilePlacement) -> some View {
        GridRow {
            Text("[\(p.index)] \(p.title.isEmpty ? "—" : p.title)")
                .font(.system(.caption, design: .monospaced)).lineLimit(1)
            Text("(\(p.requested.x),\(p.requested.y)) \(p.requested.width)×\(p.requested.height)")
                .font(.system(.caption, design: .monospaced))
            if let a = p.actual {
                Text("(\(a.x),\(a.y)) \(a.width)×\(a.height)")
                    .font(.system(.caption, design: .monospaced))
            } else {
                Text("AX refused").font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.orange)
            }
            deltaCell(p)
        }
    }

    @ViewBuilder
    private func deltaCell(_ p: TilePlacement) -> some View {
        if p.actual == nil {
            Text("—").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        } else if p.isExact {
            Text("exact").font(.system(.caption, design: .monospaced)).foregroundStyle(.green)
        } else if let pd = p.positionDelta, let sd = p.sizeDelta {
            Text("pos(\(pd.dx),\(pd.dy)) size(\(sd.dw),\(sd.dh))")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.orange)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, _ tag: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.title2).bold()
            if let tag {
                Text(tag).font(.caption).bold().padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15)).cornerRadius(4)
            }
        }
    }

    private func intField(_ binding: Binding<Int>, width: CGFloat) -> some View {
        TextField("", value: binding, format: .number.grouping(.never))
            .frame(width: width)
            .disabled(host.running)
    }

    private func refreshAll() {
        displays = Displays.all()
        apps = AppResolver.runningApps()
        if selectedDisplayID == 0 || !displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = displays.first(where: { $0.isMain })?.id ?? displays.first?.id ?? 0
        }
        refreshPermissions()
    }

    private func refreshPermissions() {
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
    }

    private func startServing() {
        guard let app = apps.first(where: { $0.pid == selectedAppPID }),
            let disp = displays.first(where: { $0.id == selectedDisplayID })
        else { return }
        let config = HostConfig(
            target: app, display: disp, host: bindAddress,
            controlPort: UInt16(clamping: controlPort), videoPort: UInt16(clamping: videoPort),
            gutter: gutter, tile: true, video: videoEnabled, bitrateMbps: bitrateMbps, fps: fps,
            videoFormat: videoFormat)
        host.start(config: config)
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }
}

extension Text {
    fileprivate func gridHeader() -> some View {
        self.font(.caption).bold().foregroundStyle(.secondary)
    }
}
