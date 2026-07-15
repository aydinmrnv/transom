/// The non-overlap clamp for a live resize (issue #6 Phase 4, invariant I-5).
///
/// This is the answer to the "re-tile question" in the issue — see
/// `docs/architecture.md` §2.2 and the decision log. When a resize would grow a
/// window into a neighbour, the host does **not** re-tile the others (jarring, they
/// move for no visible reason) and does **not** grow the display (invalidates the
/// capture stream). It **clamps the growth** at the collision and reports the
/// clamped size back through the normal readback path (I-4) — reusing the exact
/// machinery the host already has for app-level clamping (OQ-2), which the client
/// already tolerates.
///
/// Pure integer geometry in **VDS pixels**, no AX and no Mac, so it is unit tested
/// (`Tests/TransomKitTests/ResizeClampTests`). The `ResizeService` calls it just
/// before the AX write; macOS may then clamp further to an app minimum, and the
/// read-back is re-verified for overlap by the caller.
public enum ResizeClamp {

    /// The largest size ≤ `desired` that keeps a window anchored at its current
    /// top-left non-overlapping and on-display.
    ///
    /// A window resizes from its top-left, so it only ever grows right and down;
    /// only neighbours to the right or below can block it (left/above never do).
    /// The tiler lays windows out in shelves, so in practice a blocker is either
    /// the next window in the row (right) or the next shelf (below). Growth stops
    /// one `gutter` short of any blocker, preserving the popup-overhang budget
    /// (architecture.md 3.3), and at the display edge.
    ///
    /// At **N=1** (the real primary case — a single Conductor window) `others` is
    /// empty and this reduces to a display-edge clamp, which is exactly right.
    ///
    /// - Parameters:
    ///   - current: the window's current rect (VDS px); its origin is the anchor.
    ///   - desired: the requested new size (VDS px).
    ///   - others: every other live window's current rect (VDS px).
    ///   - display: the virtual display size (VDS px).
    ///   - gutter: dead-space budget to keep between tiles (VDS px).
    public static func clamp(
        current: TileRect,
        desired: TileSize,
        others: [TileRect],
        display: TileSize,
        gutter: Int
    ) -> TileSize {
        // Never propose a non-positive size; the window keeps at least 1px.
        let wantW = max(1, desired.width)
        let wantH = max(1, desired.height)

        // Start from the display edges, measured from the fixed top-left anchor.
        var maxW = max(1, display.width - current.x)
        var maxH = max(1, display.height - current.y)

        for other in others {
            // Would the grown window share this neighbour's vertical band? Use the
            // desired height so a window growing both ways still sees a right
            // neighbour it would collide with.
            let sharesRows = current.y < other.maxY && other.y < current.y + wantH
            if other.x >= current.maxX && sharesRows {
                // Neighbour to the right: cap width a gutter short of its left edge.
                maxW = min(maxW, max(1, other.x - gutter - current.x))
            }

            let sharesCols = current.x < other.maxX && other.x < current.x + wantW
            if other.y >= current.maxY && sharesCols {
                // Neighbour below: cap height a gutter short of its top edge.
                maxH = min(maxH, max(1, other.y - gutter - current.y))
            }
        }

        return TileSize(width: min(wantW, maxW), height: min(wantH, maxH))
    }
}
