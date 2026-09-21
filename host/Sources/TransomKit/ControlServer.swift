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
    private let gutter: Int
    private let independentWindows: Bool
    private var sentBounds: [UInt64: WireSize] = [:]
    private var active: (id: UUID, transport: any PacketTransport)?
    private var stopped = false
    private var catalog: [AvailableWindow]?

    /// Called for every decoded client→host message (e.g. `requestResize`,
    /// `input`). Phase 5 wires this to AX + `CGEventPost` via `InputInjector`.
    public var onClientMessage: (@Sendable (ClientMessage) -> Void)?

    /// Called with `true` when a client connects and `false` when it disconnects
    /// or is dropped, so a status UI can show whether a client is attached and the
    /// input layer can reset held modifiers between sessions (issue #7). Fired
    /// from the actor; the closure must be thread-safe.
    public var onConnectionChange: (@Sendable (Bool) -> Void)?

    public init(vdsSize: WireSize, registry: WindowRegistry, gutter: Int = Tiler.defaultGutter, independentWindows: Bool = false) {
        self.vdsSize = vdsSize
        self.registry = registry
        self.gutter = gutter
        self.independentWindows = independentWindows
    }

    public func setOnClientMessage(_ handler: @escaping @Sendable (ClientMessage) -> Void) {
        self.onClientMessage = handler
    }

    public func setOnConnectionChange(_ handler: @escaping @Sendable (Bool) -> Void) {
        self.onConnectionChange = handler
    }

    /// Accept connections forever (one active at a time). Each connection runs until
    /// that client disconnects, then the next connection is served.
    public func serve(listener: TCPListener) async {
        for await transport in listener.connections {
            await serveConnection(transport)
        }
    }

    /// Cancelling the listener does not close its accepted connections. Close the
    /// transport explicitly so an outstanding receive wakes up when sharing ends.
    public func stop() async {
        stopped = true
        guard let active else { return }
        self.active = nil
        onConnectionChange?(false)
        await active.transport.close()
    }

    /// Push one observed window event to the connected client, if any. On send
    /// failure the connection is dropped; the next reconnect resyncs from the
    /// registry, so nothing is left half-described.
    public func broadcast(_ event: WindowWatcher.WindowEvent) async {
        await send(Self.message(for: event))
        switch event {
        case .created, .moved, .destroyed: await sendResizeBounds()
        default: break
        }
    }

    private func sendResizeBounds() async {
        let entries = registry.snapshot()
        let display = TileSize(width: Int(vdsSize.w), height: Int(vdsSize.h))
        func tile(_ r: WireRect) -> TileRect { TileRect(x: Int(r.x), y: Int(r.y), width: Int(r.w), height: Int(r.h)) }
        for entry in entries {
            let limit = ResizeClamp.clamp(current: tile(entry.rect), desired: display,
                others: entries.filter { $0.id != entry.id }.map { tile($0.rect) }, display: display, gutter: gutter)
            let maxSize = independentWindows ? vdsSize : WireSize(w: max(entry.rect.w, UInt32(limit.width)), h: max(entry.rect.h, UInt32(limit.height)))
            if sentBounds[entry.id] != maxSize {
                sentBounds[entry.id] = maxSize
                await send(.resizeBounds(id: entry.id, maxSize: maxSize))
            }
        }
        sentBounds = sentBounds.filter { id, _ in entries.contains { $0.id == id } }
    }

    public func send(_ message: ControlMessage) async {
        if case .windowCatalog(let windows) = message { catalog = windows }
        guard let active else { return }
        do {
            try await active.transport.send(try WireCodec.encode(message))
        } catch {
            Log.general.notice(
                "control: send failed, dropping client: \(error.localizedDescription, privacy: .public)"
            )
            if self.active?.id == active.id {
                self.active = nil
                onConnectionChange?(false)
            }
            await active.transport.close()
        }
    }

    func serveConnection(_ transport: any PacketTransport) async {
        guard !stopped, !Task.isCancelled else {
            await transport.close()
            return
        }
        let connectionID = UUID()
        active = (connectionID, transport)
        sentBounds.removeAll()
        Log.general.notice("control: client connected")
        onConnectionChange?(true)

        do {
            try await sendResync(to: transport)
            await sendResizeBounds()
        } catch {
            Log.general.notice(
                "control: resync failed: \(error.localizedDescription, privacy: .public)")
            if active?.id == connectionID {
                active = nil
                onConnectionChange?(false)
            }
            await transport.close()
            return
        }

        // Read client→host messages until the peer closes.
        do {
            while !stopped, let frame = try await transport.receiveFrame() {
                guard !stopped, active?.id == connectionID else { break }
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
        if active?.id == connectionID {
            active = nil
            onConnectionChange?(false)
        }
        await transport.close()
    }

    /// hello + a windowCreated per live window + the current tile layout.
    private func sendResync(to transport: any PacketTransport) async throws {
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
        if let catalog { try await transport.send(try WireCodec.encode(.windowCatalog(windows: catalog))) }
    }

    private static func message(for event: WindowWatcher.WindowEvent) -> ControlMessage {
        switch event {
        case .sharingFailed(let message):
            return .error(code: 2, message: message)
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
