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
}
