import AppKit
import SwiftUI
import TransomKit

/// The menu bar icon: the chosen symbol, filled while sharing, with the shared
/// window count beside it when that is turned on.
struct MenuBarLabel: View {
    @ObservedObject var host: HostAppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(HostDefaults.menuBarSymbol) private var symbol = MenuBarSymbol.defaultSymbol
    @AppStorage(HostDefaults.menuBarShowsCount) private var showsCount = true

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .symbolVariant(host.running ? .fill : .none)
            if host.running && showsCount {
                Text("\(host.previewWindows.count)").monospacedDigit()
            }
        }
        .accessibilityLabel(host.running ? "Transom, sharing" : "Transom, not sharing")
        .onAppear { MainWindowController.shared.openWindowAction = openWindow }
    }
}

/// The panel under the menu bar icon: what is being shared, Start/Stop, and the
/// way back to the window and Settings.
struct MenuBarPanel: View {
    @ObservedObject var host: HostAppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage(HostDefaults.accentColor) private var accentID = AccentChoice.defaultID

    private var accent: Color { AccentChoice.color(for: accentID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if host.running { sharingSection } else { idleSection }
            if let error = host.startError, !host.running {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .tint(accent)
        .onAppear {
            host.refreshPermissions()
            if !host.running && !host.starting { host.refreshApps() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.title2).foregroundStyle(accent)
                .symbolVariant(host.running ? .fill : .none)
            VStack(alignment: .leading, spacing: 2) {
                Text("Transom Host").font(.headline)
                Text(statusLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(host.running ? (host.status.controlClientConnected ? .green : .orange) : .secondary.opacity(0.4))
                .frame(width: 9, height: 9)
                .help(host.running ? (host.status.controlClientConnected ? "PC connected" : "Waiting for your PC") : "Not sharing")
        }
    }

    private var statusLine: String {
        if host.starting { return "Starting…" }
        guard host.running else { return "Not sharing" }
        let windows = "\(host.previewWindows.count) window\(host.previewWindows.count == 1 ? "" : "s")"
        return host.status.controlClientConnected ? "Sharing \(windows) · PC connected" : "Sharing \(windows) · waiting for your PC"
    }

    private var sharingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if host.previewWindows.isEmpty {
                Text("No windows yet. Open a window in a shared app.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(host.previewWindows.prefix(8)) { window in
                    Label(window.title.isEmpty ? "Untitled window" : window.title, systemImage: "macwindow")
                        .font(.callout).lineLimit(1)
                }
                if host.previewWindows.count > 8 {
                    Text("and \(host.previewWindows.count - 8) more").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(host.status.notices, id: \.self) { notice in
                Label(notice, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if host.running, host.status.videoEnabled {
                Text("\(Int(host.status.measuredFPS)) fps · \(String(format: "%.1f", host.status.measuredBitrateMbps)) Mbps")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            Button(role: .destructive) {
                host.stop()
            } label: {
                Label("Stop Sharing", systemImage: "stop.circle").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
        }
    }

    private var idleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            let selected = host.selectedApps
            if selected.isEmpty {
                Text("No apps chosen yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(selected.prefix(6), id: \.pid) { app in
                        if let icon = NSRunningApplication(processIdentifier: app.pid)?.icon {
                            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                                .help(app.name)
                        }
                    }
                    Text(selected.map(\.name).joined(separator: ", "))
                        .font(.callout).lineLimit(2)
                }
            }
            if let blocker = host.startBlocker {
                Text(blocker).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                host.startSharing()
            } label: {
                Label(host.starting ? "Starting…" : "Start Sharing", systemImage: "play.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!host.canStart)
            Button("Choose Apps…") { showWindow() }
                .buttonStyle(.link).font(.caption)
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Transom Host") { showWindow() }
            Spacer()
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: { Image(systemName: "gearshape") }
                .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: { Image(systemName: "power") }
                .help("Quit Transom Host")
        }
        .buttonStyle(.borderless)
    }

    private func showWindow() {
        MainWindowController.shared.show(openWindow: openWindow)
    }
}
