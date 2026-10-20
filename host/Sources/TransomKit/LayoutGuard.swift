/// Decides when the host must re-tile because the windows on the virtual display
/// have stopped satisfying I-5.
///
/// The tiler lays windows out when sharing starts and when a window opens, and
/// `ResizeClamp` keeps a client resize from growing one window into another.
/// Neither covers a change made on the Mac side: a streamed drag of a title bar
/// or resize edge, a zoom, an app resizing itself. Those can leave a window on
/// top of a neighbour or partly off the display, and then its crop shows another
/// window's pixels and a hover lands on whichever window is in front.
///
/// The guard is polled with the live rects of the standard windows. It asks for a
/// re-tile only once a violating layout has **settled** (identical on two
/// consecutive polls, with no mouse button held), so it never fights a drag or an
/// animation in progress. It gives up on a layout a re-tile could not repair.
///
/// Pure, so it is unit tested with no Mac (`Tests/TransomKitTests/LayoutGuardTests`).
/// `TileService.enforceNonOverlap` is the impure half.
public struct LayoutGuard: Sendable {

    /// Failed re-tiles in a row before the guard stops trying. A restore after a
    /// failed re-tile is itself an AX write an app may round, so "the same layout"
    /// is not a reliable enough reason to stop on its own.
    static let maxFailures = 3

    private var pending: [TileRect]?
    private var unrepairable: [TileRect]?
    private var failures = 0

    public init() {}

    /// One poll. `windows` are the live VDS rects of the standard windows; returns
    /// true when the host should re-tile now.
    public mutating func shouldRetile(windows: [TileRect], display: TileSize, pointerDown: Bool)
        -> Bool
    {
        guard !Tiler.isNonOverlapping(windows, on: display) else {
            pending = nil
            unrepairable = nil
            failures = 0
            return false
        }
        let layout = Self.canonical(windows)
        guard !pointerDown, failures < Self.maxFailures, layout != unrepairable else {
            pending = nil
            return false
        }
        guard layout == pending else {
            pending = layout
            return false
        }
        pending = nil
        return true
    }

    /// The re-tile `shouldRetile` asked for did not produce a valid layout, and
    /// left the windows at `windows`. Leave that layout alone until it changes.
    public mutating func retileFailed(windows: [TileRect]) {
        unrepairable = Self.canonical(windows)
        failures += 1
    }

    /// AX lists windows front to back, so the order changes with focus.
    private static func canonical(_ windows: [TileRect]) -> [TileRect] {
        windows.sorted { ($0.x, $0.y, $0.width, $0.height) < ($1.x, $1.y, $1.width, $1.height) }
    }
}
