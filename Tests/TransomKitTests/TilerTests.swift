import Testing

@testable import TransomKit

/// Unit tests for the pure tiler. No Mac, no AX, no display — just integer
/// geometry, which is the whole point of keeping the tiler pure (issue #3).
@Suite("Tiler")
struct TilerTests {

    // MARK: helpers

    /// Unwrap a success or fail the test with the error.
    private func rects(
        _ windows: [TileSize], _ display: TileSize, gutter: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [TileRect] {
        switch Tiler.layout(windows: windows, display: display, gutter: gutter) {
        case .success(let r): return r
        case .failure(let e):
            Issue.record("expected a layout, got error: \(e)", sourceLocation: sourceLocation)
            throw e
        }
    }

    private func error(
        _ windows: [TileSize], _ display: TileSize, gutter: Int
    ) -> TilerError? {
        switch Tiler.layout(windows: windows, display: display, gutter: gutter) {
        case .success: return nil
        case .failure(let e): return e
        }
    }

    // MARK: input validation

    @Test("empty input is an error, not an empty layout")
    func emptyInput() {
        #expect(error([], TileSize(width: 1000, height: 1000), gutter: 0) == .noWindows)
    }

    @Test("negative gutter is rejected")
    func negativeGutter() {
        #expect(
            error([TileSize(width: 10, height: 10)], TileSize(width: 100, height: 100), gutter: -1)
                == .negativeGutter(-1))
    }

    @Test("a non-positive window size is rejected")
    func nonPositiveSize() {
        let display = TileSize(width: 1000, height: 1000)
        #expect(
            error([TileSize(width: 0, height: 10)], display, gutter: 0)
                == .nonPositiveSize(index: 0, size: TileSize(width: 0, height: 10)))
        #expect(
            error([TileSize(width: 10, height: -5)], display, gutter: 0)
                == .nonPositiveSize(index: 0, size: TileSize(width: 10, height: -5)))
    }

    // MARK: placement

    @Test("a single window lands at the origin at its own size")
    func singleWindow() throws {
        let r = try rects(
            [TileSize(width: 640, height: 480)], TileSize(width: 1000, height: 1000), gutter: 200)
        #expect(r == [TileRect(x: 0, y: 0, width: 640, height: 480)])
    }

    @Test("two windows sit side by side separated by exactly one gutter")
    func twoInARow() throws {
        let r = try rects(
            [TileSize(width: 300, height: 200), TileSize(width: 400, height: 250)],
            TileSize(width: 2000, height: 1000), gutter: 200)
        #expect(r[0] == TileRect(x: 0, y: 0, width: 300, height: 200))
        // Second window starts one gutter past the first's right edge (300 + 200).
        #expect(r[1] == TileRect(x: 500, y: 0, width: 400, height: 250))
    }

    @Test("a window that would overflow the row width wraps to a new shelf")
    func wrapToNewRow() throws {
        // Display 1000 wide. Two 400-wide windows fit in row 0 (0..400, 600..1000
        // with gutter 200). The third wraps below the tallest of row 0.
        let r = try rects(
            [
                TileSize(width: 400, height: 300),
                TileSize(width: 400, height: 250),
                TileSize(width: 400, height: 200),
            ],
            TileSize(width: 1000, height: 1000), gutter: 200)
        #expect(r[0] == TileRect(x: 0, y: 0, width: 400, height: 300))
        #expect(r[1] == TileRect(x: 600, y: 0, width: 400, height: 250))
        // Row 0's tallest is 300; next shelf starts at 300 + gutter 200 = 500.
        #expect(r[2] == TileRect(x: 0, y: 500, width: 400, height: 200))
    }

    @Test("a window exactly display-width fills its row; the next one wraps")
    func fullWidthWindow() throws {
        let r = try rects(
            [TileSize(width: 1000, height: 300), TileSize(width: 200, height: 200)],
            TileSize(width: 1000, height: 1000), gutter: 100)
        #expect(r[0] == TileRect(x: 0, y: 0, width: 1000, height: 300))
        #expect(r[1] == TileRect(x: 0, y: 400, width: 200, height: 200))
    }

    // MARK: can't-fit

    @Test("a window wider than the display cannot fit")
    func tooWide() {
        let d = TileSize(width: 1000, height: 1000)
        #expect(
            error([TileSize(width: 1200, height: 100)], d, gutter: 0)
                == .windowLargerThanDisplay(
                    index: 0, size: TileSize(width: 1200, height: 100), display: d))
    }

    @Test("a window taller than the display cannot fit")
    func tooTall() {
        let d = TileSize(width: 1000, height: 1000)
        #expect(
            error([TileSize(width: 100, height: 1200)], d, gutter: 0)
                == .windowLargerThanDisplay(
                    index: 0, size: TileSize(width: 100, height: 1200), display: d))
    }

    @Test("running out of vertical room is an error, never an overlap (I-5)")
    func noVerticalRoom() {
        // Row 0: an 800-tall window. Gutter 200 pushes the next shelf to y=1000,
        // which is the display height, so a second window has zero room.
        let d = TileSize(width: 1000, height: 1000)
        let windows = [
            TileSize(width: 600, height: 800),
            TileSize(width: 600, height: 800),  // forced to wrap: 600+200+600 > 1000
        ]
        #expect(
            error(windows, d, gutter: 200)
                == .noVerticalRoom(index: 1, size: TileSize(width: 600, height: 800), display: d))
    }

    // MARK: properties

    @Test("a produced layout never overlaps and respects the gutter")
    func nonOverlapProperty() throws {
        let windows = [
            TileSize(width: 300, height: 220),
            TileSize(width: 250, height: 300),
            TileSize(width: 400, height: 180),
            TileSize(width: 500, height: 260),
            TileSize(width: 200, height: 200),
        ]
        let gutter = 200
        let r = try rects(windows, TileSize(width: 1200, height: 1600), gutter: gutter)
        #expect(r.count == windows.count)
        for i in 0..<r.count {
            // Sizes are preserved (the tiler positions, it does not resize).
            #expect(r[i].width == windows[i].width)
            #expect(r[i].height == windows[i].height)
            for j in (i + 1)..<r.count {
                #expect(!r[i].intersects(r[j]), "tiles \(i) and \(j) overlap")
                // Any two tiles are separated by at least a gutter on some axis.
                let gapX = max(r[j].x - r[i].maxX, r[i].x - r[j].maxX)
                let gapY = max(r[j].y - r[i].maxY, r[i].y - r[j].maxY)
                #expect(gapX >= gutter || gapY >= gutter, "tiles \(i),\(j) closer than a gutter")
            }
        }
    }

    @Test("zero gutter packs tightly but still never overlaps")
    func zeroGutterTouchesButNoOverlap() throws {
        let r = try rects(
            [TileSize(width: 500, height: 300), TileSize(width: 500, height: 300)],
            TileSize(width: 1000, height: 1000), gutter: 0)
        #expect(r[0] == TileRect(x: 0, y: 0, width: 500, height: 300))
        #expect(r[1] == TileRect(x: 500, y: 0, width: 500, height: 300))
        // Edge-touching is not an overlap.
        #expect(!r[0].intersects(r[1]))
    }
}
