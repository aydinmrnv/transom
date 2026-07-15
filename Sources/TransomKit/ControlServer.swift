import Foundation

/// The control channel server (issue #3 Phase 3): one TCP client at a time,
/// receives lifecycle + geometry events and pushes them as protocol messages;
/// reads client requests back.
///
/// Reconnect is a first-class requirement: if the client drops, the host keeps
/// running (capture and AX never stop), and when the client reconnects it gets a
/// **full resync** — `hello`, a `windowCreated` for every live window, and a
/// `tileLayout` — from the registry, then resumes the live stream. No restart.
///
/// An actor so `broadcast` (driven from the event forwarding task) and the
/// per-connection send/receive interleave safely without a lock.
public actor ControlServer {
    private let vdsSize: WireSize
    private let registry: WindowRegistry
    private var active: TCPTransport?

    /// Called for every decoded client→host message (e.g. `requestResize`,
    /// `input`). Phase 5 wires this to AX + `CGEventPost` via `InputInjector`.
    public var onClientMessage: (@Sendable (ClientMessage) -> Void)?

    /// Called with `true` when a client connects and `false` when it disconnects
    /// or is dropped, so a status UI can show whether a client is attached and the
    /// input layer can reset held modifiers between sessions (issue #7). Fired
    /// from the actor; the closure must be thread-safe.
    public var onConnectionChange: (@Sendable (Bool) -> Void)?

    public init(vdsSize: WireSize, registry: WindowRegistry) {
        self.vdsSize = vdsSize
        self.registry = registry
    }

    public func setOnClientMessage(_ handler: @escaping @Sendable (ClientMessage) -> Void) {
        self.onClientMessage = handler
    }

    public func setOnConnectionChange(_ handler: @escaping @Sendable (Bool) -> Void) {
        self.onConnectionChange = handler
    }

    /// Accept connections forever (one active at a time). Each `handle` runs until
    /// that client disconnects, then the next connection is served.
    public func serve(listener: TCPListener) async {
        for await transport in listener.connections {
            await handle(transport)
        }
    }

    /// Push one observed window event to the connected client, if any. On send
    /// failure the connection is dropped; the next reconnect resyncs from the
    /// registry, so nothing is left half-described.
    public func broadcast(_ event: WindowWatcher.WindowEvent) async {
        guard let active else { return }
        do {
            try await active.send(try WireCodec.encode(Self.message(for: event)))
        } catch {
            Log.general.notice(
                "control: send failed, dropping client: \(error.localizedDescription, privacy: .public)"
            )
            self.active = nil
            onConnectionChange?(false)
        }
    }

    private func handle(_ transport: TCPTransport) async {
        active = transport
        Log.general.notice("control: client connected")
        onConnectionChange?(true)

        do {
            try await sendResync(to: transport)
        } catch {
            Log.general.notice(
                "control: resync failed: \(error.localizedDescription, privacy: .public)")
            if active === transport { active = nil }
            onConnectionChange?(false)
            await transport.close()
            return
        }

        // Read client→host messages until the peer closes.
        do {
            while let frame = try await transport.receiveFrame() {
                guard let message = try? WireCodec.decodeClient(frame) else {
                    Log.general.notice("control: undecodable client frame ignored")
                    continue
                }
                onClientMessage?(message)
            }
        } catch {
            Log.general.notice(
                "control: receive ended: \(error.localizedDescription, privacy: .public)")
        }

        Log.general.notice("control: client disconnected")
        if active === transport { active = nil }
        onConnectionChange?(false)
        await transport.close()
    }

    /// hello + a windowCreated per live window + the current tile layout.
    private func sendResync(to transport: TCPTransport) async throws {
        try await transport.send(
            try WireCodec.encode(
                .hello(protocolVersion: transomProtocolVersion, vdsSize: vdsSize)))
        let entries = registry.snapshot()
        for entry in entries {
            try await transport.send(
                try WireCodec.encode(
                    .windowCreated(
                        id: entry.id, rect: entry.rect, title: entry.title, kind: .normal)))
        }
        let windows = entries.map { WireWindow(id: $0.id, rect: $0.rect) }
        try await transport.send(
            try WireCodec.encode(.tileLayout(windows: windows, displaySize: vdsSize)))
    }

    private static func message(for event: WindowWatcher.WindowEvent) -> ControlMessage {
        switch event {
        case .created(let id, let rect, let title):
            return .windowCreated(id: id, rect: rect, title: title, kind: .normal)
        case .moved(let id, let rect):
            return .windowMoved(id: id, rect: rect)
        case .destroyed(let id):
            return .windowDestroyed(id: id)
        case .titleChanged(let id, let title):
            return .windowTitle(id: id, title: title)
        case .focused(let id):
            return .windowFocused(id: id)
        }
    }
}
