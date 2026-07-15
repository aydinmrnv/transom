import ApplicationServices
import CoreGraphics
import CoreMedia
import Foundation

/// Everything needed to start serving one app on one display: the same knobs the
/// `serve` CLI takes, in one `Sendable` value the host app can also build.
public struct HostConfig: Sendable {
    public var target: TargetApp
    public var display: DisplayInfo
    public var host: String
    public var controlPort: UInt16
    public var videoPort: UInt16
    public var gutter: Int
    public var tile: Bool
    public var video: Bool
    public var bitrateMbps: Int
    public var fps: Int

    public init(
        target: TargetApp,
        display: DisplayInfo,
        host: String = "127.0.0.1",
        controlPort: UInt16 = 7000,
        videoPort: UInt16 = 7001,
        gutter: Int = Tiler.defaultGutter,
        tile: Bool = true,
        video: Bool = true,
        bitrateMbps: Int = 40,
        fps: Int = 60
    ) {
        self.target = target
        self.display = display
        self.host = host
        self.controlPort = controlPort
        self.videoPort = videoPort
        self.gutter = gutter
        self.tile = tile
        self.video = video
        self.bitrateMbps = bitrateMbps
        self.fps = fps
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
    /// The codec + chroma the encoder reports it is producing (e.g. "hvc1 … 4:4:4
    /// 10-bit"), captured on the first encoded frame.
    public var encoderFormatSummary = "—"

    /// The startup tile layout with post-clamp actual rects and deltas (I-4/OQ-2).
    public var tilePlacements: [TilePlacement] = []
    /// Set if the tiler could not lay the window set out (surfaced, not swallowed).
    public var tileError: String?
    /// Live count of windows the AX watcher currently tracks.
    public var liveWindowCount = 0

    public init() {}

    /// The load-bearing check for OQ-4: are we actually on the 4:4:4 10-bit
    /// hardware path, or has something fallen back? `true` only when the encoder
    /// reads back as hardware *and* reports 4:4:4 chroma. The app shows this
    /// prominently, because a silent fall to 4:2:0 fails the product on text.
    public var encoderIs444Hardware: Bool {
        usingHardware && encoderFormatSummary.contains("4:4:4")
    }
}

/// The serving pipeline for one app on one display, extracted from the `serve`
/// command so the CLI and the SwiftUI host app drive the **same** code (the app
/// is a thin shell over `serve`, not a fork of it).
///
/// It tiles the app's windows once at startup (I-5), watches them via AX and
/// streams lifecycle + geometry on the control channel, and — with `video` —
/// captures the display and HEVC-encodes it 4:4:4 10-bit in hardware on a second
/// channel. Capture and AX never stop while a client comes and goes; a reconnect
/// resyncs from the registry (see `ControlServer`).
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
    private var watcher: WindowWatcher?
    private var watcherRunLoop: CFRunLoop?
    private var controlListener: TCPListener?
    private var videoListener: TCPListener?
    private var capture: DisplayCapture?
    private var encoder: HEVCEncoder?
    private var eventSink: AsyncStream<WindowWatcher.WindowEvent>.Continuation?
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

    // MARK: - Lifecycle

    /// Tile, start the AX watcher + control server, and (if `video`) the capture +
    /// encoder + video server. Returns once everything is listening and the initial
    /// registry is seeded, so a client connecting immediately gets a full resync.
    /// Throws with a plain message if a permission or bind precondition fails.
    public func start() async throws {
        try preflight()

        let disp = config.display
        let registry = WindowRegistry()
        self.registry = registry
        let vdsSize = WireSize(w: UInt32(disp.pixelWidth), h: UInt32(disp.pixelHeight))

        // Tile once at startup so streamed windows are non-overlapping (I-5), and
        // keep the requested-vs-actual placements for the Status view (I-4/OQ-2).
        if config.tile {
            switch TileService.layout(pid: config.target.pid, display: disp, gutter: config.gutter)
            {
            case .success(let placements):
                statsLock.withLock { tilePlacements = placements }
            case .failure(let error):
                statsLock.withLock { tileError = error.description }
                Log.general.notice(
                    "serve: tiling failed: \(error.description, privacy: .public)")
            }
        }

        // Control channel: AX events -> ordered broadcast via one AsyncStream.
        let (events, eventSink) = AsyncStream.makeStream(of: WindowWatcher.WindowEvent.self)
        self.eventSink = eventSink
        let watcher = WindowWatcher(pid: config.target.pid, display: disp, registry: registry)
        watcher.onEvent = { event in eventSink.yield(event) }
        self.watcher = watcher

        let controlServer = ControlServer(vdsSize: vdsSize, registry: registry)
        await controlServer.setOnClientMessage { message in
            // Phase 4 wires requestResize -> AX. For now, surface it.
            Log.general.notice(
                "control: client -> \(String(describing: message), privacy: .public)")
        }
        await controlServer.setOnConnectionChange { [weak self] connected in
            self?.statsLock.withLock { self?.controlConnected = connected }
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
                    try watcher.start()
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
                CFRunLoopRun()
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
        controlListener.start()

        if config.video {
            try await startVideo(disp: disp, vdsSize: vdsSize)
            statsLock.withLock { videoEnabled = true }
        }

        statsLock.withLock { isRunning = true }
    }

    private func startVideo(disp: DisplayInfo, vdsSize: WireSize) async throws {
        let enc = try HEVCEncoder(
            config: HEVCEncoder.Config(
                width: disp.pixelWidth, height: disp.pixelHeight, fps: config.fps,
                bitrateBitsPerSecond: config.bitrateMbps * 1_000_000,
                maxKeyFrameInterval: config.fps * 2))
        enc.extractFrameData = true
        self.encoder = enc
        statsLock.withLock { usingHardware = enc.usingHardware }

        let videoServer = VideoServer(hvccProvider: { enc.parameterSetsHVCC })
        await videoServer.setOnConnectionChange { [weak self] connected in
            self?.statsLock.withLock { self?.videoConnected = connected }
        }
        let listener = try TCPListener(host: config.host, port: config.videoPort, label: "video")
        self.videoListener = listener

        let (frames, frameSink) = AsyncStream.makeStream(
            of: HEVCEncoder.EncodedFrame.self, bufferingPolicy: .bufferingNewest(4))
        enc.onEncodedFrame = { [weak self] frame in
            // Pass the encoder's format read-back in from here (we hold `enc`
            // strongly) rather than reading `self.encoder` off this VT thread.
            self?.recordEncodedFrame(frame, formatSummary: enc.outputFormatSummary)
            frameSink.yield(frame)
        }

        let cap = DisplayCapture(display: disp, fps: config.fps)
        self.capture = cap
        let frameDuration = CMTimeMake(value: 1, timescale: Int32(config.fps))
        cap.onPixelBuffer = { [weak self] pixelBuffer, pts in
            self?.markEncodeStart()
            try? enc.encode(pixelBuffer, pts: pts, duration: frameDuration)
        }
        try await cap.start()

        tasks.append(Task { await videoServer.serve(listener: listener) })
        tasks.append(Task { for await f in frames { await videoServer.send(f) } })
        listener.start()
    }

    /// Stop everything and reset to a clean state. Safe to call more than once.
    public func stop() async {
        controlListener?.stop()
        videoListener?.stop()
        if let capture { await capture.stop() }
        encoder?.finish()
        eventSink?.finish()
        for task in tasks { task.cancel() }
        // Stopping its run loop ends the watcher thread; the AXObserver and its
        // source are released when the watcher deallocates below.
        if let runLoop = watcherRunLoop { CFRunLoopStop(runLoop) }

        tasks = []
        registry = nil
        watcher = nil
        watcherRunLoop = nil
        controlListener = nil
        videoListener = nil
        capture = nil
        encoder = nil
        eventSink = nil

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
