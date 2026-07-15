import ArgumentParser
import Foundation
import TransomKit

/// `mock-client` — a stand-in for the not-yet-existent Rust client, so input can
/// be verified **over the wire** (issue #7, I-7). It connects to a running
/// `serve` control channel, consumes the resync (`hello` + `windowCreated`* +
/// `tileLayout`) to learn window ids and rects, then sends `Input` /
/// `RequestFocus` messages — the exact bytes the real client will send.
///
/// This closes the loop the issue's verification checklist asks for: a client
/// posting a click at a known window-local coordinate, with the host translating
/// and the app responding. Run `serve` in one terminal and this in another.
struct MockClient: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mock-client",
        abstract: "Connect to a serve control channel and post input events (verification harness)."
    )

    @Option(name: .long, help: "Host to connect to.")
    var host: String = "127.0.0.1"

    @Option(name: .long, help: "Control channel TCP port.")
    var controlPort: UInt16 = 7000

    @Option(name: .long, help: "Target window id (from the printed resync listing).")
    var id: UInt64?

    @Flag(name: .long, help: "Send RequestFocus for --id.")
    var focus: Bool = false

    @Flag(name: .long, help: "Click at --x/--y inside --id.")
    var click: Bool = false

    @Option(name: .long, help: "Window-local x (physical pixels) for --click.")
    var x: UInt32?

    @Option(name: .long, help: "Window-local y (physical pixels) for --click.")
    var y: UInt32?

    @Option(name: .long, help: "Mouse button: left | right | middle.")
    var button: String = "left"

    @Option(name: .long, help: "Type this text into --id (a RequestFocus is sent first).")
    var type: String?

    @Option(
        name: .long, help: "Send a chord in Windows-side names, e.g. \"ctrl+a\" (→ ⌘A), into --id.")
    var chord: String?

    @Flag(name: .long, help: "Only print the resync (discovered windows) and exit.")
    var listOnly: Bool = false

    @Option(name: .long, help: "Milliseconds between sent events.")
    var stepMs: Int = 14

    func run() async throws {
        setvbuf(stdout, nil, _IONBF, 0)

        let transport = try await TCPTransport.connect(host: host, port: controlPort)
        print("mock-client: connected to \(host):\(controlPort)")

        let windows = try await readResync(transport)
        print("mock-client: discovered \(windows.count) window(s):")
        for w in windows.sorted(by: { $0.key < $1.key }) {
            let r = w.value
            print("  id=\(w.key)  rect=(x:\(r.x) y:\(r.y) w:\(r.w) h:\(r.h)) px")
        }

        if listOnly {
            await transport.close()
            return
        }

        // A timestamp counter, standing in for the client's monotonic clock (ms).
        var ts: UInt64 = 1

        if focus, let id {
            print("mock-client: -> RequestFocus id=\(id)")
            try await send(transport, .requestFocus(id: id))
            try await step()
        }

        if click {
            guard let id, let x, let y else {
                throw ProbeError("--click needs --id, --x and --y.")
            }
            guard let mb = MouseButton(rawValue: button) else {
                throw ProbeError("unknown button \"\(button)\" (use left/right/middle).")
            }
            print("mock-client: -> Input mouseDown/up id=\(id) local=(\(x),\(y)) button=\(button)")
            try await send(transport, .input(id: id, event: .mouseMove(x: x, y: y), ts: bump(&ts)))
            try await step()
            try await send(
                transport, .input(id: id, event: .mouseDown(x: x, y: y, button: mb), ts: bump(&ts)))
            try await step()
            try await send(
                transport, .input(id: id, event: .mouseUp(x: x, y: y, button: mb), ts: bump(&ts)))
            try await step()
        }

        if let type {
            guard let id else { throw ProbeError("--type needs --id.") }
            let (events, unsupported) = MockInput.typing(type)
            if !unsupported.isEmpty {
                print(
                    "mock-client: note: unsupported chars dropped: \(unsupported.map(String.init).joined())"
                )
            }
            print("mock-client: -> RequestFocus + \(events.count) key event(s) to type \"\(type)\"")
            try await send(transport, .requestFocus(id: id))
            try await step()
            for event in events {
                try await send(transport, .input(id: id, event: event, ts: bump(&ts)))
                try await step()
            }
        }

        if let chord {
            guard let id else { throw ProbeError("--chord needs --id.") }
            let (events, error) = MockInput.chord(chord)
            if let error { throw ProbeError("bad --chord: \(error)") }
            print(
                "mock-client: -> RequestFocus + chord \"\(chord)\" (\(events.count) key events) to id=\(id)"
            )
            try await send(transport, .requestFocus(id: id))
            try await step()
            for event in events {
                try await send(transport, .input(id: id, event: event, ts: bump(&ts)))
                try await step()
            }
        }

        // Give the host's receive loop a moment to drain before we close.
        try await Task.sleep(nanoseconds: 200_000_000)
        await transport.close()
        print("mock-client: done.")
    }

    // MARK: - Wire

    private func send(_ transport: TCPTransport, _ message: ClientMessage) async throws {
        try await transport.send(try WireCodec.encode(message))
    }

    private func bump(_ ts: inout UInt64) -> UInt64 {
        defer { ts += 1 }
        return ts
    }

    private func step() async throws {
        if stepMs > 0 { try await Task.sleep(nanoseconds: UInt64(stepMs) * 1_000_000) }
    }

    /// Read the resync stream up to and including `tileLayout`, collecting each
    /// window's id → rect. Stops at `tileLayout` (the last resync message).
    private func readResync(_ transport: TCPTransport) async throws -> [UInt64: WireRect] {
        var windows: [UInt64: WireRect] = [:]
        while let frame = try await transport.receiveFrame() {
            let message = try WireCodec.decodeControl(frame)
            switch message {
            case .hello(let version, let vdsSize):
                print("mock-client: hello protocol=\(version) vds=\(vdsSize.w)x\(vdsSize.h)")
            case .windowCreated(let id, let rect, let title, _):
                windows[id] = rect
                print("mock-client:   windowCreated id=\(id) \"\(title)\"")
            case .tileLayout(let ws, _):
                for w in ws where windows[w.id] == nil { windows[w.id] = w.rect }
                return windows
            default:
                continue
            }
        }
        return windows
    }
}
