/// The resize throttle: decides which of a flood of `RequestResize` messages
/// actually reaches AX (issue #6 Phase 4, protocol.md §5, architecture.md 2.1).
///
/// `WM_SIZING` on the client fires far faster than an AX write can settle (a
/// roundtrip is 30ms+), so applying every `live` request would queue AX writes
/// that lag the drag badly. This limits `live` to roughly `1/interval` Hz.
///
/// It is a **pure value type with time injected**: it never reads a clock,
/// touches AX, or spawns a task, so it can be — and is — unit tested with
/// synthetic timestamps and no Mac (`Tests/TransomKitTests/ResizeThrottleTests`).
/// The impure shell that supplies the clock and performs the write is
/// `ResizeService`.
///
/// Rules, straight from the constraints in issue #6:
/// - **`live` is throttled** to at most one write per `interval` (leading edge).
/// - **the last `live` in a burst is never silently dropped.** A coalesced
///   request is remembered and released by `onTick` once its window elapses, so a
///   drag that pauses still catches up rather than freezing a window a step behind.
/// - **`end` is authoritative** — the 1:1 snap. It is never throttled and never
///   dropped, even if a `live` at the same size just landed.
/// - **`begin` primes** the throttle so the first `live` of a drag applies
///   immediately; it needs no write of its own (the window is already that size).
public struct ResizeThrottle {

    /// What the caller should do with a request. `write` carries the id + size to
    /// push to AX now; `none` means the request was dropped or coalesced.
    public enum Outcome: Equatable, Sendable {
        case write(id: UInt64, size: WireSize)
        case none
    }

    /// Minimum seconds between applied `live` writes. 0.1 == ~10Hz (issue #6).
    public let interval: Double

    /// Time the last write was applied, or nil before the first of a drag.
    private var lastApply: Double?
    /// The newest `live` request seen inside the current throttle window, held for
    /// a trailing flush. Cleared whenever a write is applied.
    private var pending: (id: UInt64, size: WireSize)?

    public init(interval: Double = 0.1) {
        self.interval = interval
    }

    /// Whether a coalesced `live` is waiting for its window to elapse. The impure
    /// shell uses this to know it should keep ticking.
    public var hasPending: Bool { pending != nil }

    /// Feed one client `RequestResize`. `now` is monotonic seconds (injected).
    public mutating func onRequest(
        id: UInt64, size: WireSize, phase: ResizePhase, now: Double
    ) -> Outcome {
        switch phase {
        case .begin:
            // Drag starting: prime so the first `live` writes immediately, and do
            // not write here — the window already has this size.
            lastApply = nil
            pending = nil
            return .none

        case .end:
            // Authoritative 1:1 snap. Never throttled, never dropped.
            lastApply = now
            pending = nil
            return .write(id: id, size: size)

        case .live:
            if let last = lastApply, now - last < interval {
                // Inside the window: remember the newest size for a trailing flush.
                pending = (id, size)
                return .none
            }
            lastApply = now
            pending = nil
            return .write(id: id, size: size)
        }
    }

    /// Release a coalesced `live` once its throttle window has elapsed. Drive from
    /// a periodic tick; returns `.none` until there is a pending request whose
    /// window is up.
    public mutating func onTick(now: Double) -> Outcome {
        guard let p = pending, let last = lastApply, now - last >= interval else {
            return .none
        }
        lastApply = now
        pending = nil
        return .write(id: p.id, size: p.size)
    }
}
