import Foundation

/// The Transom wire protocol (issue #3 Phase 3), the concrete realisation of
/// `docs/protocol.md`.
///
/// The client is a separate Rust codebase on a separate machine that codes
/// against `docs/protocol.md`, so the JSON shapes here are a **contract**: every
/// message is a flat JSON object with a `"type"` discriminator and explicitly
/// named fields (not Swift's default enum-with-associated-values encoding, which
/// no other language would guess). If you change a shape here, change
/// `docs/protocol.md` in the same commit.
///
/// All coordinates are **VDS physical pixels, unsigned 32-bit** (I-2, I-3). Never
/// points, never scaled units.

// MARK: - Value types

/// A rectangle in VDS physical pixels: origin top-left, Y down (I-3).
public struct WireRect: Codable, Equatable, Sendable {
    public var x: UInt32
    public var y: UInt32
    public var w: UInt32
    public var h: UInt32
    public init(x: UInt32, y: UInt32, w: UInt32, h: UInt32) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

/// A size in physical pixels.
public struct WireSize: Codable, Equatable, Sendable {
    public var w: UInt32
    public var h: UInt32
    public init(w: UInt32, h: UInt32) {
        self.w = w
        self.h = h
    }
}

/// One window's id + rect, as carried in a tile layout.
public struct WireWindow: Codable, Equatable, Sendable {
    public var id: UInt64
    public var rect: WireRect
    public init(id: UInt64, rect: WireRect) {
        self.id = id
        self.rect = rect
    }
}

/// What kind of surface a window is. The client must not give a menu a resizable
/// frame or an Alt-Tab entry, so the taxonomy travels on the wire.
public enum WindowKind: String, Codable, Sendable {
    case normal
    case menu
    case sheet
    case popover
}

/// Maps to the client's `WM_ENTERSIZEMOVE` / `WM_SIZING` / `WM_EXITSIZEMOVE`
/// (protocol.md §5). The host throttles `live` and treats `end` as the
/// authoritative 1:1 snap.
public enum ResizePhase: String, Codable, Sendable {
    case begin
    case live
    case end
}

/// The protocol version carried in `hello`. Bump on any breaking wire change.
public let transomProtocolVersion = 1

// MARK: - Host -> Client

public enum ControlMessage: Sendable, Equatable {
    /// First message on a fresh control connection: version + the full virtual
    /// display size, so the client can sanity-check every rect it receives.
    case hello(protocolVersion: Int, vdsSize: WireSize)
    case windowCreated(id: UInt64, rect: WireRect, title: String, kind: WindowKind)
    /// ACTUAL geometry after an AX write or an observed move (I-4), never requested.
    case windowMoved(id: UInt64, rect: WireRect)
    case windowDestroyed(id: UInt64)
    case windowTitle(id: UInt64, title: String)
    case windowFocused(id: UInt64)
    case tileLayout(windows: [WireWindow], displaySize: WireSize)
    case error(code: UInt32, message: String)
}

// MARK: - Client -> Host

public enum ClientMessage: Sendable, Equatable {
    case requestResize(id: UInt64, size: WireSize, phase: ResizePhase)
    case requestFocus(id: UInt64)
    case requestClose(id: UInt64)
    /// A click/type/scroll targeted at window `id` (issue #7). `event` carries
    /// window-local physical pixels / Windows VK codes (see `InputEvent`); `ts` is
    /// the client's monotonic timestamp in milliseconds, opaque to the host in v1.
    case input(id: UInt64, event: InputEvent, ts: UInt64)
}

// MARK: - Codable (explicit, cross-language JSON)

extension ControlMessage: Codable {
    private enum Key: String, CodingKey {
        case type, id, rect, title, kind, windows, displaySize
        case protocolVersion = "protocol"
        case vdsSize, code, message
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .hello(let version, let vdsSize):
            try c.encode("hello", forKey: .type)
            try c.encode(version, forKey: .protocolVersion)
            try c.encode(vdsSize, forKey: .vdsSize)
        case .windowCreated(let id, let rect, let title, let kind):
            try c.encode("windowCreated", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(rect, forKey: .rect)
            try c.encode(title, forKey: .title)
            try c.encode(kind, forKey: .kind)
        case .windowMoved(let id, let rect):
            try c.encode("windowMoved", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(rect, forKey: .rect)
        case .windowDestroyed(let id):
            try c.encode("windowDestroyed", forKey: .type)
            try c.encode(id, forKey: .id)
        case .windowTitle(let id, let title):
            try c.encode("windowTitle", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(title, forKey: .title)
        case .windowFocused(let id):
            try c.encode("windowFocused", forKey: .type)
            try c.encode(id, forKey: .id)
        case .tileLayout(let windows, let displaySize):
            try c.encode("tileLayout", forKey: .type)
            try c.encode(windows, forKey: .windows)
            try c.encode(displaySize, forKey: .displaySize)
        case .error(let code, let message):
            try c.encode("error", forKey: .type)
            try c.encode(code, forKey: .code)
            try c.encode(message, forKey: .message)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "hello":
            self = .hello(
                protocolVersion: try c.decode(Int.self, forKey: .protocolVersion),
                vdsSize: try c.decode(WireSize.self, forKey: .vdsSize))
        case "windowCreated":
            self = .windowCreated(
                id: try c.decode(UInt64.self, forKey: .id),
                rect: try c.decode(WireRect.self, forKey: .rect),
                title: try c.decode(String.self, forKey: .title),
                kind: try c.decode(WindowKind.self, forKey: .kind))
        case "windowMoved":
            self = .windowMoved(
                id: try c.decode(UInt64.self, forKey: .id),
                rect: try c.decode(WireRect.self, forKey: .rect))
        case "windowDestroyed":
            self = .windowDestroyed(id: try c.decode(UInt64.self, forKey: .id))
        case "windowTitle":
            self = .windowTitle(
                id: try c.decode(UInt64.self, forKey: .id),
                title: try c.decode(String.self, forKey: .title))
        case "windowFocused":
            self = .windowFocused(id: try c.decode(UInt64.self, forKey: .id))
        case "tileLayout":
            self = .tileLayout(
                windows: try c.decode([WireWindow].self, forKey: .windows),
                displaySize: try c.decode(WireSize.self, forKey: .displaySize))
        case "error":
            self = .error(
                code: try c.decode(UInt32.self, forKey: .code),
                message: try c.decode(String.self, forKey: .message))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown ControlMessage type \"\(type)\"")
        }
    }
}

extension ClientMessage: Codable {
    private enum Key: String, CodingKey {
        case type, id, size, phase, event, ts
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .requestResize(let id, let size, let phase):
            try c.encode("requestResize", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(size, forKey: .size)
            try c.encode(phase, forKey: .phase)
        case .requestFocus(let id):
            try c.encode("requestFocus", forKey: .type)
            try c.encode(id, forKey: .id)
        case .requestClose(let id):
            try c.encode("requestClose", forKey: .type)
            try c.encode(id, forKey: .id)
        case .input(let id, let event, let ts):
            try c.encode("input", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(event, forKey: .event)
            try c.encode(ts, forKey: .ts)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "requestResize":
            self = .requestResize(
                id: try c.decode(UInt64.self, forKey: .id),
                size: try c.decode(WireSize.self, forKey: .size),
                phase: try c.decode(ResizePhase.self, forKey: .phase))
        case "requestFocus":
            self = .requestFocus(id: try c.decode(UInt64.self, forKey: .id))
        case "requestClose":
            self = .requestClose(id: try c.decode(UInt64.self, forKey: .id))
        case "input":
            self = .input(
                id: try c.decode(UInt64.self, forKey: .id),
                event: try c.decode(InputEvent.self, forKey: .event),
                ts: try c.decode(UInt64.self, forKey: .ts))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown ClientMessage type \"\(type)\"")
        }
    }
}

// MARK: - Framing

/// Length-prefixed framing over a byte stream (protocol.md §1): each message is a
/// 4-byte big-endian unsigned length followed by that many JSON bytes. This is
/// the only stream-specific concern; on a datagram transport (M3 UDP) each
/// datagram is already one message and this disappears, which is why it lives
/// behind `PacketTransport` (see `Transport.swift`).
public enum WireCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public static func encode(_ message: ControlMessage) throws -> Data {
        try encoder.encode(message)
    }
    public static func encode(_ message: ClientMessage) throws -> Data {
        try encoder.encode(message)
    }
    public static func decodeControl(_ data: Data) throws -> ControlMessage {
        try decoder.decode(ControlMessage.self, from: data)
    }
    public static func decodeClient(_ data: Data) throws -> ClientMessage {
        try decoder.decode(ClientMessage.self, from: data)
    }

    /// Prefix a payload with its 4-byte big-endian length.
    public static func frame(_ payload: Data) -> Data {
        let length = UInt32(payload.count).bigEndian
        var out = Data(capacity: payload.count + 4)
        withUnsafeBytes(of: length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// Frame a control message in one step.
    public static func framed(_ message: ControlMessage) throws -> Data {
        frame(try encode(message))
    }
}

/// The **video** channel payload format (protocol.md §6). Video is binary and
/// per-frame at 60fps, so JSON would be wrong here: each framed message on the
/// video transport is one of these, distinguished by a leading type byte.
///
/// - `config` (0x01): the HEVC `hvcC` parameter sets. Sent once before the first
///   frame (and again after a reconnect), because an `hvc1` stream carries no
///   inline parameter sets and the decoder needs them first.
/// - `frame` (0x02): `seq: u64` · `ptsMicros: u64` · `flags: u8` (bit0 = keyframe)
///   · the HEVC access-unit bytes. All integers big-endian.
public enum VideoWire {
    public enum Message: Equatable, Sendable {
        case config(hvcc: Data)
        case frame(seq: UInt64, ptsMicros: UInt64, keyframe: Bool, data: Data)
    }

    public static func encodeConfig(hvcc: Data) -> Data {
        var out = Data([0x01])
        out.append(hvcc)
        return out
    }

    public static func encodeFrame(seq: UInt64, ptsMicros: UInt64, keyframe: Bool, data: Data)
        -> Data
    {
        var out = Data([0x02])
        out.append(contentsOf: bigEndianBytes(seq))
        out.append(contentsOf: bigEndianBytes(ptsMicros))
        out.append(keyframe ? 1 : 0)
        out.append(data)
        return out
    }

    public static func decode(_ payload: Data) -> Message? {
        let bytes = [UInt8](payload)
        guard let type = bytes.first else { return nil }
        switch type {
        case 0x01:
            return .config(hvcc: Data(bytes.dropFirst()))
        case 0x02:
            guard bytes.count >= 18 else { return nil }
            let seq = beUInt64(bytes, 1)
            let pts = beUInt64(bytes, 9)
            let keyframe = bytes[17] != 0
            return .frame(seq: seq, ptsMicros: pts, keyframe: keyframe, data: Data(bytes[18...]))
        default:
            return nil
        }
    }

    private static func bigEndianBytes(_ v: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((v >> (8 * (7 - $0))) & 0xFF) }
    }
    private static func beUInt64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(bytes[offset + i]) }
        return v
    }
}

/// Reassembles length-prefixed frames from a byte stream that arrives in
/// arbitrary chunks. Pure and stream-agnostic, so it is unit tested. Backed by a
/// `[UInt8]` to sidestep `Data`'s non-zero-based slice indices.
public struct FrameBuffer {
    public enum FrameError: Error, Equatable {
        case frameTooLarge(length: Int, max: Int)
    }

    private var bytes: [UInt8] = []
    private let maxFrameLength: Int

    /// - Parameter maxFrameLength: reject frames claiming to be larger than this,
    ///   so a corrupt or hostile length can't make us buffer unbounded memory.
    public init(maxFrameLength: Int = 64 * 1024 * 1024) {
        self.maxFrameLength = maxFrameLength
    }

    public mutating func append(_ data: Data) {
        bytes.append(contentsOf: data)
    }

    /// Pop the next complete frame's payload, or nil if not enough bytes yet.
    public mutating func next() throws -> Data? {
        guard bytes.count >= 4 else { return nil }
        let length =
            (Int(bytes[0]) << 24) | (Int(bytes[1]) << 16) | (Int(bytes[2]) << 8) | Int(bytes[3])
        guard length <= maxFrameLength else {
            throw FrameError.frameTooLarge(length: length, max: maxFrameLength)
        }
        let total = 4 + length
        guard bytes.count >= total else { return nil }
        let payload = Data(bytes[4..<total])
        bytes.removeFirst(total)
        return payload
    }
}
