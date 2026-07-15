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
        var placeable: [(win: AXWindow, sizePoints: CGSize, sizePixels: TileSize)] = []
        for win in AXWindow.windows(pid: pid) where win.role == (kAXWindowRole as String) {
            guard let size = win.size() else { continue }
            let px = TileSize(
                width: Int(
                    Coordinates.vdsPixels(fromAXPoints: size.width, scale: display.scale).rounded()),
                height: Int(
                    Coordinates.vdsPixels(fromAXPoints: size.height, scale: display.scale).rounded()
                ))
            placeable.append((win, size, px))
        }
        guard !placeable.isEmpty else { return .success([]) }

        let displaySize = TileSize(width: display.pixelWidth, height: display.pixelHeight)
        switch Tiler.layout(
            windows: placeable.map(\.sizePixels), display: displaySize, gutter: gutter)
        {
        case .failure(let error):
            return .failure(error)
        case .success(let rects):
            var placements: [TilePlacement] = []
            placements.reserveCapacity(placeable.count)
            for (placement, rect) in zip(placeable, rects) {
                let axRect = Coordinates.axGlobalRect(
                    fromDisplayPixels: CGRect(
                        x: CGFloat(rect.x), y: CGFloat(rect.y),
                        width: CGFloat(rect.width), height: CGFloat(rect.height)),
                    displayOriginPoints: display.originPoints,
                    scale: display.scale)
                let result = placement.win.place(
                    position: axRect.origin, size: placement.sizePoints)
                placements.append(
                    TilePlacement(
                        index: placement.win.index,
                        title: placement.win.title,
                        requested: rect,
                        actual: Self.actualVDSRect(from: result, display: display)))
            }
            return .success(placements)
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
