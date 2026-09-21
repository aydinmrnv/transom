import Foundation

/// The video channel server (issue #3 Phase 3, second connection): streams
/// encoded HEVC frames to at most one connected client.
///
/// This is the "frames may be dropped, never delayed" channel (protocol.md §1).
/// The caller feeds frames through a small most-recent buffer, so if the client
/// or link stalls, old frames are dropped rather than queued. On connect (and
/// again on reconnect) the parameter sets are sent before the first frame,
/// because an `hvc1` stream is undecodable without them.
public actor VideoServer {
    private var active: (id: UUID, transport: any PacketTransport)?
    private var streamingActivity: NSObjectProtocol?
    private var stopped = false
    var hasClient: Bool { active != nil }
    private var sentConfig = false
    private var waitingForKeyframe = true
    private var seq: UInt64 = 0
    private var lastEncodedSequence: UInt64?
    private var reportStart = DispatchTime.now().uptimeNanoseconds
    private var reportFrames = 0
    private var reportSendNanos: UInt64 = 0
    private var reportMaxSendNanos: UInt64 = 0
    private let hvccProvider: @Sendable () -> Data?
    private let requestKeyframe: @Sendable () -> Void

    /// Called with `true` when a client connects and `false` when it disconnects
    /// or is dropped, so a status UI can show whether the video client is attached.
    /// Fired from the actor; the closure must be thread-safe.
    public var onConnectionChange: (@Sendable (Bool) -> Void)?

    /// - Parameter hvccProvider: returns the encoder's `hvcC` parameter sets once
    ///   the first frame has been encoded (nil before then).
    public init(hvccProvider: @escaping @Sendable () -> Data?, requestKeyframe: @escaping @Sendable () -> Void = {}) {
        self.hvccProvider = hvccProvider
        self.requestKeyframe = requestKeyframe
    }

    public func setOnConnectionChange(_ handler: @escaping @Sendable (Bool) -> Void) {
        self.onConnectionChange = handler
    }

    public func serve(listener: SocketVideoListener) async {
        for await transport in listener.connections {
            await serveConnection(transport)
        }
    }

    func serveConnection(_ transport: any PacketTransport) async {
        guard !stopped, !Task.isCancelled else {
            await transport.close()
            return
        }
        let connectionID = UUID()
        active = (connectionID, transport)
        endStreamingActivity()
        streamingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Streaming Mac windows to Transom")
        sentConfig = false
        waitingForKeyframe = true
        lastEncodedSequence = nil
        reportStart = DispatchTime.now().uptimeNanoseconds
        reportFrames = 0
        reportSendNanos = 0
        reportMaxSendNanos = 0
        Log.encode.notice("video: client connected")
        onConnectionChange?(true)
        // The client sends nothing on this channel; the receive loop just detects
        // disconnect so the host can stop targeting a dead socket.
        do {
            while !stopped, try await transport.receiveFrame() != nil {}
        } catch {
            // fall through to cleanup
        }
        Log.encode.notice("video: client disconnected")
        if active?.id == connectionID {
            active = nil
            endStreamingActivity()
            onConnectionChange?(false)
        }
        await transport.close()
    }

    /// Stop the accepted connection as well as any buffered listener arrivals.
    public func stop() async {
        stopped = true
        guard let active else { return }
        self.active = nil
        endStreamingActivity()
        onConnectionChange?(false)
        await active.transport.close()
    }

    /// Send one encoded frame to the connected client, if any. Config is sent
    /// lazily before the first frame of a connection.
    public func send(_ frame: HEVCEncoder.EncodedFrame) async {
        guard let active else { return }
        if let sequence = frame.sequence {
            if let previous = lastEncodedSequence, sequence != previous &+ 1,
                !frame.isKeyframe, !waitingForKeyframe {
                waitingForKeyframe = true
                requestKeyframe()
                Log.encode.notice("video: encoded queue overrun; waiting for a fresh keyframe")
            }
            lastEncodedSequence = sequence
        }
        guard !waitingForKeyframe || frame.isKeyframe else { return }
        let sendStart = DispatchTime.now().uptimeNanoseconds
        do {
            if !sentConfig {
                guard let hvcc = hvccProvider() else { return }
                try await active.transport.send(VideoWire.encodeConfig(hvcc: hvcc))
                guard self.active?.id == active.id else { return }
                sentConfig = true
            }
            waitingForKeyframe = false
            let ptsMicros =
                frame.pts.seconds.isFinite ? UInt64(max(0, frame.pts.seconds * 1_000_000)) : 0
            try await active.transport.send(
                VideoWire.encodeFrame(
                    seq: frame.sequence ?? seq, ptsMicros: ptsMicros, keyframe: frame.isKeyframe, data: frame.data))
            seq += 1
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = now - sendStart
            reportFrames += 1
            reportSendNanos += elapsed
            reportMaxSendNanos = max(reportMaxSendNanos, elapsed)
            if now - reportStart >= 5_000_000_000 {
                let fps = Double(reportFrames) * 1_000_000_000 / Double(now - reportStart)
                let mean = Double(reportSendNanos) / Double(reportFrames) / 1_000_000
                let maximum = Double(reportMaxSendNanos) / 1_000_000
                Log.encode.notice("video performance: \(fps) sent fps, send mean \(mean) ms, max \(maximum) ms")
                reportStart = now
                reportFrames = 0
                reportSendNanos = 0
                reportMaxSendNanos = 0
            }
        } catch {
            if self.active?.id == active.id {
                self.active = nil
                endStreamingActivity()
                onConnectionChange?(false)
            }
            await active.transport.close()
        }
    }

    private func endStreamingActivity() {
        if let streamingActivity {
            ProcessInfo.processInfo.endActivity(streamingActivity)
            self.streamingActivity = nil
        }
    }
}
