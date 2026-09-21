import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Independent window captures share only the TCP transport. Geometry, HEVC
/// reference frames and recovery are isolated, so overlapping windows are safe.
public actor WindowVideoHub {
    private struct Stream {
        let size: WireSize
        let generation: UInt64
        let capture: DisplayCapture
        let encoder: HEVCEncoder
        let server: VideoServer
        let sink: AsyncStream<HEVCEncoder.EncodedFrame>.Continuation
        let task: Task<Void, Never>
    }
    private let config: HostConfig
    private var streams: [UInt64: Stream] = [:]
    private var nextGeneration: UInt64 = 0
    private var active: (id: UUID, transport: any PacketTransport)?
    private var stopped = false
    private var activity: NSObjectProtocol?
    public let previews = WindowPreviewCache()
    private let connectionChanged: @Sendable (Bool) -> Void
    private let encoded: @Sendable (HEVCEncoder.EncodedFrame, String, Bool) -> Void

    public init(config: HostConfig, connectionChanged: @escaping @Sendable (Bool) -> Void,
                encoded: @escaping @Sendable (HEVCEncoder.EncodedFrame, String, Bool) -> Void) {
        self.config = config; self.connectionChanged = connectionChanged; self.encoded = encoded
    }

    public func serve(listener: SocketVideoListener) async {
        for await transport in listener.connections {
            guard !stopped else { await transport.close(); continue }
            let connectionID = UUID()
            active = (connectionID, transport)
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Streaming Mac windows to Transom")
            connectionChanged(true)
            for (id, stream) in streams {
                await stream.server.attachShared(wrap(transport, id: id, stream: stream))
            }
            do { while !stopped, try await transport.receiveFrame() != nil {} } catch {}
            if active?.id == connectionID {
                active = nil
                for stream in streams.values { await stream.server.attachShared(nil) }
                connectionChanged(false)
                if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
            }
            await transport.close()
        }
    }

    private func wrap(_ transport: any PacketTransport, id: UInt64, stream: Stream) -> WindowPacketTransport {
        WindowPacketTransport(base: transport, id: id, generation: stream.generation, size: stream.size)
    }

    public func open(id: UInt64, window: SCWindow, size: WireSize) async throws {
        guard !stopped else { return }
        // NV12 uses chroma pairs. An odd last row/column is padded, never scaled.
        let size = WireSize(w: (size.w + 1) & ~1, h: (size.h + 1) & ~1)
        guard streams[id]?.size != size else { return }
        let enc = try HEVCEncoder(config: HEVCEncoder.Config(
            width: Int(size.w), height: Int(size.h), fps: config.fps,
            bitrateBitsPerSecond: config.bitrateMbps * 1_000_000,
            maxKeyFrameInterval: config.fps * 2, format: config.videoFormat))
        enc.extractFrameData = true
        let cap = DisplayCapture(display: config.display, fps: config.fps,
            pixelFormat: config.videoFormat.capturePixelFormat, window: window, size: size)
        let server = VideoServer(hvccProvider: { enc.parameterSetsHVCC }, requestKeyframe: { [weak enc, weak cap] in
            enc?.requestKeyframe(); cap?.requestRefresh()
        })
        let (frames, sink) = AsyncStream.makeStream(of: HEVCEncoder.EncodedFrame.self, bufferingPolicy: .bufferingNewest(4))
        let encoded = self.encoded
        enc.onEncodedFrame = { [weak enc] frame in
            encoded(frame, enc?.outputFormatSummary ?? "unknown", enc?.usingHardware ?? false)
            if case .dropped = sink.yield(frame) { enc?.requestKeyframe() }
        }
        let duration = CMTime(value: 1, timescale: Int32(config.fps))
        cap.onPixelBuffer = { buffer, pts in
            // A resized window can deliver the old surface while SCK settles.
            guard CVPixelBufferGetWidth(buffer) == Int(size.w), CVPixelBufferGetHeight(buffer) == Int(size.h) else { return }
            try? enc.encode(buffer, pts: pts, duration: duration)
        }
        do { try await cap.start() } catch { enc.finish(); sink.finish(); throw error }
        guard !stopped else { await cap.stop(); enc.finish(); sink.finish(); return }
        await remove(id: id)
        guard !stopped else { await cap.stop(); enc.finish(); sink.finish(); return }
        nextGeneration += 1
        let stream = Stream(size: size, generation: nextGeneration, capture: cap, encoder: enc,
                            server: server, sink: sink, task: Task { for await frame in frames { await server.send(frame) } })
        streams[id] = stream
        previews.set(id: id, capture: cap)
        if let active { await server.attachShared(wrap(active.transport, id: id, stream: stream)) }
        Log.encode.notice("window video: \(id) generation \(stream.generation) \(size.w)x\(size.h) hardware=\(enc.usingHardware)")
    }

    public func remove(id: UInt64) async {
        guard let stream = streams.removeValue(forKey: id) else { return }
        previews.set(id: id, capture: nil)
        await stream.server.attachShared(nil)
        await stream.capture.stop()
        stream.encoder.finish(); stream.sink.finish(); stream.task.cancel()
    }
    public func refresh() {
        for stream in streams.values { stream.encoder.requestKeyframe(); stream.capture.requestRefresh() }
    }
    public func tick() {
        guard active != nil else { return }
        for stream in streams.values { stream.capture.requestIdleRefresh() }
    }
    public func stop() async {
        stopped = true
        let transport = active?.transport; active = nil
        await transport?.close()
        for id in Array(streams.keys) { await remove(id: id) }
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        connectionChanged(false)
    }
}

struct WindowPacketTransport: PacketTransport {
    let base: any PacketTransport
    let id: UInt64
    let generation: UInt64
    let size: WireSize
    func send(_ payload: Data) async throws {
        try await base.send(VideoWire.encodeWindow(id: id, generation: generation, size: size, payload: payload))
    }
    func receiveFrame() async throws -> Data? { nil }
    // VideoServer invokes close only on a failed socket write in shared mode.
    // Normal window removal detaches its server without closing this transport.
    func close() async { await base.close() }
}

public final class WindowPreviewCache: @unchecked Sendable {
    private let lock = NSLock()
    private var captures: [UInt64: DisplayCapture] = [:]
    func set(id: UInt64, capture: DisplayCapture?) { lock.withLock { captures[id] = capture } }
    public func images() -> [UInt64: CGImage] {
        lock.withLock { captures }.compactMapValues { $0.latestImage(maxPixelWidth: 480) }
    }
}
