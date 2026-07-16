import SwiftUI
import TransomKit

/// The `UserDefaults` keys the host control panel persists its settings under.
///
/// One list, referenced by both the main window (which reads them at Start to
/// build the `HostConfig`) and the Settings window (which edits them). Keeping the
/// literals here means the two views can never drift onto different keys — the bug
/// that silently splits a setting into two.
enum HostDefaults {
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
    static let previewOutlines = "host.previewOutlines"
    static let previewLabels = "host.previewLabels"

    /// Valid TCP port range. Start is gated on both ports falling inside it so a
    /// value never gets silently clamped into a different endpoint at serve time.
    static let portRange = 1...65535
}

/// The standard macOS Settings window (Cmd-,). Every control binds to a
/// `HostDefaults` key via `@AppStorage`, so edits persist and the main window
/// picks them up — connection/video/layout changes at the next Start, preview
/// toggles live. This is where the knobs that used to crowd the main window now
/// live, leaving the main window to the act of *starting a session*.
struct HostSettingsView: View {
    var body: some View {
        TabView {
            ConnectionSettings()
                .tabItem { Label("Connection", systemImage: "network") }
            VideoSettings()
                .tabItem { Label("Video", systemImage: "video") }
            LayoutSettings()
                .tabItem { Label("Layout", systemImage: "rectangle.3.group") }
            InputSettings()
                .tabItem { Label("Input", systemImage: "keyboard") }
        }
        .frame(width: 460, height: 380)
    }
}

// MARK: - Connection

private struct ConnectionSettings: View {
    @AppStorage(HostDefaults.bindAddress) private var bindAddress = "127.0.0.1"
    @AppStorage(HostDefaults.controlPort) private var controlPort = 7000
    @AppStorage(HostDefaults.videoPort) private var videoPort = 7001

    private var isPrivate: Bool { PrivateAddress.isPrivateIPv4(bindAddress) }
    private func portValid(_ p: Int) -> Bool { HostDefaults.portRange.contains(p) }

    var body: some View {
        Form {
            Section("Bind") {
                TextField("Address", text: $bindAddress)
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
                    Image(systemName: isPrivate ? "lock.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(isPrivate ? .green : .red)
                }
                if controlPort == 7000 {
                    Label(
                        "Port 7000 is AirPlay Receiver on many Macs. If the control client never "
                            + "connects, pick another port or turn AirPlay Receiver off in System "
                            + "Settings › General › AirDrop & Handoff.",
                        systemImage: "info.circle"
                    )
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
    @AppStorage(HostDefaults.fps) private var fps = 60
    @AppStorage(HostDefaults.bitrateMbps) private var bitrateMbps = 40

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

    var body: some View {
        Form {
            Section("Tiling") {
                TextField("Gutter (px)", value: $gutter, format: .number.grouping(.never))
                Text(
                    "Space left between tiled windows when the session starts. Windows are laid out "
                        + "once, non-overlapping (I-5). Applies at the next Start."
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

    var body: some View {
        Form {
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
