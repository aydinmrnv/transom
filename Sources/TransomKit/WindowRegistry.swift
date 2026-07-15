import ApplicationServices
import Foundation

/// Mints and owns the opaque `u64` window identity the wire uses (protocol.md §3),
/// and the mapping to the `AXUIElement` it stands for.
///
/// The client never interprets the id; it is just a token it keys its proxy
/// windows on. Keeping the AX↔id correlation confined to this type is exactly
/// what protocol.md asks for: however OQ-3 is eventually resolved (private
/// `_AXUIElementGetWindow`, frame heuristics, …), it stays behind this wall.
///
/// Thread-safe: the AX watcher mutates it from a run-loop thread while the control
/// server reads snapshots from an async task, so every access is under one lock.
public final class WindowRegistry: @unchecked Sendable {

    public struct Entry: Sendable, Equatable {
        public let id: UInt64
        public var rect: WireRect
        public var title: String
    }

    /// `AXUIElement` is a CF type; wrap it so it is a dictionary key via
    /// `CFEqual`/`CFHash` regardless of whether the SDK bridges `Hashable`.
    private struct ElementKey: Hashable {
        let element: AXUIElement
        static func == (a: ElementKey, b: ElementKey) -> Bool { CFEqual(a.element, b.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    private let lock = NSLock()
    private var nextID: UInt64 = 1
    private var idByElement: [ElementKey: UInt64] = [:]
    private var elementByID: [UInt64: AXUIElement] = [:]
    private var entries: [UInt64: Entry] = [:]

    public init() {}

    /// The id for this element, minting a fresh one the first time it is seen.
    public func id(for element: AXUIElement) -> (id: UInt64, isNew: Bool) {
        lock.withLock {
            let key = ElementKey(element: element)
            if let existing = idByElement[key] { return (existing, false) }
            let id = nextID
            nextID += 1
            idByElement[key] = id
            elementByID[id] = element
            return (id, true)
        }
    }

    /// The AX element behind an id, for driving AX writes (Phase 4) and input
    /// injection / window raising (Phase 5).
    public func element(for id: UInt64) -> AXUIElement? {
        lock.withLock { elementByID[id] }
    }

    /// The current recorded state for an id (its VDS rect + title), or nil if the
    /// id is unknown. Input injection reads the rect to translate a window-local
    /// click into VDS/AX space (issue #7).
    public func entry(for id: UInt64) -> Entry? {
        lock.withLock { entries[id] }
    }

    public func record(id: UInt64, rect: WireRect, title: String) {
        lock.withLock { entries[id] = Entry(id: id, rect: rect, title: title) }
    }

    public func updateRect(id: UInt64, rect: WireRect) {
        lock.withLock { entries[id]?.rect = rect }
    }

    public func updateTitle(id: UInt64, title: String) {
        lock.withLock { entries[id]?.title = title }
    }

    /// Forget an element (on destroy). Returns its id if it was known.
    public func remove(element: AXUIElement) -> UInt64? {
        lock.withLock {
            let key = ElementKey(element: element)
            guard let id = idByElement[key] else { return nil }
            idByElement[key] = nil
            elementByID[id] = nil
            entries[id] = nil
            return id
        }
    }

    /// Every live window's current state, id-ordered — the payload for a fresh
    /// client's resync.
    public func snapshot() -> [Entry] {
        lock.withLock { entries.values.sorted { $0.id < $1.id } }
    }
}
