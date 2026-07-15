import Foundation
import Network

/// The transport boundary (issue #3 Phase 3).
///
/// v1 is TCP on a wired LAN (two connections: control + video), but the whole
/// point of putting a protocol here is that swapping in the M3 custom-UDP video
/// transport touches nothing above this line — not capture, not tiling, not AX.
/// A `PacketTransport` moves whole **messages**, not a byte stream: the TCP
/// implementation hides its length-prefix framing, and a future UDP one would map
/// one datagram to one message, so callers never see the difference.
public protocol PacketTransport: Sendable {
    /// Send one whole message. The implementation frames it as needed.
    func send(_ payload: Data) async throws
    /// The next whole message, or nil once the peer has closed. Must not be
    /// called concurrently with itself (drive it from a single receive loop).
    func receiveFrame() async throws -> Data?
    /// Tear the connection down.
    func close() async
}

public enum TransportError: Error, CustomStringConvertible, Equatable {
    case refusedPublicBind(String)
    case badPort(UInt16)
    case listenerFailed(String)

    public var description: String {
        switch self {
        case .refusedPublicBind(let host):
            return
                "refusing to bind to \"\(host)\": Transom has no auth or encryption and must "
                + "only listen on a private address (10/8, 172.16/12, 192.168/16, 127/8, "
                + "169.254/16). See the security note in the README."
        case .badPort(let p):
            return "invalid port \(p)"
        case .listenerFailed(let m):
            return "listener failed: \(m)"
        }
    }
}

/// Whether an IPv4 literal is in a private / non-routable range. Pure and tested.
///
/// This is the enforcement point for the security note: the host refuses to bind
/// anywhere the wider internet could reach, because anyone who reaches the port
/// gets a video feed and keystroke injection (no auth, no crypto — acceptable on
/// a wired home LAN and nowhere else).
public enum PrivateAddress {
    public static func isPrivateIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part) else { return false }
            octets.append(value)
        }
        let a = octets[0]
        let b = octets[1]
        switch a {
        case 10: return true  // 10.0.0.0/8
        case 127: return true  // loopback 127.0.0.0/8
        case 192: return b == 168  // 192.168.0.0/16
        case 172: return (16...31).contains(b)  // 172.16.0.0/12
        case 169: return b == 254  // link-local 169.254.0.0/16
        default: return false
        }
    }
}

/// A TCP `PacketTransport` over one `NWConnection`, with length-prefix framing.
/// An actor so the receive buffer and the single-outstanding-receive rule are
/// enforced by isolation rather than a lock.
public actor TCPTransport: PacketTransport {
    private let connection: NWConnection
    private var frames = FrameBuffer()

    public init(connection: NWConnection) {
        self.connection = connection
    }

    public func send(_ payload: Data) async throws {
        let framed = WireCodec.frame(payload)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: framed,
                completion: .contentProcessed { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                })
        }
    }

    public func receiveFrame() async throws -> Data? {
        while true {
            if let frame = try frames.next() { return frame }
            guard let chunk = try await receiveChunk() else { return nil }
            frames.append(chunk)
        }
    }

    private func receiveChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
                data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(returning: nil)  // peer closed
                } else {
                    cont.resume(returning: Data())  // spurious empty; loop
                }
            }
        }
    }

    public func close() {
        connection.cancel()
    }

    /// Open an outbound TCP connection and return it once it is ready. Used by the
    /// host-side mock client that drives the resize roundtrip in verification
    /// (`mockresize`); the real client is a separate Rust codebase. `TCP_NODELAY`
    /// matches the server so the measured round-trip isn't Nagle-inflated.
    public static func connect(host: String, port: UInt16) async throws -> TCPTransport {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TransportError.badPort(port)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: nwPort, using: params)

        let gate = ConnectGate()
        try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.finish() { cont.resume() }
                case .failed(let error):
                    if gate.finish() { cont.resume(throwing: error) }
                case .cancelled:
                    if gate.finish() { cont.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
        return TCPTransport(connection: connection)
    }
}

/// One-shot latch so an `NWConnection` state handler resumes its continuation
/// exactly once even though it fires for several states.
private final class ConnectGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func finish() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}

/// Accepts TCP connections on a private address and hands each one back as a
/// ready-to-use `TCPTransport`. One listener per channel (control, video).
public final class TCPListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    public let connections: AsyncStream<TCPTransport>
    private let continuation: AsyncStream<TCPTransport>.Continuation

    /// - Throws: `TransportError.refusedPublicBind` if `host` is not private.
    public init(host: String, port: UInt16, label: String) throws {
        guard PrivateAddress.isPrivateIPv4(host) else {
            throw TransportError.refusedPublicBind(host)
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TransportError.badPort(port)
        }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true  // Nagle off (issue #3 decision); it adds tens of ms silently.
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        // Bind to this exact private interface, not 0.0.0.0.
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)

        self.listener = try NWListener(using: params)
        self.queue = DispatchQueue(label: "one.transom.host.net.\(label)")
        (self.connections, self.continuation) = AsyncStream.makeStream()

        let continuation = self.continuation
        let queue = self.queue
        // `TRANSOM_NET_DEBUG=1` traces inbound connection state to stderr. Added
        // while diagnosing the port-7000/AirPlay collision (architecture.md §8):
        // when another process owns the port, `newConnection` simply never fires,
        // and that silence is otherwise invisible. Off by default, zero cost.
        let debug = ProcessInfo.processInfo.environment["TRANSOM_NET_DEBUG"] != nil
        listener.newConnectionHandler = { connection in
            if debug { FileHandle.standardError.write(Data("net: newConnection\n".utf8)) }
            // Hand the transport out only once the connection is actually ready,
            // so the first send/receive doesn't queue against a half-open socket.
            connection.stateUpdateHandler = { state in
                if debug {
                    FileHandle.standardError.write(Data("net: conn state \(state)\n".utf8))
                }
                switch state {
                case .ready:
                    continuation.yield(TCPTransport(connection: connection))
                case .failed, .cancelled:
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func start() {
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
        continuation.finish()
    }
}
