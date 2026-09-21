import CoreMedia
import Foundation
import Testing

@testable import TransomKit

private actor RecordingVideoTransport: PacketTransport {
    var messages: [Data] = []
    var receiving = false
    private var closed = false

    func send(_ payload: Data) { messages.append(payload) }

    func receiveFrame() async throws -> Data? {
        receiving = true
        while !closed {
            try await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    func close() { closed = true }
}

@Suite("Video startup")
struct VideoServerTests {
    private func waitForConnection(_ transport: RecordingVideoTransport) async throws {
        for _ in 0..<200 {
            if await transport.receiving { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Video connection did not start")
    }

    private func frame(keyframe: Bool) -> HEVCEncoder.EncodedFrame {
        HEVCEncoder.EncodedFrame(
            byteCount: 2, pts: .zero, isKeyframe: keyframe, data: Data([0x26, 1]))
    }

    @Test("each connection starts with config and a keyframe, never a delta")
    func keyframeOnEveryConnection() async throws {
        let config = Data([1, 2, 3])
        let server = VideoServer(hvccProvider: { config })
        for _ in 0..<2 {
            let transport = RecordingVideoTransport()
            let connection = Task { await server.serveConnection(transport) }
            defer { connection.cancel() }
            try await waitForConnection(transport)
            await server.send(frame(keyframe: false))
            #expect(await transport.messages.isEmpty)
            await server.send(frame(keyframe: true))
            let messages = await transport.messages
            try #require(messages.count == 2)
            #expect(VideoWire.decode(messages[0]) == .config(hvcc: config))
            if case .frame(_, _, let keyframe, _)? = VideoWire.decode(messages[1]) {
                #expect(keyframe)
            } else {
                Issue.record("Expected a keyframe after config")
            }
            await server.send(frame(keyframe: false))
            #expect(await transport.messages.count == 3)
            await transport.close()
            await connection.value
        }
    }

    @Test("two window streams retain independent configs and dependency chains")
    func independentStreams() async throws {
        let transport = RecordingVideoTransport()
        let a = VideoServer(hvccProvider: { Data([11]) })
        let b = VideoServer(hvccProvider: { Data([22]) })
        let size = WireSize(w: 2600, h: 1800)
        await a.attachShared(WindowPacketTransport(base: transport, id: 1, generation: 1, size: size))
        await b.attachShared(WindowPacketTransport(base: transport, id: 2, generation: 2, size: size))
        await a.send(frame(keyframe: true))
        await b.send(frame(keyframe: true))
        await a.attachShared(nil)
        await a.send(frame(keyframe: false))
        await b.send(frame(keyframe: false))
        let packets = await transport.messages.compactMap(VideoWire.decode)
        #expect(packets.count == 5)
        #expect(packets[0] == .window(id: 1, generation: 1, size: size, message: .config(hvcc: Data([11]))))
        #expect(packets[2] == .window(id: 2, generation: 2, size: size, message: .config(hvcc: Data([22]))))
        if case .window(2, 2, _, .frame(_, _, false, _)) = packets[4] {} else {
            Issue.record("Removing one window interrupted the other stream")
        }
        // A reconnect resets both configs independently.
        await b.attachShared(WindowPacketTransport(base: transport, id: 2, generation: 2, size: size))
        await b.send(frame(keyframe: false))
        #expect(await transport.messages.count == 5)
        await b.send(frame(keyframe: true))
        #expect(await transport.messages.count == 7)
    }

    @Test("frames cannot precede missing configuration")
    func waitsForConfig() async throws {
        let server = VideoServer(hvccProvider: { nil })
        let transport = RecordingVideoTransport()
        let connection = Task { await server.serveConnection(transport) }
        defer { connection.cancel() }
        try await waitForConnection(transport)
        await server.send(frame(keyframe: true))
        #expect(await transport.messages.isEmpty)
        await transport.close()
        await connection.value
    }

    @Test("a dropped encoded reference suppresses deltas until a recovery keyframe")
    func recoversAfterQueueGap() async throws {
        let server = VideoServer(hvccProvider: { Data([1, 2, 3]) })
        let transport = RecordingVideoTransport()
        let connection = Task { await server.serveConnection(transport) }
        defer { connection.cancel() }
        try await waitForConnection(transport)
        func sequenced(_ n: UInt64, keyframe: Bool) -> HEVCEncoder.EncodedFrame {
            var value = frame(keyframe: keyframe)
            value.sequence = n
            return value
        }
        await server.send(sequenced(0, keyframe: true))
        await server.send(sequenced(1, keyframe: false))
        // Frame 2 was evicted by the bounded encoder→network queue.
        await server.send(sequenced(3, keyframe: false))
        await server.send(sequenced(4, keyframe: false))
        #expect(await transport.messages.count == 3)
        await server.send(sequenced(5, keyframe: true))
        await server.send(sequenced(6, keyframe: false))
        let messages = await transport.messages
        #expect(messages.count == 5)
        if case .frame(let seq, _, let keyframe, _)? = VideoWire.decode(messages[3]) {
            #expect(seq == 5 && keyframe)
        } else { Issue.record("Expected recovery keyframe") }
        await transport.close()
        await connection.value
    }
}
