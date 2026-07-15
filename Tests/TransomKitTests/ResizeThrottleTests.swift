import Testing

@testable import TransomKit

/// Unit tests for the pure resize throttle (issue #6 Phase 4). No Mac, no clock,
/// no AX — time is injected — which is the whole point of keeping the throttle a
/// pure value type. These pin the behaviour the issue makes non-negotiable:
/// `live` is rate-limited, the last `live` in a burst is never lost, and `end` is
/// always authoritative.
@Suite("ResizeThrottle")
struct ResizeThrottleTests {

    private let interval = 0.1  // 10Hz
    private func size(_ w: UInt32, _ h: UInt32) -> WireSize { WireSize(w: w, h: h) }

    // MARK: leading edge

    @Test("the first live of a drag applies immediately")
    func firstLiveApplies() {
        var t = ResizeThrottle(interval: interval)
        _ = t.onRequest(id: 1, size: size(800, 600), phase: .begin, now: 0)
        let out = t.onRequest(id: 1, size: size(790, 590), phase: .live, now: 0.001)
        #expect(out == .write(id: 1, size: size(790, 590)))
    }

    @Test("begin does not itself write — the window is already that size")
    func beginDoesNotWrite() {
        var t = ResizeThrottle(interval: interval)
        #expect(t.onRequest(id: 1, size: size(800, 600), phase: .begin, now: 0) == .none)
    }

    // MARK: throttling

    @Test("a live inside the window is coalesced, not written")
    func liveInsideWindowCoalesces() {
        var t = ResizeThrottle(interval: interval)
        _ = t.onRequest(id: 1, size: size(800, 600), phase: .live, now: 0)  // applies (first)
        let out = t.onRequest(id: 1, size: size(790, 590), phase: .live, now: 0.05)
        #expect(out == .none)
        #expect(t.hasPending)
    }

    @Test("a live after the window applies again")
    func liveAfterWindowApplies() {
        var t = ResizeThrottle(interval: interval)
        _ = t.onRequest(id: 1, size: size(800, 600), phase: .live, now: 0)
        let out = t.onRequest(id: 1, size: size(700, 500), phase: .live, now: 0.11)
        #expect(out == .write(id: 1, size: size(700, 500)))
    }

    @Test("a 60Hz burst over 1s yields ~10 writes, not 60")
    func burstIsThrottledToTenHz() {
        var t = ResizeThrottle(interval: interval)
        _ = t.onRequest(id: 1, size: size(1000, 800), phase: .begin, now: 0)
        var writes = 0
        // 60 live requests across one second, plus a tick after each to flush.
        for i in 0..<60 {
            let now = Double(i) / 60.0
            if case .write = t.onRequest(id: 1, size: size(UInt32(1000 - i), 800), phase: .live, now: now) {
                writes += 1
            }
        }
        // Leading-edge writes only (no trailing ticks here): one per ~100ms window.
        #expect(writes >= 9 && writes <= 11, "expected ~10 writes, got \(writes)")
    }

    // MARK: trailing flush

    @Test("a coalesced live flushes on tick once its window elapses")
    func trailingFlush() {
        var t = ResizeThrottle(interval: interval)
        _ = t.onRequest(id: 1, size: size(800, 600), phase: .live, now: 0)  // applies
        _ = t.onRequest(id: 1, size: size(780, 580), phase: .live, now: 0.03)  // coalesced
        _ = t.onRequest(id: 1, size: size(760, 560), phase: .live, now: 0.06)  // coalesced (newest)
        // Before the window elapses, a tick does nothing.
        #expect(t.onTick(now: 0.08) == .none)
        // After it elapses, the newest coalesced size flushes — the last live is
        // never silently dropped (a paused drag still catches up).
        #expect(t.onTick(now: 0.11) == .write(id: 1, size: size(760, 560)))
        // Nothing left pending.
        #expect(t.onTick(now: 0.5) == .none)
        #expect(!t.hasPending)
    }

    @Test("tick with no pending is a no-op")
    func tickNoPending() {
        var t = ResizeThrottle(interval: interval)
        #expect(t.onTick(now: 1.0) == .none)
    }

    // MARK: end is authoritative

    @Test("end always applies, even immediately after a live at the same instant")
    func endAlwaysApplies() {
        var t = ResizeThrottle(interval: interval)
        _ = t.onRequest(id: 1, size: size(800, 600), phase: .live, now: 0)  // applies
        // A live 1ms later would be throttled...
        #expect(t.onRequest(id: 1, size: size(799, 599), phase: .live, now: 0.001) == .none)
        // ...but the End at 2ms is the authoritative snap and must not be dropped.
        #expect(
            t.onRequest(id: 1, size: size(320, 240), phase: .end, now: 0.002)
                == .write(id: 1, size: size(320, 240)))
    }

    @Test("end clears any pending so it can't flush a stale size afterwards")
    func endClearsPending() {
        var t = ResizeThrottle(interval: interval)
        _ = t.onRequest(id: 1, size: size(800, 600), phase: .live, now: 0)
        _ = t.onRequest(id: 1, size: size(780, 580), phase: .live, now: 0.02)  // pending
        _ = t.onRequest(id: 1, size: size(320, 240), phase: .end, now: 0.03)  // authoritative
        #expect(!t.hasPending)
        #expect(t.onTick(now: 1.0) == .none)
    }

    @Test("begin resets so a new drag's first live applies immediately")
    func beginResetsBetweenDrags() {
        var t = ResizeThrottle(interval: interval)
        _ = t.onRequest(id: 1, size: size(800, 600), phase: .live, now: 0)  // applies, lastApply=0
        // A new drag begins much later; its first live should apply, not be gated
        // against the previous drag's clock.
        _ = t.onRequest(id: 1, size: size(800, 600), phase: .begin, now: 0.05)
        #expect(
            t.onRequest(id: 1, size: size(790, 590), phase: .live, now: 0.051)
                == .write(id: 1, size: size(790, 590)))
    }
}
