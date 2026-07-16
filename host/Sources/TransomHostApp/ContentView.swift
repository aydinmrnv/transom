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

    /// The window highlighted in the preview / windows list. `nil` is "none".
    @State private var selectedWindowID: UInt64?

    // Live permission state, refreshed on a slow timer.
    @State private var screenRecording = false
    @State private var accessibility = false
    private let identity = CodeIdentity.current()
    private let permTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    // Persisted config — the source of truth is the Settings window (Cmd-,); these
    // read the same UserDefaults keys and are consumed at Start (HostDefaults).
    @AppStorage(HostDefaults.bindAddress) private var bindAddress = "127.0.0.1"
    @AppStorage(HostDefaults.controlPort) private var controlPort = 7000
    @AppStorage(HostDefaults.videoPort) private var videoPort = 7001
    @AppStorage(HostDefaults.bitrateMbps) private var bitrateMbps = 40
    @AppStorage(HostDefaults.fps) private var fps = 60
    @AppStorage(HostDefaults.gutter) private var gutter = Tiler.defaultGutter
    @AppStorage(HostDefaults.video) private var videoEnabled = true
    /// Encoder chroma. Default 4:2:0 8-bit: the Windows client's in-box decoder can
    /// decode it, so pixels actually appear. 4:4:4 10-bit is crisper but needs a
    /// 4:4:4-capable client decoder (protocol.md §6-7).
    @AppStorage(HostDefaults.chroma) private var chroma = HEVCEncoder.Format.hevc420_8bit.rawValue
    @AppStorage(HostDefaults.namesakeModifiers) private var namesakeModifiers = false
    @AppStorage(HostDefaults.logInput) private var logInput = false
    @AppStorage(HostDefaults.previewOutlines) private var previewOutlines = true
    @AppStorage(HostDefaults.previewLabels) private var previewLabels = true

    private var videoFormat: HEVCEncoder.Format {
        HEVCEncoder.Format(rawValue: chroma) ?? .hevc420_8bit
    }

    private var hostIsPrivate: Bool { PrivateAddress.isPrivateIPv4(bindAddress) }
    private var permissionsReady: Bool { accessibility && (!videoEnabled || screenRecording) }
    /// Both ports must be real TCP endpoints. Without this gate, `startServing()`
    /// would `UInt16(clamping:)` an out-of-range value into a *different* port than
    /// the recap shows (e.g. 70000 → 65535), binding somewhere the user never asked.
    private var portsValid: Bool {
        HostDefaults.portRange.contains(controlPort) && HostDefaults.portRange.contains(videoPort)
    }
    private var canStart: Bool {
        permissionsReady && selectedAppPID != 0 && selectedDisplayID != 0 && hostIsPrivate
            && portsValid && !host.running && !host.starting
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
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
            }
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

            settingsSummaryRow

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
                } else if !hostIsPrivate {
                    Text("Bind address isn't private — fix it in Settings (⌘,) before Start.")
                        .font(.caption).foregroundStyle(.red)
                } else if !portsValid {
                    Text("Ports must be 1–65535 — fix them in Settings (⌘,) before Start.")
                        .font(.caption).foregroundStyle(.red)
                }
            }

            if let err = host.startError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A read-only recap of the persisted settings, with a jump into the Settings
    /// window where they're edited. The knobs used to live inline here; now the
    /// main window is about *starting a session* and this is just the confirmation
    /// of what Start will use.
    private var settingsSummaryRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
            Text(configSummary)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            SettingsLink { Text("Settings…") }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07))
        .cornerRadius(8)
    }

    private var configSummary: String {
        var parts = ["\(bindAddress)", "control \(controlPort)"]
        if videoEnabled {
            parts.append("video \(videoPort)")
            parts.append("HEVC \(videoFormat.chromaTag)")
            parts.append("\(fps) fps")
            parts.append("\(bitrateMbps) Mbps")
        } else {
            parts.append("video off")
        }
        parts.append("gutter \(gutter)px")
        parts.append(namesakeModifiers ? "Ctrl→Ctrl" : "Ctrl→⌘")
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - 3. Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Status", "live")

            clientRow
            previewSection
            encoderModeBanner
            if host.status.videoEnabled {
                statTiles
            }
            tileLayoutView
        }
        .onChange(of: host.previewWindows) { _, windows in
            // Drop a highlight whose window closed, so the selection never dangles.
            if let id = selectedWindowID, !windows.contains(where: { $0.id == id }) {
                selectedWindowID = nil
            }
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

    // MARK: Live preview

    /// The headline of this whole feature: a downscaled view of the exact frame
    /// being encoded, every tracked window outlined on top, and the selected one
    /// highlighted (in both the picture and the list beside it).
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Live preview").font(.headline)
                Text(
                    host.status.videoEnabled
                        ? "what you're streaming" : "window layout (video off)"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 14) {
                StreamPreview(
                    image: host.previewImage,
                    displaySize: host.displayPixelSize,
                    windows: host.previewWindows,
                    showOutlines: previewOutlines,
                    showLabels: previewLabels,
                    videoEnabled: host.status.videoEnabled,
                    selectedID: $selectedWindowID)
                windowsPanel
            }
        }
    }

    private var windowsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Windows").font(.headline)
                Text("\(host.previewWindows.count)")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12)).cornerRadius(4)
                Spacer()
            }
            if host.previewWindows.isEmpty {
                Text("No tracked windows yet.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(host.previewWindows) { windowRow($0) }
                    }
                }
                .frame(maxHeight: 380)
            }
            Text("Click a window — here or in the preview — to highlight it.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 250)
    }

    private func windowRow(_ w: PreviewWindow) -> some View {
        let selected = w.id == selectedWindowID
        return Button {
            selectedWindowID = selected ? nil : w.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(w.title.isEmpty ? "window \(w.id)" : w.title)
                    .font(.caption).bold().lineLimit(1)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Text(
                    "id \(w.id) · (\(Int(w.rect.minX)),\(Int(w.rect.minY))) "
                        + "\(Int(w.rect.width))×\(Int(w.rect.height))"
                )
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(selected ? Color.accentColor : Color.secondary.opacity(0.08))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
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
            videoFormat: videoFormat, namesakeModifiers: namesakeModifiers, logInput: logInput)
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
