import Testing

@testable import TransomKit

/// Unit tests for the layout guard (I-5): when a Mac-side move or resize has left
/// the windows overlapping, and when the host should stay out of it.
@Suite("LayoutGuard")
struct LayoutGuardTests {

    private let display = TileSize(width: 2000, height: 1000)
    private let a = TileRect(x: 0, y: 0, width: 800, height: 600)
    private let b = TileRect(x: 1000, y: 0, width: 800, height: 600)
    /// `a` dragged right until it covers part of `b`.
    private let aOverB = TileRect(x: 600, y: 0, width: 800, height: 600)
    /// `a` dragged left past the display edge.
    private let aOffDisplay = TileRect(x: -40, y: 0, width: 800, height: 600)

    private func poll(_ guardState: inout LayoutGuard, _ windows: [TileRect], pointerDown: Bool = false)
        -> Bool
    {
        guardState.shouldRetile(windows: windows, display: display, pointerDown: pointerDown)
    }

    @Test("isNonOverlapping accepts a tiled layout and rejects overlap or an off-display window")
    func validity() {
        #expect(Tiler.isNonOverlapping([a, b], on: display))
        #expect(Tiler.isNonOverlapping([], on: display))
        #expect(!Tiler.isNonOverlapping([aOverB, b], on: display))
        #expect(!Tiler.isNonOverlapping([aOffDisplay, b], on: display))
        #expect(!Tiler.isNonOverlapping([a, TileRect(x: 1000, y: 500, width: 800, height: 600)], on: display))
    }

    @Test("a valid layout never asks for a re-tile")
    func validLayoutIsLeftAlone() {
        var guardState = LayoutGuard()
        for _ in 0..<4 { #expect(!poll(&guardState, [a, b])) }
    }

    @Test("an overlap is repaired once it has held still for two polls")
    func settledOverlapRetiles() {
        var guardState = LayoutGuard()
        #expect(!poll(&guardState, [aOverB, b]))
        #expect(poll(&guardState, [aOverB, b]))
    }

    @Test("a window off the display counts, and focus order does not")
    func offDisplayAndOrder() {
        var guardState = LayoutGuard()
        #expect(!poll(&guardState, [aOffDisplay, b]))
        // AX now lists the windows the other way round: same layout.
        #expect(poll(&guardState, [b, aOffDisplay]))
    }

    @Test("a layout that is still changing is not touched")
    func movingLayoutWaits() {
        var guardState = LayoutGuard()
        #expect(!poll(&guardState, [aOverB, b]))
        #expect(!poll(&guardState, [TileRect(x: 700, y: 0, width: 800, height: 600), b]))
        #expect(!poll(&guardState, [TileRect(x: 800, y: 0, width: 800, height: 600), b]))
        #expect(poll(&guardState, [TileRect(x: 800, y: 0, width: 800, height: 600), b]))
    }

    @Test("nothing is re-tiled while the client holds a mouse button")
    func dragInProgressWaits() {
        var guardState = LayoutGuard()
        for _ in 0..<4 { #expect(!poll(&guardState, [aOverB, b], pointerDown: true)) }
        // Released: the layout must still settle for a poll before the repair.
        #expect(!poll(&guardState, [aOverB, b]))
        #expect(poll(&guardState, [aOverB, b]))
    }

    @Test("a layout a re-tile could not repair is left alone until it changes")
    func failedLayoutIsNotRetried() {
        var guardState = LayoutGuard()
        _ = poll(&guardState, [aOverB, b])
        #expect(poll(&guardState, [aOverB, b]))
        guardState.retileFailed(windows: [aOverB, b])
        for _ in 0..<4 { #expect(!poll(&guardState, [b, aOverB])) }

        // A different overlap is a new problem and gets its own attempt.
        #expect(!poll(&guardState, [aOffDisplay, b]))
        #expect(poll(&guardState, [aOffDisplay, b]))
    }

    @Test("repeated failures stop the guard until the layout is valid again")
    func failureBudget() {
        var guardState = LayoutGuard()
        for step in 0..<LayoutGuard.maxFailures {
            let layout = [TileRect(x: 600 + step, y: 0, width: 800, height: 600), b]
            _ = poll(&guardState, layout)
            #expect(poll(&guardState, layout))
            guardState.retileFailed(windows: layout)
        }
        let another = [TileRect(x: 500, y: 0, width: 800, height: 600), b]
        for _ in 0..<4 { #expect(!poll(&guardState, another)) }

        #expect(!poll(&guardState, [a, b]))
        #expect(!poll(&guardState, [aOverB, b]))
        #expect(poll(&guardState, [aOverB, b]))
    }
}
