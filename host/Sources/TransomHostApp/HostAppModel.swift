import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import TransomKit

/// What the app picker shows about an app's windows, so a hidden or minimized
/// app explains itself instead of just looking empty.
struct AppWindowSummary: Equatable, Sendable {
    var windows = 0
    var minimized = 0
    var fullScreen = 0
    var hidden = false

    /// Windows that are not on the display right now but will be brought there
    /// when sharing starts (`WindowRestorer`).
    var offDisplay: Int { hidden ? windows : minimized + fullScreen }
}

/// Drives one `HostSession` from the UI: start it, poll a status snapshot onto
/// `@Published` state a few times a second, and stop it. All the real work lives
/// in `HostSession`; this is the SwiftUI-side adapter, deliberately thin.
///
/// It also owns the setup the main window and the menu bar share (which apps and
/// display, permissions, the address), so sharing can start and stop from the
/// menu bar with the window closed. One instance, `shared`, for the app's life.
@MainActor
final class HostAppModel: ObservableObject {
    static let shared = HostAppModel()

    @Published var running = false
    @Published var starting = false
    @Published var status = HostStatus()
    @Published var startError: String?

    /// Live stream-preview state, refreshed on a faster timer than `status` so the
    /// picture and the window overlays feel live (window moves during a client
    /// drag come in around 10Hz). Driven by `HostSession.preview()`.
    @Published var previewImage: NSImage?
    @Published var previewWindows: [PreviewWindow] = []
    @Published var displayPixelSize: CGSize = .zero

    @Published var displays: [DisplayInfo] = []
    @Published var apps: [TargetApp] = []
    @Published var summaries: [pid_t: AppWindowSummary] = [:]
    @Published private(set) var selectedPIDs: Set<pid_t> = []
    @Published var selectedDisplayID: CGDirectDisplayID = 0
    @Published var screenRecording = false
    @Published var accessibility = false
    @Published var detectedAddress = HostDiscovery.localAddresses().first ?? ""
    /// The address the running session is bound to, pinned while it runs.
    @Published var activeAddress: String?

    /// Whether the main window is on screen. The preview image is only rendered
    /// for it; the menu bar needs the window list, not the picture.
    var previewVisible = true

    private var session: HostSession?
    private var pollTimer: Timer?
    private var previewTimer: Timer?
    private var housekeepingTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var refreshAppsPending = false
    private var autoStartDeadline: Date?

    /// How often the preview panel refreshes. ~12Hz is smooth enough for a control
    /// panel while staying cheap (each tick resamples one downscaled frame).
    private static let previewInterval = 1.0 / 12.0

    private init() {}

    // MARK: - Setup

    /// Start the background upkeep: permissions and the LAN address every 1.5 s,
    /// and the app list whenever an app launches, quits, hides or is shown.
    func activate() {
        guard housekeepingTimer == nil else { return }
        refreshAll()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.housekeeping() }
        }
        RunLoop.main.add(timer, forMode: .common)
        housekeepingTimer = timer

        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ]
        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleAppRefresh() }
            }
        }
    }

    func refreshAll() {
        HostDefaults.repairStaleBindAddress()
        displays = Displays.all()
        if selectedDisplayID == 0 || !displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = displays.first(where: { $0.isMain })?.id ?? displays.first?.id ?? 0
        }
        refreshApps()
        refreshPermissions()
    }

    func refreshApps() {
        let includeAccessory = UserDefaults.standard.bool(forKey: HostDefaults.showAccessoryApps)
        let own = ProcessInfo.processInfo.processIdentifier
        let previous = apps.filter { selectedPIDs.contains($0.pid) }
        apps = AppResolver.runningApps(includingAccessoryApps: includeAccessory)
            .filter { $0.pid != own }
        // Selection is remembered by bundle id, so an app that relaunches (new
        // pid) or starts after Transom stays chosen. An app with no bundle id can
        // only be remembered by pid, for as long as it runs.
        let saved = savedBundleIDs
        let previousPIDs = Set(previous.filter { $0.bundleID == nil }.map(\.pid))
        selectedPIDs = Set(
            apps.filter { app in
                app.bundleID.map(saved.contains) ?? previousPIDs.contains(app.pid)
            }.map(\.pid))
        refreshSummaries()
    }

    func refreshPermissions() {
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
    }

    func isSelected(_ app: TargetApp) -> Bool { selectedPIDs.contains(app.pid) }

    func toggle(_ app: TargetApp) {
        var saved = savedBundleIDs
        if selectedPIDs.contains(app.pid) {
            selectedPIDs.remove(app.pid)
            if let id = app.bundleID { saved.remove(id) }
        } else {
            selectedPIDs.insert(app.pid)
            if let id = app.bundleID { saved.insert(id) }
        }
        savedBundleIDs = saved
    }

    var selectedApps: [TargetApp] { apps.filter { selectedPIDs.contains($0.pid) } }

    private var savedBundleIDs: Set<String> {
        get {
            Set(
                (UserDefaults.standard.string(forKey: HostDefaults.sharedApps) ?? "")
                    .split(separator: "\n").map(String.init))
        }
        set {
            UserDefaults.standard.set(newValue.sorted().joined(separator: "\n"), forKey: HostDefaults.sharedApps)
        }
    }

    private func scheduleAppRefresh() {
        guard !refreshAppsPending else { return }
        refreshAppsPending = true
        // Launch and activation notifications arrive in bursts; one refresh
        // after they settle is enough.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshAppsPending = false
                if !self.running && !self.starting { self.refreshApps() }
            }
        }
    }

    /// Read every app's window state off the main thread: AX messages a busy app
    /// synchronously, and one beachballing app must not stall the window.
    private func refreshSummaries() {
        guard AXIsProcessTrusted() else {
            summaries = [:]
            return
        }
        let pids = apps.map(\.pid)
        Task.detached(priority: .utility) { [weak self] in
            var result: [pid_t: AppWindowSummary] = [:]
            for pid in pids { result[pid] = Self.summary(pid: pid) }
            await MainActor.run { [result] in self?.summaries = result }
        }
    }

    nonisolated private static func summary(pid: pid_t) -> AppWindowSummary {
        let windows = AXWindow.windows(pid: pid).filter { $0.role == (kAXWindowRole as String) }
        return AppWindowSummary(
            windows: windows.count,
            minimized: windows.filter(\.isMinimized).count,
            fullScreen: windows.filter(\.isFullScreen).count,
            hidden: AXWindow.isApplicationHidden(pid: pid))
    }

    private func housekeeping() {
        refreshPermissions()
        if !running && !starting {
            activeAddress = nil
            detectedAddress = HostDiscovery.localAddresses().first ?? ""
        }
        autoStartTick()
    }

    // MARK: - Readiness

    private var defaults: UserDefaults { .standard }
    private var videoEnabled: Bool { defaults.bool(forKey: HostDefaults.video) }
    private var automaticAddress: Bool { defaults.bool(forKey: HostDefaults.automaticAddress) }
    private var bindAddress: String { defaults.string(forKey: HostDefaults.bindAddress) ?? "127.0.0.1" }
    private var controlPort: Int { defaults.integer(forKey: HostDefaults.controlPort) }
    private var videoPort: Int { defaults.integer(forKey: HostDefaults.videoPort) }

    var effectiveAddress: String { activeAddress ?? (automaticAddress ? detectedAddress : bindAddress) }
    var hostIsAssigned: Bool {
        effectiveAddress.hasPrefix("127.") || HostDiscovery.localAddresses().contains(effectiveAddress)
    }
    var permissionsReady: Bool { accessibility && (!videoEnabled || screenRecording) }
    var portsValid: Bool {
        HostDefaults.portRange.contains(controlPort) && HostDefaults.portRange.contains(videoPort)
            && (!videoEnabled || controlPort != videoPort)
    }

    /// Why sharing cannot start right now, in words, or nil when it can.
    var startBlocker: String? {
        if !accessibility { return "Allow Accessibility in System Settings." }
        if videoEnabled && !screenRecording { return "Allow Screen Recording in System Settings." }
        if selectedPIDs.isEmpty { return "Choose at least one app to share." }
        if selectedDisplayID == 0 { return "Choose a sharing display." }
        if !PrivateAddress.isPrivateIPv4(effectiveAddress) || !hostIsAssigned {
            return "Connect this Mac to Ethernet or Wi-Fi."
        }
        if !portsValid { return "Choose valid, different ports in Settings." }
        return nil
    }

    var canStart: Bool { startBlocker == nil && !starting && !running }

    // MARK: - Sharing

    /// Start sharing the selected apps with the current settings. Safe to call
    /// from the menu bar: the app list is refreshed first, since pids go stale.
    func startSharing() {
        guard !running, !starting else { return }
        refreshApps()
        refreshPermissions()
        if let blocker = startBlocker {
            startError = blocker
            return
        }
        let targets = selectedApps
        guard let first = targets.first,
            let display = displays.first(where: { $0.id == selectedDisplayID })
        else { return }
        let address = automaticAddress ? (HostDiscovery.localAddresses().first ?? "") : bindAddress
        guard PrivateAddress.isPrivateIPv4(address) else {
            startError = "Connect this Mac to Ethernet or Wi-Fi before sharing."
            return
        }
        activeAddress = address
        let d = defaults
        start(
            config: HostConfig(
                target: first, additionalTargets: Array(targets.dropFirst()),
                display: display, host: address, controlPort: UInt16(clamping: controlPort),
                videoPort: UInt16(clamping: videoPort), gutter: d.integer(forKey: HostDefaults.gutter),
                tile: true, video: videoEnabled, bitrateMbps: d.integer(forKey: HostDefaults.bitrateMbps),
                fps: d.integer(forKey: HostDefaults.fps),
                videoFormat: HEVCEncoder.Format(rawValue: d.string(forKey: HostDefaults.chroma) ?? "")
                    ?? .hevc420_8bit,
                namesakeModifiers: d.bool(forKey: HostDefaults.namesakeModifiers),
                logInput: d.bool(forKey: HostDefaults.logInput),
                inputDelivery: d.bool(forKey: HostDefaults.foregroundInput) ? .foreground : .background,
                restoreWindows: d.bool(forKey: HostDefaults.restoreWindows)))
    }

    /// Arm "start sharing at launch". Apps opened at login may still be
    /// launching, so keep trying for a minute rather than once.
    func scheduleAutoStart() {
        guard defaults.bool(forKey: HostDefaults.startSharingOnLaunch) else { return }
        autoStartDeadline = Date().addingTimeInterval(60)
        autoStartTick()
    }

    private func autoStartTick() {
        guard let deadline = autoStartDeadline else { return }
        if running || starting {
            autoStartDeadline = nil
            return
        }
        if selectedPIDs.isEmpty { refreshApps() }
        if canStart {
            autoStartDeadline = nil
            Log.app.info("starting to share at launch")
            startSharing()
        } else if Date() > deadline {
            autoStartDeadline = nil
            startError = "Could not start sharing at launch. \(startBlocker ?? "")"
        }
    }

    func start(config: HostConfig) {
        guard session == nil else { return }
        startError = nil
        starting = true
        let session = HostSession(config: config)
        self.session = session
        Task { @MainActor in
            do {
                try await session.start()
                self.running = true
                self.starting = false
                self.status = session.status()
                self.startPolling()
                self.startPreview()
            } catch {
                self.startError = "\(error)"
                self.starting = false
                self.session = nil
                self.activeAddress = nil
            }
        }
    }

    func stop() {
        guard let session = detachSession() else { return }
        Task { await session.stop() }
    }

    /// Stop and wait for the sockets and capture to close, for a clean quit.
    func stopAndWait() async {
        guard let session = detachSession() else { return }
        await session.stop()
    }

    private func detachSession() -> HostSession? {
        pollTimer?.invalidate()
        pollTimer = nil
        previewTimer?.invalidate()
        previewTimer = nil
        let session = self.session
        self.session = nil
        running = false
        starting = false
        status = HostStatus()
        previewImage = nil
        previewWindows = []
        displayPixelSize = .zero
        activeAddress = nil
        refreshApps()
        return session
    }

    private func startPolling() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        guard let session else { return }
        status = session.status()
    }

    private func startPreview() {
        let timer = Timer(timeInterval: Self.previewInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollPreview() }
        }
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
    }

    private func pollPreview() {
        guard let session else { return }
        let snap = session.preview()
        let showImages = previewVisible && defaults.bool(forKey: HostDefaults.showThumbnails)
        if showImages, let cg = snap.image {
            previewImage = NSImage(
                cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } else if previewImage != nil {
            previewImage = nil
        }
        let windows = snap.windows.map(PreviewWindow.init(entry:))
        if windows != previewWindows { previewWindows = windows }
        let size = CGSize(width: snap.displayPixelWidth, height: snap.displayPixelHeight)
        if size != displayPixelSize { displayPixelSize = size }
    }
}
