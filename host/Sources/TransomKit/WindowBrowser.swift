import AppKit
import ApplicationServices
import ScreenCaptureKit

/// All-window discovery is separate from the streaming atlas. Browsing never
/// moves a window. An explicit open admits just that window to the shared set.
public actor WindowBrowser {
    private struct Candidate: @unchecked Sendable {
        let element: AXUIElement
        let capture: SCWindow?
        let info: AvailableWindow
    }
    private let registry: WindowRegistry
    private let display: DisplayInfo
    private let gutter: Int
    private let server: ControlServer
    private var capture: DisplayCapture?
    private var candidates: [UInt64: Candidate] = [:]
    private var active: Set<UInt64> = []
    private var activeCaptures: [UInt64: CGWindowID] = [:]
    private var published: [AvailableWindow] = []
    private var changing = false
    private var stopped = false
    private var previewing = false
    private var lastDiscovery = Date.distantPast
    private var hasPublished = false

    public init(registry: WindowRegistry, display: DisplayInfo, gutter: Int, server: ControlServer) {
        self.registry = registry; self.display = display; self.gutter = gutter; self.server = server
    }
    public func setCapture(_ capture: DisplayCapture) { self.capture = capture }
    public func stop() { stopped = true }

    // Refuse ambiguous matches instead of ever showing the wrong window.
    static func matchIndex(title: String, frame: CGRect, choices: [(String, CGRect)]) -> Int? {
        let exact = choices.indices.filter {
            abs(choices[$0].1.minX - frame.minX) < 2 && abs(choices[$0].1.minY - frame.minY) < 2
                && abs(choices[$0].1.width - frame.width) < 2 && abs(choices[$0].1.height - frame.height) < 2
        }
        if exact.count == 1 { return exact[0] }
        let named = (exact.isEmpty ? Array(choices.indices) : exact).filter { !title.isEmpty && choices[$0].0 == title }
        return named.count == 1 ? named[0] : nil
    }

    public func tick() async {
        guard !changing, !stopped else { return }
        if Date().timeIntervalSince(lastDiscovery) > 1.5 {
            await discover()
        }
        guard !changing, !stopped else { return }
        for id in active.sorted() {
            guard let candidate = candidates[id] else { continue }
            let win = AXWindow(element: candidate.element, index: -1)
            if win.isMinimized {
                await release(id: id)
                continue
            }
            await record(id: id, candidate: candidate)
        }
    }

    private func discover() async {
        lastDiscovery = Date()
        let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard !changing, !stopped else { return }
        var next: [UInt64: Candidate] = [:]
        let apps = AppResolver.runningApps().filter { $0.pid != ProcessInfo.processInfo.processIdentifier }
        for app in apps {
            let axApp = AXWindow.application(pid: app.pid)
            AXUIElementSetMessagingTimeout(axApp, 0.08)
            guard let windows = AXWindow.availableWindows(pid: app.pid) else {
                // A temporarily busy app has not closed its windows.
                for (id, candidate) in candidates {
                    var pid: pid_t = 0
                    if AXUIElementGetPid(candidate.element, &pid) == .success && pid == app.pid { next[id] = candidate }
                }
                continue
            }
            let scWindows = content?.windows.filter { $0.owningApplication?.processID == app.pid && $0.windowLayer == 0 } ?? []
            for win in windows {
                AXUIElementSetMessagingTimeout(win.element, 0.08)
                guard win.role == kAXWindowRole as String,
                    [kAXStandardWindowSubrole as String, kAXDialogSubrole as String].contains(win.subrole),
                    let frame = win.frame(), frame.width > 1, frame.height > 1 else { continue }
                let id = registry.id(for: win.element).id
                let title = win.title.isEmpty || win.title == app.name ? app.name : "\(app.name) — \(win.title)"
                let match = Self.matchIndex(title: win.title, frame: frame, choices: scWindows.map { ($0.title ?? "", $0.frame) })
                next[id] = Candidate(element: win.element, capture: match.map { scWindows[$0] },
                                     info: AvailableWindow(id: id, title: title, minimized: win.isMinimized))
            }
        }
        for (id, old) in candidates where next[id] == nil {
            await release(id: id)
            _ = registry.remove(element: old.element)
        }
        candidates = next
        let items = next.values.map(\.info).sorted { $0.id < $1.id }
        if !hasPublished || items != published {
            hasPublished = true
            published = items
            await server.send(.windowCatalog(windows: items))
        }
    }

    public func open(id: UInt64) async {
        guard !changing, !stopped, let candidate = candidates[id] else {
            await server.send(.error(code: 3, message: "This window is no longer available. Choose another window."))
            return
        }
        if active.contains(id) { await server.send(.windowOpened(id: id)); return }
        changing = true
        defer { changing = false }
        let win = AXWindow(element: candidate.element, index: -1)
        let wasMinimized = win.isMinimized
        if wasMinimized { AXUIElementSetAttributeValue(candidate.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        let ids = active.union([id]).sorted()
        let windows = ids.compactMap { candidates[$0].map { AXWindow(element: $0.element, index: -1) } }
        let originals = windows.map { $0.frame() }
        let result = TileService.layout(windows: windows, display: display, gutter: gutter)
        guard case .success = result else {
            if wasMinimized { AXUIElementSetAttributeValue(candidate.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
            await server.send(.error(code: 3, message: "There isn’t enough room on the Mac display for this window. Hide another window on this PC and try again."))
            return
        }
        do {
            // Refresh SCWindow metadata after an AX move/restore. Only selected
            // windows enter the filter; unrelated apps cannot cover their crops.
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            var selected: [SCWindow] = []
            for window in windows {
                var pid: pid_t = 0
                AXUIElementGetPid(window.element, &pid)
                let choices = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
                guard let frame = window.frame(), let index = Self.matchIndex(title: window.title, frame: frame, choices: choices.map { ($0.title ?? "", $0.frame) }) else {
                    throw ProbeError("macOS has not made this window available for capture yet. Restore it on the Mac and try again.")
                }
                selected.append(choices[index])
            }
            if let capture { try await capture.selectWindows(selected) }
            guard !stopped else { return }
            active.insert(id)
            for (selectedID, window) in zip(ids, selected) { activeCaptures[selectedID] = window.windowID }
            for selectedID in ids {
                if let item = candidates[selectedID] { await record(id: selectedID, candidate: item) }
            }
            await server.send(.windowOpened(id: id))
            capture?.requestRefresh()
        } catch {
            for (window, original) in zip(windows, originals) {
                if let original { _ = window.place(position: original.origin, size: original.size) }
            }
            if wasMinimized { AXUIElementSetAttributeValue(candidate.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
            await server.send(.error(code: 3, message: error.localizedDescription))
        }
    }

    public func release(id: UInt64) async {
        guard active.remove(id) != nil else { return }
        registry.unshare(id: id)
        await server.broadcast(.destroyed(id: id))
        // Remove the exact capture ID without changing any remaining geometry.
        if let capture, let captureID = activeCaptures.removeValue(forKey: id) {
            try? await capture.removeWindow(captureID)
        }
    }

    private func record(id: UInt64, candidate: Candidate) async {
        let win = AXWindow(element: candidate.element, index: -1)
        guard let frame = win.frame() else { return }
        let pixels = Coordinates.displayPixels(fromAXRect: frame, displayOriginPoints: display.originPoints, scale: display.scale)
        guard let rect = WindowWatcher.captureRect(pixels, displayWidth: display.pixelWidth, displayHeight: display.pixelHeight) else { return }
        let old = registry.entry(for: id)
        registry.record(id: id, rect: rect, title: candidate.info.title)
        if old == nil { await server.broadcast(.created(id: id, rect: rect, title: candidate.info.title)) }
        else {
            if old?.rect != rect { await server.broadcast(.moved(id: id, rect: rect)) }
            if old?.title != candidate.info.title { await server.broadcast(.titleChanged(id: id, title: candidate.info.title)) }
        }
    }

    public func preview(id: UInt64) async {
        guard !previewing, !stopped, let window = candidates[id]?.capture else { return }
        previewing = true
        defer { previewing = false }
        let config = SCStreamConfiguration()
        let ratio = min(320 / max(window.frame.width, 1), 200 / max(window.frame.height, 1))
        config.width = max(1, Int(window.frame.width * ratio))
        config.height = max(1, Int(window.frame.height * ratio))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
            guard !stopped, candidates[id] != nil,
                let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7]), jpeg.count <= 128_000 else { return }
            await server.send(.windowPreview(id: id, jpeg: jpeg.base64EncodedString()))
        } catch { /* A hidden/protected window keeps its last preview. */ }
    }
}
