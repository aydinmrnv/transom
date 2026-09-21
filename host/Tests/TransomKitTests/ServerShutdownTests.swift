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
