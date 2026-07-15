/// The tiler: a **pure function** that packs window sizes onto a display
/// non-overlapping, with gutters (issue #3 Phase 1, invariant I-5).
///
/// This file deliberately has **no dependency on AX, ScreenCaptureKit, or any
/// Mac API**. It is integer geometry and nothing else, which is exactly why it
/// can — and must — be unit tested (the issue: "It needs no Mac and no AX to
/// test, so there is no excuse for it to be untested"). The command layer reads
/// real window sizes from AX, converts them to VDS pixels (I-3), calls this, then
/// writes the result back through AX and reads back the *actual* geometry (I-4).
///
/// All coordinates here are **VDS pixels**: origin top-left of the virtual
/// display, Y **down** (I-3). Integers, because pixels are integers.

/// A window's size in VDS pixels, as handed to the tiler.
public struct TileSize: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// A placed tile in VDS pixels. Origin top-left, Y down.
public struct TileRect: Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }

    /// True if this rect and `other` share any interior area. Edge-touching
    /// (shared boundary, zero overlap area) is **not** an overlap.
    public func intersects(_ other: TileRect) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }
}

/// Why a layout could not be produced. Every case names the offending window and
/// the sizes involved, because a failed tile is data the host must surface (I-4,
/// I-5), not a warning to swallow.
public enum TilerError: Error, Equatable, CustomStringConvertible {
    /// No windows were given.
    case noWindows
    /// Gutter must be non-negative.
    case negativeGutter(Int)
    /// A window reported a non-positive size; the caller should have filtered it.
    case nonPositiveSize(index: Int, size: TileSize)
    /// A single window is larger than the whole display in at least one axis, so
    /// it can never be placed. The tiling budget is exceeded (architecture.md 3.3).
    case windowLargerThanDisplay(index: Int, size: TileSize, display: TileSize)
    /// The window fits by itself but there is no vertical room left after packing
    /// the ones before it. Non-overlap (I-5) forbids stacking, so this is an error.
    case noVerticalRoom(index: Int, size: TileSize, display: TileSize)

    public var description: String {
        switch self {
        case .noWindows:
            return "no windows to tile"
        case .negativeGutter(let g):
            return "gutter must be >= 0, got \(g)"
        case .nonPositiveSize(let i, let s):
            return "window[\(i)] has a non-positive size \(s.width)x\(s.height)"
        case .windowLargerThanDisplay(let i, let s, let d):
            return
                "window[\(i)] \(s.width)x\(s.height) is larger than the display "
                + "\(d.width)x\(d.height) — cannot fit (I-5); tiling budget exceeded"
        case .noVerticalRoom(let i, let s, let d):
            return
                "window[\(i)] \(s.width)x\(s.height) has no vertical room left on the "
                + "\(d.width)x\(d.height) display without overlapping (I-5)"
        }
    }
}

public enum Tiler {

    /// Default gutter in VDS pixels between tiles.
    ///
    /// A completion popup or dropdown near a window edge can overhang past its
    /// parent's rect; on a tiled display that overhang would land on a neighbour's
    /// tile and corrupt that neighbour's crop. Dead space between tiles catches
    /// the overhang so it hurts nothing. This costs a constant in the tiling
    /// budget (architecture.md 3.3). ~200px per the settled decision in issue #3.
    public static let defaultGutter = 200

    /// Pack `windows` onto a `display` non-overlapping, leaving `gutter` pixels of
    /// dead space between tiles. Returns the placed rects **in input order**
    /// (`result[i]` is the placement of `windows[i]`), or a typed error naming the
    /// window that could not be placed.
    ///
    /// Algorithm: a shelf packer. Fill a row left to right; when the next window
    /// would run past the right edge, wrap to a new shelf below the tallest window
    /// in the current row, plus one gutter. Simple and predictable; it preserves
    /// input order so the caller can map rects back to windows by index. It does
    /// not reorder or resize — Phase 1 tiles windows at their current size.
    ///
    /// Non-overlap is guaranteed by construction: within a row each window starts
    /// one gutter past the previous window's right edge, and each row starts one
    /// gutter below the previous row's tallest window.
    public static func layout(
        windows: [TileSize],
        display: TileSize,
        gutter: Int
    ) -> Result<[TileRect], TilerError> {
        guard gutter >= 0 else { return .failure(.negativeGutter(gutter)) }
        guard !windows.isEmpty else { return .failure(.noWindows) }

        var rects: [TileRect] = []
        rects.reserveCapacity(windows.count)

        // Cursor is the top-left of the next tile. `rowHeight` is the tallest
        // window placed in the current shelf so far.
        var cursorX = 0
        var cursorY = 0
        var rowHeight = 0

        for (index, win) in windows.enumerated() {
            guard win.width > 0, win.height > 0 else {
                return .failure(.nonPositiveSize(index: index, size: win))
            }
            guard win.width <= display.width, win.height <= display.height else {
                return .failure(
                    .windowLargerThanDisplay(index: index, size: win, display: display))
            }

            // Wrap to a new shelf if this window would run off the right edge.
            // (A window exactly as wide as the display fills its row and the next
            // one wraps.)
            if cursorX + win.width > display.width {
                cursorX = 0
                cursorY += rowHeight + gutter
                rowHeight = 0
            }

            guard cursorY + win.height <= display.height else {
                return .failure(.noVerticalRoom(index: index, size: win, display: display))
            }

            rects.append(
                TileRect(x: cursorX, y: cursorY, width: win.width, height: win.height))
            cursorX += win.width + gutter
            rowHeight = max(rowHeight, win.height)
        }

        return .success(rects)
    }
}
