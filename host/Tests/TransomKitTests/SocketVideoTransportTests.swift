import Darwin
import Foundation
import Testing

@testable import TransomKit

@Suite("Video socket transport", .timeLimit(.minutes(1)))
struct SocketVideoTransportTests {
    private func pair() async throws -> (SocketVideoTransport, SocketVideoTransport) {
        // Real TCP sockets exercise NODELAY, shutdown and the framing boundary.
        let listener = try SocketVideoListener(host: "127.0.0.1", port: 0)
        listener.start()
        defer { listener.stop() }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let client = try SocketVideoTransport(owning: fd)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = listener.port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
        var incoming = listener.connections.makeAsyncIterator()
        let server = try #require(await incoming.next())
        return (client, server)
    }

    @Test("large frames cross real TCP with exact framing and content")
    func framedRoundTrip() async throws {
        let (client, server) = try await pair()
        let payloads = [Data(), Data([1, 2, 3]), Data((0..<2_000_000).map { UInt8(truncatingIfNeeded: $0) })]
        let sending = Task {
            for payload in payloads { try await server.send(payload) }
            await server.close()
        }
        for payload in payloads {
            #expect(try await client.receiveFrame() == payload)
        }
        #expect(try await client.receiveFrame() == nil)
        try await sending.value
        await client.close()
    }

    @Test("shutdown unblocks a pending read and is idempotent")
    func shutdownRead() async throws {
        let (client, server) = try await pair()
        let reading = Task { try? await server.receiveFrame() }
        try await Task.sleep(for: .milliseconds(10))
        await server.close()
        await server.close()
        #expect(await reading.value == nil)
        #expect(try await client.receiveFrame() == nil)
        await client.close()
    }

    @Test("shutdown cancels a send to a client that stopped consuming")
    func shutdownWrite() async throws {
        let (client, server) = try await pair()
        let sending = Task { () -> Bool in
            do {
                try await server.send(Data(repeating: 42, count: 16 * 1024 * 1024))
                return false
            } catch { return true }
        }
        try await Task.sleep(for: .milliseconds(50))
        await server.close()
        #expect(await sending.value)
        await client.close()
    }
}
