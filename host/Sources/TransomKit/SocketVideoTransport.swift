import Darwin
import Foundation

/// Kernel TCP for video. On the target Mac, Network.framework's video path
/// repeatedly retransmitted LAN packets and filled its send buffer. The same
/// HEVC stream over a BSD socket sustained the capture rate without those gaps.
/// Control/discovery still use Network.framework; framing is identical.
public final class SocketVideoListener: @unchecked Sendable {
    public let connections: AsyncStream<SocketVideoTransport>
    public let port: UInt16
    private let source: DispatchSourceRead
    private let continuation: AsyncStream<SocketVideoTransport>.Continuation
    private let state = NSLock()
    private var started = false
    private var stopped = false

    public init(host: String, port: UInt16) throws {
        guard PrivateAddress.isPrivateIPv4(host) else {
            throw TransportError.refusedPublicBind(host)
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError() }
        do {
            var reuse: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse))) == 0
            else { throw socketError() }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
                throw TransportError.refusedPublicBind(host)
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(fd, 1) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0
            else { throw socketError() }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            guard named == 0 else { throw socketError() }
            self.port = UInt16(bigEndian: address.sin_port)
        } catch {
            Darwin.close(fd)
            throw error
        }
        (connections, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(1))
        source = DispatchSource.makeReadSource(
            fileDescriptor: fd, queue: DispatchQueue(label: "one.transom.host.video.accept", qos: .userInitiated))
        let continuation = self.continuation
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else {
                    if errno == EINTR { continue }
                    return
                }
                do {
                    let transport = try SocketVideoTransport(owning: client)
                    switch continuation.yield(transport) {
                    case .enqueued: break
                    case .dropped, .terminated: transport.closeNow()
                    @unknown default: transport.closeNow()
                    }
                } catch {
                    // The transport initializer closes a rejected descriptor.
                    Log.encode.error("video socket setup: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
    }

    public func start() {
        state.withLock {
            guard !started, !stopped else { return }
            started = true
            source.resume()
        }
    }

    public func stop() {
        state.withLock {
            guard !stopped else { return }
            stopped = true
            source.cancel()
            if !started { source.resume() }
            continuation.finish()
        }
    }

    deinit { stop() }
}

/// Blocking syscalls run on dedicated read/write queues, never Swift's actor
/// executor or the capture queue. Shutdown unblocks both directions. The fd is
/// closed only after queued operations release this object, preventing reuse
/// races when disconnect/reconnect overlaps an in-flight send.
public final class SocketVideoTransport: PacketTransport, @unchecked Sendable {
    private let fd: Int32
    private let readQueue = DispatchQueue(label: "one.transom.host.video.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "one.transom.host.video.write", qos: .userInteractive)
    private let state = NSLock()
    private var closed = false

    init(owning fd: Int32) throws {
        self.fd = fd
        do {
            var enabled: Int32 = 1
            for (level, option) in [(SOL_SOCKET, SO_NOSIGPIPE), (IPPROTO_TCP, TCP_NODELAY), (SOL_SOCKET, SO_KEEPALIVE)] {
                guard setsockopt(fd, level, option, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0
                else { throw socketError() }
            }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0,
                fcntl(fd, F_SETFL, 0) == 0
            else { throw socketError() }
        } catch {
            // A throwing class initializer runs deinit after stored properties
            // are initialized, which owns the actual descriptor close.
            closeNow()
            throw error
        }
    }

    public func send(_ payload: Data) async throws {
        let bytes = WireCodec.frame(payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async { [self] in
                do {
                    try ensureOpen()
                    try bytes.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < raw.count {
                            try ensureOpen()
                            let count = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                            if count < 0 && errno == EINTR { continue }
                            guard count > 0 else { throw socketError() }
                            offset += count
                        }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func receiveFrame() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            readQueue.async { [self] in
                do {
                    guard let header = try readExactly(4, allowEOF: true) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    guard length <= 64 * 1024 * 1024 else { throw POSIXError(.EMSGSIZE) }
                    continuation.resume(returning: try readExactly(Int(length), allowEOF: false))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func readExactly(_ length: Int, allowEOF: Bool) throws -> Data? {
        var data = Data(count: length)
        var eof = false
        try data.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < length {
                try ensureOpen()
                let count = recv(fd, raw.baseAddress!.advanced(by: offset), length - offset, 0)
                if count < 0 && errno == EINTR { continue }
                if count == 0 && offset == 0 && allowEOF { eof = true; return }
                guard count > 0 else { throw count == 0 ? POSIXError(.ECONNRESET) : socketError() }
                offset += count
            }
        }
        return eof ? nil : data
    }

    private func ensureOpen() throws {
        if state.withLock({ closed }) { throw POSIXError(.ECANCELED) }
    }

    public func close() async { closeNow() }

    func closeNow() {
        state.withLock {
            guard !closed else { return }
            closed = true
            shutdown(fd, SHUT_RDWR)
        }
    }

    deinit { Darwin.close(fd) }
}

private func socketError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
