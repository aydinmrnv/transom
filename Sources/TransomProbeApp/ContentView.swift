import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI
import TransomKit

struct ContentView: View {
    @StateObject private var probe = ProbeModel()
    @StateObject private var geometry = GeometryModel()

    @State private var displays: [DisplayInfo] = []
    @State private var apps: [TargetApp] = []
    @State private var selectedAppPID: pid_t = 0
    @State private var selectedDisplayID: CGDirectDisplayID = 0

    // Permissions, refreshed on a slow timer so the UI is live.
    @State private var screenRecording = false
    @State private var accessibility = false
    private let identity = CodeIdentity.current()
    private let permTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    // Persisted settings (edited in the Settings window, Cmd-,).
    @AppStorage(ProbeSettings.storageKeys.fps) private var fps = 60
    @AppStorage(ProbeSettings.storageKeys.pollHz) private var pollHz = 10
    @AppStorage(ProbeSettings.storageKeys.showWindowRects) private var showWindowRects = true
    @AppStorage(ProbeSettings.storageKeys.showMenuRects) private var showMenuRects = true
    @AppStorage(ProbeSettings.storageKeys.showLabels) private var showLabels = true

    private var permissionsReady: Bool { screenRecording && accessibility }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                setupCard
                if permissionsReady {
                    liveProbeSection
                    Divider()
                    geometrySection
                    Divider()
                    displaysSection
                }
            }
            .padding(22)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
            }
        }
        .onAppear(perform: refreshAll)
        .onReceive(permTimer) { _ in refreshPermissions() }
        .onChange(of: showWindowRects) { _, new in probe.settings.showWindowRects = new }
        .onChange(of: showMenuRects) { _, new in probe.settings.showMenuRects = new }
        .onChange(of: showLabels) { _, new in probe.settings.showLabels = new }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Transom Probe").font(.largeTitle).bold()
            Text(
                "A diagnostic instrument — not a product. It answers one question: "
                    + "do macOS menus and popups show up in a ScreenCaptureKit capture, "
                    + "and does the Accessibility API report them?"
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Setup / onboarding card

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(
                    systemName: permissionsReady
                        ? "checkmark.seal.fill" : "list.number"
                )
                .foregroundStyle(permissionsReady ? Color.green : Color.accentColor)
                Text(permissionsReady ? "You're set up" : "Getting started")
                    .font(.title2).bold()
            }

            step(
                1, "Grant Screen Recording", done: screenRecording,
                help: "Lets the probe capture the display with ScreenCaptureKit."
            ) {
                Button("Open settings") {
                    open(
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                    )
                }
            }
            step(
                2, "Grant Accessibility", done: accessibility,
                help: "Lets the probe read window/menu frames via the AX API."
            ) {
                Button("Open settings") {
                    open(
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                    )
                }
            }
            step(
                3, "Relaunch after granting", done: permissionsReady,
                help: "macOS applies a new grant to this app on its next launch. "
                    + "If a toggle above stays red after you flip it in System Settings, quit and reopen."
            ) {
                Button("Refresh", action: refreshPermissions)
            }
            step(
                4, "Pick an app and display, then press Start", done: false,
                help:
                    "In the Live probe below, choose a target app (e.g. Xcode) and the display it's on.",
                showCheck: false
            ) { EmptyView() }
            step(
                5, "Open the app's menu and watch", done: false,
                help: "Open a menu, sheet, or completion popup in the target app. "
                    + "You want to see it appear in the capture with an orange outline around it — that's the answer.",
                showCheck: false
            ) { EmptyView() }

            identityFootnote
        }
        .padding(16)
        .background(Color.secondary.opacity(0.07))
        .cornerRadius(10)
    }

    @ViewBuilder
    private func step<Trailing: View>(
        _ n: Int, _ title: String, done: Bool, help: String, showCheck: Bool = true,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.25))
                    .frame(width: 22, height: 22)
                if showCheck && done {
                    Image(systemName: "checkmark").font(.caption2).bold().foregroundStyle(.white)
                } else {
                    Text("\(n)").font(.caption2).bold()
                        .foregroundStyle(done ? .white : .secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(help).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing()
        }
    }

    private var identityFootnote: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("This app's TCC identity (which identity holds the grant):")
                .font(.caption2).foregroundStyle(.secondary)
            Text(
                "\(identity.identifier ?? "—")  ·  cdhash \(identity.cdhash?.prefix(16).description ?? "—")…"
            )
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            if identity.isAdHoc {
                Text("Ad-hoc signed — macOS will re-prompt for permissions on every rebuild.")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Live probe (the important one)

    private var liveProbeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Live probe", "OQ-1", "the kill question")

            HStack {
                Picker("App", selection: $selectedAppPID) {
                    Text("Choose…").tag(pid_t(0))
                    ForEach(apps, id: \.pid) { Text($0.name).tag($0.pid) }
                }.frame(width: 260)
                Picker("Display", selection: $selectedDisplayID) {
                    Text("—").tag(CGDirectDisplayID(0))
                    ForEach(displays, id: \.id) {
                        Text("\($0.id)\($0.isMain ? " (main)" : "")").tag($0.id)
                    }
                }.frame(width: 150)
                Button("Reload apps") { apps = AppResolver.runningApps() }
                Spacer()
                if probe.running {
                    Button("Stop", role: .destructive) { probe.stop() }
                } else {
                    Button("Start", action: startProbe)
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedAppPID == 0 || selectedDisplayID == 0)
                }
            }

            legend

            if let err = probe.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption)
            }
            if !probe.statsLine.isEmpty {
                Text(probe.statsLine).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                capturePane
                eventLogPane
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendDot(.red, "app windows")
            legendDot(.orange, "open menu / popup (the thing OQ-1 is about)")
            Text("Tip: pick your app, Start, then open its menu and watch this pane.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func legendDot(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).stroke(c, lineWidth: 2)
                .frame(width: 14, height: 10)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var capturePane: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.88))
            if let img = probe.frameImage {
                Image(nsImage: img).resizable().scaledToFit()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: probe.running ? "hourglass" : "play.circle")
                        .font(.largeTitle).foregroundStyle(.white.opacity(0.5))
                    Text(probe.running ? "waiting for frames…" : "press Start to capture")
                        .foregroundStyle(.white.opacity(0.6)).font(.callout)
                }
            }
        }
        .frame(height: 380)
        .frame(maxWidth: .infinity)
        .cornerRadius(8)
    }

    private var eventLogPane: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Event log").font(.headline)
            Text("menu-opened → AX saw a menu").font(.caption2).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if probe.events.isEmpty {
                        Text("no events yet").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(probe.events) { e in
                        Text(String(format: "%7.2f  %@  %@", e.t, e.kind, e.detail))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(color(for: e.kind))
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 340, height: 380)
    }

    private func color(for kind: String) -> Color {
        switch kind {
        case "menu-opened": return .orange
        case "window-created": return .green
        case "destroyed", "menu-closed": return .secondary
        case "error": return .red
        default: return .primary
        }
    }

    // MARK: - Geometry test

    private var geometrySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Geometry test", "OQ-2", "are AX writes honored?")
            Text(
                "Set a window's position/size via AX, read it back, and compare. The delta is the answer (I-4)."
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker("Window", selection: $geometry.windowIndex) {
                    ForEach(geometry.windows, id: \.index) {
                        Text("[\($0.index)] \($0.title.isEmpty ? $0.role : $0.title)").tag($0.index)
                    }
                }.frame(width: 320)
                Button("Reload windows") { geometry.reload(pid: selectedAppPID) }
            }
            HStack {
                field("x", $geometry.x)
                field("y", $geometry.y)
                field("w", $geometry.w)
                field("h", $geometry.h)
                Button("Apply") { geometry.apply(pid: selectedAppPID) }
                    .disabled(selectedAppPID == 0 || geometry.windows.isEmpty)
            }
            if let r = geometry.result {
                geometryResult(r)
            }
        }
    }

    @ViewBuilder
    private func geometryResult(_ r: PlacementResult) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 2) {
            GridRow {
                Text("").font(.caption)
                Text("requested").font(.caption).bold()
                Text("actual").font(.caption).bold()
                Text("delta").font(.caption).bold()
            }
            GridRow {
                Text("pos").font(.system(.caption, design: .monospaced))
                Text("(\(i(r.requestedPosition.x)),\(i(r.requestedPosition.y)))")
                    .font(.system(.caption, design: .monospaced))
                Text(r.actualPosition.map { "(\(i($0.x)),\(i($0.y)))" } ?? "—")
                    .font(.system(.caption, design: .monospaced))
                Text(r.positionDelta.map { "(\(i($0.x)),\(i($0.y)))" } ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(deltaColor(r.positionDelta.map { $0 == .zero } ?? false))
            }
            GridRow {
                Text("size").font(.system(.caption, design: .monospaced))
                Text("\(i(r.requestedSize.width))x\(i(r.requestedSize.height))")
                    .font(.system(.caption, design: .monospaced))
                Text(r.actualSize.map { "\(i($0.width))x\(i($0.height))" } ?? "—")
                    .font(.system(.caption, design: .monospaced))
                Text(r.sizeDelta.map { "\(i($0.width))x\(i($0.height))" } ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(deltaColor(r.sizeDelta.map { $0 == .zero } ?? false))
            }
        }
        Text("OQ-2: honored exactly? \(r.exact ? "YES" : "NO — clamped/rounded")")
            .font(.caption).bold()
            .foregroundStyle(r.exact ? Color.green : Color.orange)
    }

    private func field(_ label: String, _ binding: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text(label)
            TextField(label, text: binding).frame(width: 70)
        }
    }

    // MARK: - Displays

    private var displaysSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("Displays", nil, nil)
                Button("Refresh", action: refreshAll)
            }
            ForEach(displays, id: \.id) { d in
                Text(
                    "id \(d.id)\(d.isMain ? "  [main]" : "")   "
                        + "\(d.pixelWidth)x\(d.pixelHeight) px   "
                        + "\(Int(d.sizePoints.width))x\(Int(d.sizePoints.height)) pt   "
                        + "scale \(String(format: "%.2f", d.scale))x"
                )
                .font(.system(.body, design: .monospaced))
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, _ tag: String?, _ subtitle: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.title2).bold()
            if let tag {
                Text(tag).font(.caption).bold().padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15)).cornerRadius(4)
            }
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func deltaColor(_ exact: Bool) -> Color { exact ? .green : .orange }
    private func i(_ v: CGFloat) -> Int { Int(v.rounded()) }

    private var currentSettings: ProbeSettings {
        ProbeSettings(
            fps: fps, pollHz: pollHz, showWindowRects: showWindowRects,
            showMenuRects: showMenuRects, showLabels: showLabels)
    }

    private func refreshAll() {
        displays = Displays.all()
        apps = AppResolver.runningApps()
        if selectedDisplayID == 0 {
            selectedDisplayID = displays.first(where: { $0.isMain })?.id ?? displays.first?.id ?? 0
        }
        refreshPermissions()
    }

    private func refreshPermissions() {
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
    }

    private func startProbe() {
        guard let app = apps.first(where: { $0.pid == selectedAppPID }),
            let disp = displays.first(where: { $0.id == selectedDisplayID })
        else { return }
        geometry.reload(pid: app.pid)
        probe.start(app: app, display: disp, settings: currentSettings)
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }
}

/// Backing model for the geometry test. Kept tiny: resolve windows, apply a
/// placement, publish the read-back result.
@MainActor
final class GeometryModel: ObservableObject {
    @Published var windows: [AXWindowInfo] = []
    @Published var windowIndex: Int = 0
    @Published var x = "100"
    @Published var y = "100"
    @Published var w = "1280"
    @Published var h = "800"
    @Published var result: PlacementResult?

    func reload(pid: pid_t) {
        guard pid != 0 else {
            windows = []
            return
        }
        windows = AXWindow.windows(pid: pid).map { $0.info() }
        if !windows.contains(where: { $0.index == windowIndex }) {
            windowIndex = windows.first?.index ?? 0
        }
    }

    func apply(pid: pid_t) {
        let all = AXWindow.windows(pid: pid)
        guard windowIndex >= 0, windowIndex < all.count else { return }
        let pos = CGPoint(x: Double(x) ?? 0, y: Double(y) ?? 0)
        let size = CGSize(width: Double(w) ?? 0, height: Double(h) ?? 0)
        result = all[windowIndex].place(position: pos, size: size)
    }
}
