import Foundation
import Testing

@testable import TransomKit

private actor ShutdownTransport: PacketTransport {
    var receiving = false
    var closed = false
    var messages: [Data] = []

    func send(_ payload: Data) { messages.append(payload) }

    func receiveFrame() async throws -> Data? {
        receiving = true
        while !closed {
            try await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    func close() { closed = true }

    func waitForReceive() async throws {
        for _ in 0..<200 {
            if receiving { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(receiving, "Server did not start receiving")
    }

    func waitForClose() async throws {
        for _ in 0..<200 {
            if closed { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(closed, "Stopped server did not close a queued connection")
    }
}

private final class ConnectionChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [Bool] = []

    func record(_ connected: Bool) { lock.withLock { changes.append(connected) } }
    var values: [Bool] { lock.withLock { changes } }
}

@Suite("Sharing shutdown")
struct ServerShutdownTests {
    @Test("control stop closes the client and rejects queued connections")
    func controlStop() async throws {
        let server = ControlServer(vdsSize: WireSize(w: 1920, h: 1080), registry: WindowRegistry())
        let changes = ConnectionChanges()
        await server.setOnConnectionChange { changes.record($0) }
        let transport = ShutdownTransport()
        let connection = Task { await server.serveConnection(transport) }
        defer { connection.cancel() }
        try await transport.waitForReceive()
        // The initial hello and empty tile layout were sent successfully.
        #expect(await transport.messages.count == 2)
        await server.stop()
        try #require(await transport.closed)
        await connection.value
        await server.stop()

        let queued = ShutdownTransport()
        let next = Task { await server.serveConnection(queued) }
        defer { next.cancel() }
        try await queued.waitForClose()
        await next.value
        #expect(await queued.messages.isEmpty)
        #expect(changes.values == [true, false])
    }

    @Test("overlapping windows each receive the whole display resize allowance")
    func independentBounds() async throws {
        let registry = WindowRegistry()
        registry.record(id: 1, rect: WireRect(x: 0, y: 50, w: 2600, h: 1800), title: "Editor")
        registry.record(id: 2, rect: WireRect(x: 0, y: 50, w: 2600, h: 1800), title: "Browser")
        let size = WireSize(w: 3840, h: 2160)
        let server = ControlServer(vdsSize: size, registry: registry, independentWindows: true)
        let transport = ShutdownTransport()
        let connection = Task { await server.serveConnection(transport) }
        try await transport.waitForReceive()
        let messages = try await transport.messages.map { try JSONDecoder().decode(ControlMessage.self, from: $0) }
        #expect(messages.contains(.resizeBounds(id: 1, maxSize: size)))
        #expect(messages.contains(.resizeBounds(id: 2, maxSize: size)))
        await server.stop()
        await connection.value
    }

    @Test("video stop closes the client and rejects queued connections")
    func videoStop() async throws {
        let server = VideoServer(hvccProvider: { nil })
        let changes = ConnectionChanges()
        await server.setOnConnectionChange { changes.record($0) }
        let transport = ShutdownTransport()
        let connection = Task { await server.serveConnection(transport) }
        defer { connection.cancel() }
        try await transport.waitForReceive()
        await server.stop()
        try #require(await transport.closed)
        await connection.value
        await server.stop()

        let queued = ShutdownTransport()
        let next = Task { await server.serveConnection(queued) }
        defer { next.cancel() }
        try await queued.waitForClose()
        await next.value
        #expect(changes.values == [true, false])
    }
}
