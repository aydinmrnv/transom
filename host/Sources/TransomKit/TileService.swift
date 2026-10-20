import ApplicationServices
import CoreGraphics
import Foundation

/// One tiled window's requested-vs-actual geometry, all in **VDS pixels** (I-3).
///
/// The tiler *requested* `requested`; AX may clamp, round, or refuse (OQ-2), so
/// `actual` is the post-write read-back (I-4) — `nil` if AX would not report it.
/// The delta between the two is the entire point the `tile` command and the host
/// app both surface, because clamping is real and per-app (OQ-2).
public struct TilePlacement: Sendable, Equatable {
    public let index: Int
    public let title: String
    public let requested: TileRect
    public let actual: TileRect?

    public init(index: Int, title: String, requested: TileRect, actual: TileRect?) {
        self.index = index
        self.title = title
        self.requested = requested
        self.actual = actual
    }

    /// True only when AX read the tile back at exactly the requested rect.
    public var isExact: Bool { actual.map { $0 == requested } ?? false }

    /// Position delta (actual − requested) in VDS pixels, or nil if AX refused.
    public var positionDelta: (dx: Int, dy: Int)? {
        guard let a = actual else { return nil }
        return (a.x - requested.x, a.y - requested.y)
    }

    /// Size delta (actual − requested) in VDS pixels, or nil if AX refused.
    public var sizeDelta: (dw: Int, dh: Int)? {
        guard let a = actual else { return nil }
        return (a.width - requested.width, a.height - requested.height)
    }
}

/// Drives the pure `Tiler` against a live app through AX: read window sizes,
/// compute a layout, write positions, and read the actual result back (I-4).
/// Shared by the `tile` command (which additionally reports deltas), the `serve`
/// command, and the host app's `HostSession` (which surfaces the placements in
/// its Status view) — the impure tiling path lives here exactly once.
public enum TileService {

    /// Tile every `AXWindow`-role window of `pid` on `display` with `gutter`
    /// pixels between tiles, then read each result back. Returns one
    /// `TilePlacement` per placed window (requested + actual VDS rects), or the
    /// tiler's typed error if the set does not fit. An app with no sizable windows
    /// yields `.success([])`.
    public static func layout(pid: pid_t, display: DisplayInfo, gutter: Int)
        -> Result<[TilePlacement], TilerError>
    {
        layout(pids: [pid], display: display, gutter: gutter)
    }

    /// One global layout across the selected apps, never overlapping per-app layouts.
    public static func layout(pids: [pid_t], display: DisplayInfo, gutter: Int, fit: Bool = false)
        -> Result<[TilePlacement], TilerError>
    {
        let items = placeable(pids: pids, display: display)
        guard !items.isEmpty else { return .success([]) }
        var minimums = [TileSize?](repeating: nil, count: items.count)
        let result = place(items, display: display, gutter: gutter, fit: fit, minimums: &minimums)
        if case .failure = result { restore(items) }
        return result
    }

    /// The windows the session start shares, and those it could not fit.
    public struct Admission {
        public let placements: [TilePlacement]
        /// Windows left out so the rest stay non-overlapping (I-5), least
        /// important first: an app's back windows go before any app's front one.
        public let overflow: [AXWindow]
    }

    /// Lay out as many of `pids`' windows as fit, instead of refusing them all.
    ///
    /// Every app's frontmost window is placed before any app's second window, so
    /// sharing Xcode with a stack of documents open still shares Device Hub. A
    /// window its app will not shrink far enough (OQ-2) is retried at the size it
    /// clamped to, then dropped. The caller must keep the overflow off the display.
    public static func admit(pids: [pid_t], display: DisplayInfo, gutter: Int)
        -> Result<Admission, TilerError>
    {
        let unordered = placeable(pids: pids, display: display)
        guard !unordered.isEmpty else { return .success(Admission(placements: [], overflow: [])) }
        let items = Tiler.priorityOrder(ranks: unordered.map(\.rank)).map { unordered[$0] }
        let displaySize = TileSize(width: display.pixelWidth, height: display.pixelHeight)
        var minimums = [TileSize?](repeating: nil, count: items.count)
        var limit = items.count
        while limit > 0 {
            let count = Tiler.admittedCount(
                windows: items.prefix(limit).map(\.sizePixels), minimums: Array(minimums.prefix(limit)),
                display: displaySize, gutter: gutter)
            guard count > 0 else { break }
            var learned = Array(minimums.prefix(count))
            let result = place(
                Array(items.prefix(count)), display: display, gutter: gutter, fit: true,
                minimums: &learned)
            minimums.replaceSubrange(0..<count, with: learned)
            if case .success(let placements) = result {
                return .success(
                    Admission(placements: placements, overflow: items.dropFirst(count).map(\.win)))
            }
            limit = count - 1
        }
        restore(items)
        return .failure(.actualGeometryRejected)
    }

    private struct Placeable {
        let win: AXWindow
        let sizePixels: TileSize
        let originalFrame: CGRect?
        /// Position in its own app's AX window list, front to back.
        let rank: Int
    }

    /// The windows of `pids` that are on the display and can be laid out. A
    /// hidden app, a minimized window and a full-screen one are not drawn on
    /// the sharing display, so they get no tile (`WindowRestorer` brings them
    /// back at session start).
    private static func placeable(pids: [pid_t], display: DisplayInfo) -> [Placeable] {
        var items: [Placeable] = []
        for pid in pids where !AXWindow.isApplicationHidden(pid: pid) {
            var rank = 0
            for win in AXWindow.windows(pid: pid) where win.role == (kAXWindowRole as String) {
                guard !win.isMinimized, !win.isFullScreen, let frame = win.frame() else { continue }
                let px = TileSize(
                    width: Int(
                        Coordinates.vdsPixels(fromAXPoints: frame.width, scale: display.scale)
                            .rounded()),
                    height: Int(
                        Coordinates.vdsPixels(fromAXPoints: frame.height, scale: display.scale)
                            .rounded()))
                items.append(Placeable(win: win, sizePixels: px, originalFrame: frame, rank: rank))
                rank += 1
            }
        }
        return items
    }

    /// Write a layout for `items` and accept it only if AX's read-back is a valid
    /// non-overlapping layout (I-4, I-5). A window that came back larger than
    /// asked has hit its app's minimum size; remember that size in `minimums` and
    /// lay out again around it, a few times at most.
    private static func place(
        _ items: [Placeable], display: DisplayInfo, gutter: Int, fit: Bool,
        minimums: inout [TileSize?]
    ) -> Result<[TilePlacement], TilerError> {
        let displaySize = TileSize(width: display.pixelWidth, height: display.pixelHeight)
        let sizes = items.map(\.sizePixels)
        for _ in 0..<3 {
            let result = fit
                ? Tiler.fittedLayout(windows: sizes, minimums: minimums, display: displaySize, gutter: gutter)
                : Tiler.layout(windows: sizes, display: displaySize, gutter: gutter)
            let rects: [TileRect]
            switch result {
            case .success(let r): rects = r
            case .failure(let error): return .failure(error)
            }
            var placements: [TilePlacement] = []
            placements.reserveCapacity(items.count)
            for (index, pair) in zip(items, rects).enumerated() {
                let (item, rect) = pair
                let axRect = Coordinates.axGlobalRect(
                    fromDisplayPixels: CGRect(
                        x: CGFloat(rect.x), y: CGFloat(rect.y),
                        width: CGFloat(rect.width), height: CGFloat(rect.height)),
                    displayOriginPoints: display.originPoints,
                    scale: display.scale)
                let readback = item.win.place(position: axRect.origin, size: axRect.size)
                placements.append(
                    TilePlacement(
                        index: index,
                        title: item.win.title,
                        requested: rect,
                        actual: Self.actualVDSRect(from: readback, display: display)))
            }
            // A Mac app can refuse a move or enforce a larger minimum. Never
            // announce an overlapping sprite sheet as a successful session.
            let actual = placements.compactMap(\.actual)
            if actual.count == placements.count && Tiler.isNonOverlapping(actual, on: displaySize) {
                return .success(placements)
            }
            var learnedAny = false
            for (i, placement) in placements.enumerated() {
                guard let a = placement.actual,
                    a.width > placement.requested.width || a.height > placement.requested.height
                else { continue }
                let previous = minimums[i]
                let minimum = TileSize(
                    width: max(a.width, previous?.width ?? 0),
                    height: max(a.height, previous?.height ?? 0))
                if minimum != previous {
                    minimums[i] = minimum
                    learnedAny = true
                }
            }
            guard fit, learnedAny else { break }
            Log.ax.notice("tile: an app clamped to its minimum size; laying out again around it")
        }
        return .failure(.actualGeometryRejected)
    }

    /// Put windows back where they were before a rejected layout.
    private static func restore(_ items: [Placeable]) {
        for item in items {
            if let frame = item.originalFrame {
                _ = item.win.place(position: frame.origin, size: frame.size)
            }
        }
    }

    /// Poll `layoutGuard` with the live layout and re-tile if it asks (I-5). Returns
    /// the re-tile's outcome, or nil when none was due. This is the one case where
    /// the host moves windows on its own initiative (I-4); the watcher reports the
    /// new rects.
    public static func enforceNonOverlap(
        _ layoutGuard: inout LayoutGuard, pids: [pid_t], display: DisplayInfo, gutter: Int,
        pointerDown: Bool
    ) -> Result<[TilePlacement], TilerError>? {
        let displaySize = TileSize(width: display.pixelWidth, height: display.pixelHeight)
        let due = layoutGuard.shouldRetile(
            windows: standardWindowRects(pids: pids, display: display), display: displaySize,
            pointerDown: pointerDown)
        guard due else { return nil }
        let result = layout(pids: pids, display: display, gutter: gutter, fit: true)
        if case .failure = result {
            layoutGuard.retileFailed(windows: standardWindowRects(pids: pids, display: display))
        }
        return result
    }

    /// The live VDS rect of every app window of `pids` (`AXWindow.isAppWindow`):
    /// the set I-5 is enforced over. Alerts, panels and popups are placed by their
    /// app, usually over their parent, and are not a reason to re-tile (OQ-1).
    private static func standardWindowRects(pids: [pid_t], display: DisplayInfo) -> [TileRect] {
        pids.filter { !AXWindow.isApplicationHidden(pid: $0) }.flatMap { AXWindow.windows(pid: $0) }
            .compactMap { win in
            guard win.isAppWindow, !win.isMinimized, !win.isFullScreen, let frame = win.frame()
            else { return nil }
            let vds = Coordinates.displayPixels(
                fromAXRect: frame, displayOriginPoints: display.originPoints, scale: display.scale)
            return TileRect(
                x: Int(vds.origin.x.rounded()), y: Int(vds.origin.y.rounded()),
                width: Int(vds.size.width.rounded()), height: Int(vds.size.height.rounded()))
        }
    }

    /// Tile as `layout(pid:display:gutter:)` does, but discard the per-window
    /// detail and return only the count placed. The thin form `serve` uses when it
    /// tiles once at startup so the streamed windows are non-overlapping (I-5).
    @discardableResult
    public static func tile(pid: pid_t, display: DisplayInfo, gutter: Int)
        -> Result<Int, TilerError>
    {
        layout(pid: pid, display: display, gutter: gutter).map(\.count)
    }

    /// Convert a placement's AX read-back (global points) into a VDS-pixel rect
    /// through the one named boundary conversion (I-3). `nil` if AX refused to
    /// report the geometry back.
    private static func actualVDSRect(from result: PlacementResult, display: DisplayInfo)
        -> TileRect?
    {
        guard let p = result.actualPosition, let s = result.actualSize else { return nil }
        let vds = Coordinates.displayPixels(
            fromAXRect: CGRect(origin: p, size: s),
            displayOriginPoints: display.originPoints,
            scale: display.scale)
        return TileRect(
            x: Int(vds.origin.x.rounded()), y: Int(vds.origin.y.rounded()),
            width: Int(vds.size.width.rounded()), height: Int(vds.size.height.rounded()))
    }
}
