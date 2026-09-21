import ApplicationServices
import CoreGraphics
import CoreMedia
import Foundation

/// Everything needed to start serving one app on one display: the same knobs the
/// `serve` CLI takes, in one `Sendable` value the host app can also build.
public struct HostConfig: Sendable {
    public var target: TargetApp
    public var additionalTargets: [TargetApp]
    public var clientWindowSelection: Bool
    public var display: DisplayInfo
    public var host: String
    public var controlPort: UInt16
    public var videoPort: UInt16
    public var gutter: Int
    public var tile: Bool
    public var video: Bool
    public var bitrateMbps: Int
    public var fps: Int
    /// Chroma / bit-depth the video is encoded at. Defaults to the mode the
    /// Windows in-box decoder can decode (4:2:0 8-bit); `.hevc444_10bit` is the
    /// crisp-text target for a 4:4:4-capable client (protocol.md §6-7).
    public var videoFormat: HEVCEncoder.Format
    /// Map Windows modifiers namesake (Ctrl→Control) instead of the default swap
    /// (Ctrl→Command). The Cmd-vs-Ctrl product decision for input (issue #7).
    public var namesakeModifiers: Bool
    /// Print the full coordinate/keycode chain for each injected input event.
    public var logInput: Bool

    public init(
        target: TargetApp,
        additionalTargets: [TargetApp] = [],
        clientWindowSelection: Bool = false,
        display: DisplayInfo,
        host: String = "127.0.0.1",
        controlPort: UInt16 = TransomPorts.control,
        videoPort: UInt16 = TransomPorts.video,
        gutter: Int = Tiler.defaultGutter,
        tile: Bool = true,
        video: Bool = true,
        bitrateMbps: Int = 40,
        fps: Int = 60,
        videoFormat: HEVCEncoder.Format = .hevc420_8bit,
        namesakeModifiers: Bool = false,
        logInput: Bool = false
    ) {
        self.target = target
        self.clientWindowSelection = clientWindowSelection
        var seen: Set<pid_t> = [target.pid]
        self.additionalTargets = additionalTargets.filter { seen.insert($0.pid).inserted }
        self.display = display
        self.host = host
        self.controlPort = controlPort
        self.videoPort = videoPort
        self.gutter = gutter
        self.tile = tile
        self.video = video
        self.bitrateMbps = bitrateMbps
        self.fps = fps
        self.videoFormat = videoFormat
        self.namesakeModifiers = namesakeModifiers
        self.logInput = logInput
    }
}

/// A live snapshot of a running `HostSession`, cheap to poll from any thread.
///
/// This is what the host app's Status section renders and what a periodic `serve`
/// status line prints. All rate numbers are measured on the host (fps/bitrate over
/// a short sliding window; `encodeLatencyMillis` is the capture→encoded-frame
/// pipeline latency). End-to-end network latency is deliberately absent: the host
/// cannot measure it without the client's cooperation, and reporting a guess would
/// be worse than reporting nothing.
public struct HostStatus: Sendable {
    public var running = false
    public var videoEnabled = false

    public var controlClientConnected = false
    public var videoClientConnected = false

    /// Frames/sec and Mbps measured over the last ~1.5 s of encoded output.
    public var measuredFPS = 0.0
    public var measuredBitrateMbps = 0.0
    /// Mean host-side pipeline latency (capture handoff → encoded frame), in ms.
    public var encodeLatencyMillis = 0.0
    public var totalFramesEncoded = 0

    /// VideoToolbox's own read-back of whether the encoder is on the hardware path.
    public var usingHardware = false
    /// The chroma / bit-depth the encoder was configured to produce. Known before
    /// the first frame, so the UI/CLI can show the mode immediately.
    public var videoFormat: HEVCEncoder.Format = .hevc420_8bit
    /// The codec + chroma the encoder reports it is producing (e.g. "hvc1 … 4:2:0
    /// 8-bit"), captured on the first encoded frame.
    public var encoderFormatSummary = "—"

    /// The startup tile layout with post-clamp actual rects and deltas (I-4/OQ-2).
    public var tilePlacements: [TilePlacement] = []
    /// Set if the tiler could not lay the window set out (surfaced, not swallowed).
    public var tileError: String?
    /// Live count of windows the AX watcher currently tracks.
    public var liveWindowCount = 0

    public init() {}

    /// Is the encoder healthy — i.e. actually on the hardware path for whatever
    /// chroma was selected? A silent fall to software is the real failure (it can't
    /// keep 60fps); running 4:2:0 by choice is not. The UI shows this as OK/degraded.
    public var encoderHardwareOK: Bool { usingHardware }

    /// Are we specifically on the 4:4:4 10-bit hardware path (the crisp-text
    /// target)? `true` only when hardware *and* 4:4:4 was selected. Distinct from
    /// `encoderHardwareOK`: 4:2:0 is decodable-by-default, not a fallback.
    public var encoderIs444Hardware: Bool {
        usingHardware && videoFormat == .hevc444_10bit
    }
}

/// A cheap, poll-on-demand snapshot for the host app's live stream preview: the
/// frame currently being encoded (nil when video is off or before the first frame)
/// plus every window the AX watcher is tracking, with its **VDS-pixel** rect and id
/// (protocol.md §3). The selector image is reduced on the GPU before readback;
/// window rects still refer to the native display. This is a viewport onto the
/// session, never a fork of the capture path.
///
/// Not `Sendable` on purpose — it carries a `CGImage` and is meant to be read
/// synchronously on the main thread (the UI's timer), never sent across a task.
public struct HostPreview {
    public var windowImages: [UInt64: CGImage] = [:]
    public var image: CGImage?
    public var windows: [WindowRegistry.Entry]
    public var displayPixelWidth: Int
    public var displayPixelHeight: Int

    public init(
        image: CGImage?, windows: [WindowRegistry.Entry],
        displayPixelWidth: Int, displayPixelHeight: Int
    ) {
        self.image = image
        self.windows = windows
        self.displayPixelWidth = displayPixelWidth
        self.displayPixelHeight = displayPixelHeight
    }
}

/// The serving pipeline for one app on one display, extracted from the `serve`
/// command so the CLI and the SwiftUI host app drive the **same** code (the app
/// is a thin shell over `serve`, not a fork of it).
///
/// It tiles the app's windows once at startup (I-5), watches them via AX and
/// streams lifecycle + geometry on the control channel, and — with `video` —
/// captures the display and HEVC-encodes it in hardware (chroma per
/// `config.videoFormat`, default 4:2:0 8-bit so the client's in-box decoder shows
/// pixels) on a second channel. Capture and AX never stop while a client comes and
/// goes; a reconnect resyncs from the registry (see `ControlServer`).
///
/// ### Concurrency
/// `@unchecked Sendable` on the same confinement invariant the rest of this
/// package uses: `start()`/`stop()` are lifecycle calls the owner serializes (the
/// UI disables Start while running), and every field a background thread touches —
/// the encoder/capture callbacks and the connection callbacks — is either itself
/// thread-safe (`WindowRegistry`) or guarded by `statsLock` here. `status()` reads
/// only that locked snapshot, so it is safe to call from the main thread on a timer.
public final class HostSession: @unchecked Sendable {
    public let config: HostConfig

    // Lifecycle-owned; mutated only inside start()/stop().
    private var registry: WindowRegistry?
    private var watchers: [WindowWatcher] = []
    private var watcherRunLoop: CFRunLoop?
    private var controlListener: TCPListener?
    private var videoListener: SocketVideoListener?
    private var controlServer: ControlServer?
    private var videoServer: VideoServer?
    private var windowVideo: WindowVideoHub?
    private var windowPreviews: WindowPreviewCache?
    private var capture: DisplayCapture?
    private var encoder: HEVCEncoder?
    private var eventSink: AsyncStream<WindowWatcher.WindowEvent>.Continuation?
    private var clientSink: AsyncStream<ClientMessage>.Continuation?
    private var injector: InputInjector?
    private var cursorMonitor: CursorMonitor?
    private var browser: WindowBrowser?
    private var tasks: [Task<Void, Never>] = []

    // Everything a background callback writes lives behind this lock.
    private let statsLock = NSLock()
    private var isRunning = false
    private var controlConnected = false
    private var videoConnected = false
    private var totalFrames = 0
    private var encoderFormatSummary = "—"
    private var usingHardware = false
    private var tilePlacements: [TilePlacement] = []
    private var tileError: String?
    private var videoEnabled = false
    /// (uptimeNanos, compressedBytes) of recently encoded frames, trimmed to a
    /// short window so fps/bitrate reflect *now*, not the whole session.
    private var frameSamples: [(t: UInt64, bytes: Int)] = []
    /// FIFO of capture-handoff timestamps awaiting their encoded output, so each
    /// output frame can be matched to its input for a latency measurement. Encoded
    /// output is in input order (frame reordering is off), so front-matching holds.
    private var pendingEncodeStarts: [UInt64] = []
    private var latencySamplesMs: [Double] = []

    /// Sliding window for the fps/bitrate estimate.
    private static let rateWindowNanos: UInt64 = 1_500_000_000

    public init(config: HostConfig) {
        self.config = config
    }

    /// A snapshot of the current state. Cheap; safe from any thread.
    public func status() -> HostStatus {
        var s = HostStatus()
        let liveCount = registry?.snapshot().count ?? 0
        statsLock.withLock {
            trimRateWindowLocked()
            s.running = isRunning
            s.videoEnabled = videoEnabled
            s.controlClientConnected = controlConnected
            s.videoClientConnected = videoConnected
            s.totalFramesEncoded = totalFrames
            s.usingHardware = usingHardware
            s.videoFormat = config.videoFormat
            s.encoderFormatSummary = encoderFormatSummary
            s.tilePlacements = tilePlacements
            s.tileError = tileError
            let (fps, mbps) = rateLocked()
            s.measuredFPS = fps
            s.measuredBitrateMbps = mbps
            s.encodeLatencyMillis =
                latencySamplesMs.isEmpty
                ? 0 : latencySamplesMs.reduce(0, +) / Double(latencySamplesMs.count)
        }
        s.liveWindowCount = liveCount
        return s
    }

    /// The latest capture frame + the live window rects, for the host app's
    /// stream-preview panel. Cheap enough to poll ~10 times/sec; reads the same
    /// live capture and registry the stream uses, so the panel shows exactly what
    /// is going out. Only this UI preview is reduced to 1280 pixels wide; streamed
    /// interactive pixels remain native (I-1). `image` is nil when video is off or no frame has
    /// arrived yet; `windows` is still populated (control-only sessions have a
    /// window layout but no pixels). Call on the main thread — it is not `Sendable`.
    public func preview() -> HostPreview {
        var snapshot = HostPreview(
            image: capture?.latestImage(maxPixelWidth: 1280),
            windows: registry?.snapshot() ?? [],
            displayPixelWidth: config.display.pixelWidth,
            displayPixelHeight: config.display.pixelHeight)
        snapshot.windowImages = windowPreviews?.images() ?? [:]
        return snapshot
    }

    // MARK: - Lifecycle

    /// Tile, start the AX watcher + control server, and (if `video`) the capture +
    /// encoder + video server. Returns once everything is listening and the initial
    /// registry is seeded, so a client connecting immediately gets a full resync.
    /// Throws with a plain message if a permission or bind precondition fails.
    public func start() async throws {
        do {
            try await startImpl()
        } catch {
            // A video bind failure, watcher error, or permission race can happen
            // after part of the session is live. Always tear down the partial
            // graph before surfacing the error so retrying from the UI is safe.
            await stop()
            throw error
        }
    }

    private func startImpl() async throws {
        try preflight()

        let disp = config.display
        let registry = WindowRegistry()
        self.registry = registry
        let vdsSize = WireSize(w: UInt32(disp.pixelWidth), h: UInt32(disp.pixelHeight))

        // Tile once at startup so streamed windows are non-overlapping (I-5), and
        // keep the requested-vs-actual placements for the Status view (I-4/OQ-2).
        let targets = config.clientWindowSelection ? [] : [config.target] + config.additionalTargets
        if config.tile {
            switch TileService.layout(pids: targets.map(\.pid), display: disp, gutter: config.gutter, fit: true)
            {
            case .success(let placements):
                statsLock.withLock { tilePlacements = placements }
            case .failure(let error):
                statsLock.withLock { tileError = error.description }
                throw ProbeError("The selected windows do not fit on the sharing display. Choose fewer apps or a larger display. \(error.description)")
            }
        }

        // Control channel: AX events -> ordered broadcast via one AsyncStream.
        let (events, eventSink) = AsyncStream.makeStream(of: WindowWatcher.WindowEvent.self)
        self.eventSink = eventSink
        let watchers = targets.map { target in
            let watcher = WindowWatcher(pid: target.pid, display: disp, registry: registry,
                appName: target.name)
            watcher.onEvent = { event in eventSink.yield(event) }
            if config.tile {
                let pids = targets.map(\.pid)
                let gutter = config.gutter
                watcher.prepareNewWindow = { [weak self] element in
                    switch TileService.layout(pids: pids, display: disp, gutter: gutter, fit: true) {
                    case .success(let placements):
                        self?.statsLock.withLock { self?.tilePlacements = placements; self?.tileError = nil }
                        return true
                    case .failure(let error):
                        // Keep a rejected new document from covering another
                        // shared crop. The document remains open and can be restored.
                        let minimized = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                        let message = minimized == .success
                            ? "The new window does not fit on the sharing display and was minimized. Share fewer apps, then restore it on the Mac."
                            : "The new window does not fit and could not be minimized. Stop sharing and choose fewer apps."
                        self?.statsLock.withLock { self?.tileError = error.description }
                        eventSink.yield(.sharingFailed(message: message))
                        return false
                    }
                }
            }
            return watcher
        }
        self.watchers = watchers

        // Phase 4 (issue #6): the geometry roundtrip. Client RequestResize is
        // throttled (~10Hz), written to AX, read back, and emitted as windowMoved
        // (ACTUAL geometry, I-4) through the same ordered event stream, so both this
        // CLI and the host app get resize for free.
        let resize = ResizeService(
            registry: registry, display: disp, gutter: config.gutter, independentWindows: config.clientWindowSelection,
            emit: { event in eventSink.yield(event) })

        // Phase 5 (issue #7): input injection. Client Input/RequestFocus become
        // CGEvents + AX raises, translating window-local pixels through the one
        // coordinate function (I-3). Modifier mapping is the Cmd-vs-Ctrl decision
        // (default swaps Ctrl→Command). Shared by the CLI and the host app.
        let injector = InputInjector(
            display: disp, registry: registry,
            modifierMap: config.namesakeModifiers ? .namesake : .swap)
        if config.logInput { injector.onTrace = { line in print("  \(line)") } }
        self.injector = injector

        let (clientMessages, clientSink) = AsyncStream.makeStream(of: ClientMessage.self)
        self.clientSink = clientSink

        let controlServer = ControlServer(vdsSize: vdsSize, registry: registry, gutter: config.gutter, independentWindows: config.clientWindowSelection)
        self.controlServer = controlServer
        let cursorMonitor = CursorMonitor(registry: registry, display: disp) { message in
            Task { await controlServer.send(message) }
        }
        self.cursorMonitor = cursorMonitor
        let browser: WindowBrowser? = config.clientWindowSelection
            ? WindowBrowser(registry: registry, display: disp, gutter: config.gutter, server: controlServer) : nil
        self.browser = browser
        // Mouse/key events must not wait behind slow AX resize writes.
        await controlServer.setOnClientMessage { message in
            switch message {
            case .input, .requestFocus:
                injector.handle(message)
                cursorMonitor.observe(message)
            case .previewWindow(let id):
                Task { await browser?.preview(id: id) }
            default: clientSink.yield(message)
            }
        }
        await controlServer.setOnConnectionChange { [weak self] connected in
            self?.statsLock.withLock { self?.controlConnected = connected }
            // A dropped client leaves no modifier held for the next one (issue #7).
            if !connected { injector.resetModifiers(); cursorMonitor.reset() }
        }
        let controlListener = try TCPListener(
            host: config.host, port: config.controlPort, label: "control")
        self.controlListener = controlListener

        // Start the AX watcher on its own run-loop thread and wait until it has
        // registered + seeded the registry (same handshake the CLI used).
        let ctx = WatcherThreadBox()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let watcherThread = Thread {
                ctx.runLoop = CFRunLoopGetCurrent()
                do {
                    for watcher in watchers { try watcher.start() }
                    cont.resume()
                } catch {
                    for watcher in watchers { watcher.stop() }
                    cont.resume(throwing: error)
                    return
                }
                CFRunLoopRun()
                for watcher in watchers { watcher.stop() }
            }
            watcherThread.stackSize = 1 << 20
            watcherThread.start()
        }
        self.watcherRunLoop = ctx.runLoop

        tasks.append(Task { await controlServer.serve(listener: controlListener) })
        tasks.append(
            Task {
                for await event in events { await controlServer.broadcast(event) }
            })
        // Drive resize requests in arrival order (AX writes serialise on the actor),
        // and tick at ~20Hz so a coalesced live from a paused drag still flushes.
        tasks.append(
            Task {
                for await message in clientMessages {
                    switch message {
                    case .openWindow(let id):
                        await browser?.open(id: id)
                    case .releaseWindow(let id):
                        await browser?.release(id: id)
                    case .previewWindow: break
                    case let .requestResize(id, size, phase):
                        await resize.handle(id: id, size: size, phase: phase)
                    case let .commitResize(id, size, request):
                        await resize.handle(id: id, size: size, phase: .end)
                        if let rect = registry.snapshot().first(where: { $0.id == id })?.rect {
                            await controlServer.send(.resizeCompleted(id: id, rect: rect, request: request))
                            capture?.requestRefresh()
                        }
                    case .input, .requestFocus:
                        injector.handle(message)
                    case let .requestClose(id):
                        injector.close(id: id)
                    case .requestKeyframe:
                        await windowVideo?.refresh()
                        // A client may deliberately drop stale compressed frames
                        // to protect interaction latency. Restart its dependency
                        // chain at the next encoded frame.
                        encoder?.requestKeyframe()
                        capture?.requestRefresh()
                    }
                }
            })
        tasks.append(
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    await resize.tick()
                }
            })
        try await controlListener.start()

        if config.video {
            try await startVideo(disp: disp, vdsSize: vdsSize)
            statsLock.withLock { videoEnabled = true }
        }

        if let browser {
            if let windowVideo { await browser.setVideo(windowVideo) }
            await browser.tick()
            tasks.append(Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(150))
                    await browser.tick()
                }
            })
        }

        controlListener.advertise(
            address: config.host, videoPort: config.video ? config.videoPort : nil)
        statsLock.withLock { isRunning = true }
    }

    private func startVideo(disp: DisplayInfo, vdsSize: WireSize) async throws {
        if config.clientWindowSelection {
            let hub = WindowVideoHub(config: config, connectionChanged: { [weak self] connected in
                self?.statsLock.withLock { self?.videoConnected = connected }
            }, encoded: { [weak self] frame, summary, hardware in
                self?.statsLock.withLock { self?.usingHardware = hardware }
                self?.recordEncodedFrame(frame, formatSummary: summary)
            })
            windowVideo = hub
            windowPreviews = await hub.previews
            let listener = try SocketVideoListener(host: config.host, port: config.videoPort)
            videoListener = listener
            listener.start()
            tasks.append(Task { await hub.serve(listener: listener) })
            tasks.append(Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { break }
                    await hub.tick()
                }
            })
            return
        }
        let enc = try HEVCEncoder(
            config: HEVCEncoder.Config(
                width: disp.pixelWidth, height: disp.pixelHeight, fps: config.fps,
                bitrateBitsPerSecond: config.bitrateMbps * 1_000_000,
                maxKeyFrameInterval: config.fps * 2, format: config.videoFormat))
        enc.extractFrameData = true
        self.encoder = enc
        statsLock.withLock { usingHardware = enc.usingHardware }

        let cap = DisplayCapture(display: disp, fps: config.fps,
            applicationPIDs: Set(([config.target] + config.additionalTargets).map(\.pid)),
            pixelFormat: config.videoFormat.capturePixelFormat,
            selectedWindows: config.clientWindowSelection ? [] : nil)
        self.capture = cap

        let videoServer = VideoServer(hvccProvider: { enc.parameterSetsHVCC }, requestKeyframe: { [weak enc, weak cap] in
            enc?.requestKeyframe()
            cap?.requestRefresh()
        })
        self.videoServer = videoServer
        await videoServer.setOnConnectionChange { [weak self, weak enc, weak cap] connected in
            self?.statsLock.withLock { self?.videoConnected = connected }
            if connected {
                enc?.requestKeyframe()
                cap?.requestRefresh()
            }
        }
        let listener = try SocketVideoListener(host: config.host, port: config.videoPort)
        self.videoListener = listener

        let (frames, frameSink) = AsyncStream.makeStream(
            of: HEVCEncoder.EncodedFrame.self, bufferingPolicy: .bufferingNewest(4))
        enc.onEncodedFrame = { [weak self, weak enc] frame in
            // Read the encoder directly instead of self.encoder on a VT thread;
            // keep it weak so the callback does not retain its own encoder.
            self?.recordEncodedFrame(frame, formatSummary: enc?.outputFormatSummary ?? "unknown")
            if case .dropped = frameSink.yield(frame) {
                enc?.requestKeyframe()
            }
        }

        let frameDuration = CMTimeMake(value: 1, timescale: Int32(config.fps))
        cap.onPixelBuffer = { [weak self] pixelBuffer, pts in
            self?.markEncodeStart()
            try? enc.encode(pixelBuffer, pts: pts, duration: frameDuration)
        }
        try await cap.start()

        listener.start()
        tasks.append(Task { await videoServer.serve(listener: listener) })
        tasks.append(Task { for await f in frames { await videoServer.send(f) } })
        tasks.append(Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(300)) }
                catch { break }
                if await videoServer.hasClient { cap.requestIdleRefresh() }
            }
        })
    }

    /// Stop everything and reset to a clean state. Safe to call more than once.
    public func stop() async {
        cursorMonitor?.stop()
        await browser?.stop()
        controlListener?.stop()
        videoListener?.stop()
        await controlServer?.stop()
        await videoServer?.stop()
        await windowVideo?.stop()
        if let capture { await capture.stop() }
        encoder?.finish()
        eventSink?.finish()
        clientSink?.finish()
        for task in tasks { task.cancel() }
        // Stopping its run loop ends the watcher thread; the AXObserver and its
        // source are released when the watcher deallocates below.
        if let runLoop = watcherRunLoop { CFRunLoopStop(runLoop) }

        tasks = []
        registry = nil
        watchers = []
        watcherRunLoop = nil
        controlListener = nil
        videoListener = nil
        controlServer = nil
        videoServer = nil
        windowVideo = nil
        windowPreviews = nil
        capture = nil
        encoder = nil
        eventSink = nil
        clientSink = nil
        injector = nil
        cursorMonitor = nil
        browser = nil

        statsLock.withLock {
            isRunning = false
            controlConnected = false
            videoConnected = false
            videoEnabled = false
            frameSamples = []
            pendingEncodeStarts = []
            latencySamplesMs = []
        }
    }

    // MARK: - Preconditions

    private func preflight() throws {
        guard AXIsProcessTrusted() else {
            throw ProbeError(
                "Accessibility is not granted. Grant it in System Settings and relaunch "
                    + "(compare against `transom-host doctor`).")
        }
        if config.video && !CGPreflightScreenCaptureAccess() {
            throw ProbeError(
                "Screen Recording is not granted, which is required to capture and encode video.")
        }
        guard PrivateAddress.isPrivateIPv4(config.host) else {
            throw ProbeError(TransportError.refusedPublicBind(config.host).description)
        }
        let addressIsAssigned = config.host.hasPrefix("127.")
            || HostDiscovery.localAddresses().contains(config.host)
        guard addressIsAssigned else {
            throw ProbeError(
                TransportError.addressNotAvailable(
                    config.host, available: HostDiscovery.localAddresses()
                ).description
            )
        }
        if config.video && config.controlPort == config.videoPort {
            throw ProbeError("control and video ports must be different")
        }
    }

    // MARK: - Stats (called from capture / VideoToolbox threads)

    private func markEncodeStart() {
        let now = DispatchTime.now().uptimeNanoseconds
        statsLock.withLock {
            pendingEncodeStarts.append(now)
            // Bound the queue: if output ever lags input, drop the oldest so the
            // latency estimate stays fresh instead of drifting unboundedly.
            if pendingEncodeStarts.count > 12 { pendingEncodeStarts.removeFirst() }
        }
    }

    private func recordEncodedFrame(_ frame: HEVCEncoder.EncodedFrame, formatSummary: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        statsLock.withLock {
            totalFrames += 1
            encoderFormatSummary = formatSummary
            frameSamples.append((t: now, bytes: frame.byteCount))
            trimRateWindowLocked()
            if !pendingEncodeStarts.isEmpty {
                let start = pendingEncodeStarts.removeFirst()
                if now >= start {
                    latencySamplesMs.append(Double(now - start) / 1_000_000)
                    if latencySamplesMs.count > 60 { latencySamplesMs.removeFirst() }
                }
            }
        }
    }

    /// Drop rate samples older than the window. Caller holds `statsLock`.
    private func trimRateWindowLocked() {
        guard let newest = frameSamples.last?.t else { return }
        let cutoff = newest >= Self.rateWindowNanos ? newest - Self.rateWindowNanos : 0
        while let oldest = frameSamples.first, oldest.t < cutoff {
            frameSamples.removeFirst()
        }
    }

    /// (fps, Mbps) over the retained window. Caller holds `statsLock`.
    private func rateLocked() -> (Double, Double) {
        guard let first = frameSamples.first, let last = frameSamples.last,
            frameSamples.count >= 2, last.t > first.t
        else { return (0, 0) }
        let span = Double(last.t - first.t) / 1_000_000_000
        let fps = Double(frameSamples.count - 1) / span
        // Bytes of every frame *after* the window's opening sample arrived in `span`.
        let bytes = frameSamples.dropFirst().reduce(0) { $0 + $1.bytes }
        let mbps = Double(bytes) * 8 / span / 1_000_000
        return (fps, mbps)
    }
}

/// Cross-thread handoff for the watcher run-loop thread's `CFRunLoop`, written on
/// that thread before the continuation resumes, so the caller reads it safely.
private final class WatcherThreadBox: @unchecked Sendable {
    var runLoop: CFRunLoop?
}
