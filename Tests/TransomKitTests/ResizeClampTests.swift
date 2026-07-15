import Testing

@testable import TransomKit

/// Unit tests for the pure non-overlap resize clamp (issue #6 Phase 4, I-5) — the
/// implementation of the "re-tile question" decision (Option 2: clamp growth at a
/// collision, report the clamped size). Integer geometry, no Mac, so it is tested
/// here rather than only observed on the target.
@Suite("ResizeClamp")
struct ResizeClampTests {

    private let display = TileSize(width: 2000, height: 1000)
    private let gutter = 200

    private func clamp(
        _ current: TileRect, _ desired: TileSize, others: [TileRect] = []
    ) -> TileSize {
        ResizeClamp.clamp(
            current: current, desired: desired, others: others, display: display, gutter: gutter)
    }

    // MARK: N=1 (the real primary case) — only the display edge constrains

    @Test("with no neighbours, growth that fits is returned unchanged")
    func n1FitsUnchanged() {
        let out = clamp(TileRect(x: 0, y: 0, width: 400, height: 300), TileSize(width: 500, height: 400))
        #expect(out == TileSize(width: 500, height: 400))
    }

    @Test("with no neighbours, growth past the right/bottom edge clamps to the edge")
    func n1ClampsToDisplayEdge() {
        // Anchored at (1600,700); the display is 2000x1000, so at most 400x300 fits.
        let out = clamp(
            TileRect(x: 1600, y: 700, width: 200, height: 150), TileSize(width: 900, height: 900))
        #expect(out == TileSize(width: 400, height: 300))
    }

    // MARK: neighbours

    @Test("a neighbour to the right caps width a gutter short of it")
    func rightNeighbourCapsWidth() {
        // Window at (0,0) 400x300; neighbour's left edge at x=600. Growth must stop
        // a gutter (200) short → max width 400 (right edge at 400, gap 200).
        let out = clamp(
            TileRect(x: 0, y: 0, width: 400, height: 300),
            TileSize(width: 800, height: 300),
            others: [TileRect(x: 600, y: 0, width: 400, height: 300)])
        #expect(out == TileSize(width: 400, height: 300))
    }

    @Test("a neighbour below caps height a gutter short of it")
    func belowNeighbourCapsHeight() {
        let out = clamp(
            TileRect(x: 0, y: 0, width: 400, height: 300),
            TileSize(width: 400, height: 800),
            others: [TileRect(x: 0, y: 600, width: 400, height: 300)])
        #expect(out == TileSize(width: 400, height: 400))  // 600 - 200 gutter - 0
    }

    @Test("a neighbour to the left never constrains rightward growth")
    func leftNeighbourDoesNotConstrain() {
        let out = clamp(
            TileRect(x: 600, y: 0, width: 400, height: 300),
            TileSize(width: 800, height: 300),
            others: [TileRect(x: 0, y: 0, width: 400, height: 300)])
        #expect(out == TileSize(width: 800, height: 300))
    }

    @Test("a neighbour that shares no rows does not cap width")
    func nonOverlappingRowsNoWidthCap() {
        // Neighbour is far below; growing wide (but not tall) can't collide with it.
        let out = clamp(
            TileRect(x: 0, y: 0, width: 400, height: 300),
            TileSize(width: 800, height: 300),
            others: [TileRect(x: 600, y: 600, width: 400, height: 300)])
        #expect(out == TileSize(width: 800, height: 300))
    }

    @Test("the tightest of several right neighbours wins")
    func tightestNeighbourWins() {
        let out = clamp(
            TileRect(x: 0, y: 0, width: 300, height: 300),
            TileSize(width: 900, height: 300),
            others: [
                TileRect(x: 900, y: 0, width: 200, height: 300),
                TileRect(x: 700, y: 0, width: 200, height: 300),  // closer → 700-200-0 = 500
            ])
        #expect(out == TileSize(width: 500, height: 300))
    }

    // MARK: degenerate

    @Test("a non-positive desired size is floored to 1px, never zero or negative")
    func nonPositiveFloored() {
        let out = clamp(TileRect(x: 0, y: 0, width: 400, height: 300), TileSize(width: 0, height: -5))
        #expect(out == TileSize(width: 1, height: 1))
    }
}
