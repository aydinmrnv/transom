import ApplicationServices
import ArgumentParser
import CoreGraphics
import Foundation
import TransomKit

/// `tile <app> <display>` — pack an app's windows non-overlapping on a display,
/// with gutters, and report the **actual** post-write geometry and the deltas.
///
/// The layout itself is decided by the pure `Tiler` (unit-tested, no Mac needed).
/// This command is the impure half: it reads real window sizes from AX, hands
/// them to the tiler in **VDS pixels** (I-3), writes each result back through AX,
/// and — crucially — **reads back** and reports what macOS actually did, never
/// the requested geometry (I-4). AX may clamp or refuse (OQ-2), so the layout is
/// re-checked for non-overlap on the *actual* rects, because I-5 is about what
/// really happened, not what we intended.
struct Tile: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tile",
        abstract:
            "Tile an app's windows non-overlapping (with gutters) on a display; report actual geometry."
    )

    @Argument(help: "Target app: a name like \"Xcode\" or a bundle id.")
    var app: String

    @Argument(help: "Display id, as printed by `displays`.")
    var display: UInt32

    @Option(
        name: .long,
        help: "Gutter in VDS pixels between tiles (popup/dropdown overhang budget, I-5).")
    var gutter: Int = Tiler.defaultGutter

    func run() throws {
        guard AXIsProcessTrusted() else {
            throw ProbeError(
                "Accessibility is not granted. Run `transom-host doctor` for guidance.")
        }

        let target: TargetApp
        switch AppResolver.resolve(app) {
        case .success(let t): target = t
        case .failure(let e): throw e
        }
        guard let disp = TransomKit.Displays.byID(display) else {
            throw ProbeError("no active display with id \(display). See `displays`.")
        }

        // Collect the windows AX can actually size, and convert each current size
        // (AX points) into VDS pixels for the tiler (I-3). Only real windows
        // (role AXWindow) are tiled: apps expose other elements in their window
        // list — Finder's desktop is an `AXScrollArea` sized to the whole display —
        // and those are not movable windows the client should get a tile for.
        var placeable: [(win: AXWindow, sizePoints: CGSize, sizePixels: TileSize)] = []
        for win in AXWindow.windows(pid: target.pid) {
            guard win.role == (kAXWindowRole as String) else {
                print(
                    "  window[\(win.index)] \"\(win.title)\": role \(win.role) is not a window, skipping"
                )
                continue
            }
            guard let s = win.size() else {
                print("  window[\(win.index)] \"\(win.title)\": AX reports no size, skipping")
                continue
            }
            let px = TileSize(
                width: Int(
                    Coordinates.vdsPixels(fromAXPoints: s.width, scale: disp.scale).rounded()),
                height: Int(
                    Coordinates.vdsPixels(fromAXPoints: s.height, scale: disp.scale).rounded()))
            placeable.append((win, s, px))
        }

        print(
            "tile: \(target.name) on display \(display) "
                + "(\(disp.pixelWidth)x\(disp.pixelHeight) px, scale \(disp.scale)), gutter=\(gutter)px"
        )
        print(String(repeating: "-", count: 72))

        guard !placeable.isEmpty else {
            throw ProbeError("\(target.name) has no AX-sizable windows to tile.")
        }

        // The pure tiler decides the layout in VDS pixels.
        let displaySize = TileSize(width: disp.pixelWidth, height: disp.pixelHeight)
        let layout: [TileRect]
        switch Tiler.layout(
            windows: placeable.map(\.sizePixels), display: displaySize, gutter: gutter)
        {
        case .success(let rects):
            layout = rects
        case .failure(let err):
            // A failed tile is data, surfaced verbatim (I-4/I-5), not swallowed.
            print("  LAYOUT FAILED: \(err)")
            print("  -> tiling budget exceeded for this window set (architecture.md 3.3)")
            Log.general.error(
                "tile \(target.name, privacy: .public) layout failed: \(err.description, privacy: .public)"
            )
            throw ExitCode.failure
        }

        // Apply each placement via AX and read back the ACTUAL geometry (I-4).
        // We set position from the tiler and keep the window's own size, so tiling
        // repositions without resizing (resize is Phase 4).
        var actualRects: [(idx: Int, title: String, rect: TileRect?)] = []
        for (placement, requested) in zip(placeable, layout) {
            let axRect = Coordinates.axGlobalRect(
                fromDisplayPixels: CGRect(
                    x: CGFloat(requested.x), y: CGFloat(requested.y),
                    width: CGFloat(requested.width), height: CGFloat(requested.height)),
                displayOriginPoints: disp.originPoints,
                scale: disp.scale)
            let result = placement.win.place(position: axRect.origin, size: placement.sizePoints)

            let actual: TileRect? = actualVDSRect(from: result, disp: disp)
            actualRects.append((placement.win.index, placement.win.title, actual))
            report(
                index: placement.win.index, title: placement.win.title,
                requested: requested, actual: actual)
        }

        // Re-verify the ACTUAL rects (post-clamp) do not overlap — I-5 is about
        // what really happened, not what we asked for.
        var overlaps = false
        for a in 0..<actualRects.count {
            for b in (a + 1)..<actualRects.count {
                guard let ra = actualRects[a].rect, let rb = actualRects[b].rect else { continue }
                if ra.intersects(rb) {
                    overlaps = true
                    print(
                        "  OVERLAP after readback: window[\(actualRects[a].idx)] "
                            + "and window[\(actualRects[b].idx)] intersect")
                }
            }
        }

        print(String(repeating: "-", count: 72))
        print("  windows tiled: \(actualRects.count)")
        print("  actual rects non-overlapping (I-5): \(overlaps ? "NO — see above" : "YES")")

        Log.general.notice(
            "tile \(target.name, privacy: .public) count=\(actualRects.count) overlap=\(overlaps, privacy: .public)"
        )

        if overlaps { throw ExitCode.failure }
    }

    /// Convert a placement's AX read-back (global points) into a VDS-pixel rect
    /// through the one named boundary conversion (I-3). `nil` if AX refused to
    /// report the geometry back.
    private func actualVDSRect(from result: PlacementResult, disp: DisplayInfo) -> TileRect? {
        guard let p = result.actualPosition, let s = result.actualSize else { return nil }
        let vds = Coordinates.displayPixels(
            fromAXRect: CGRect(origin: p, size: s),
            displayOriginPoints: disp.originPoints,
            scale: disp.scale)
        return TileRect(
            x: Int(vds.origin.x.rounded()), y: Int(vds.origin.y.rounded()),
            width: Int(vds.size.width.rounded()), height: Int(vds.size.height.rounded()))
    }

    /// Print requested-vs-actual in VDS pixels with the delta. The delta is the
    /// entire point (I-4, OQ-2): "requested 2560x1440, got 2560x1438".
    private func report(index: Int, title: String, requested: TileRect, actual: TileRect?) {
        print("  window[\(index)] \"\(title)\"")
        print(
            "    requested (VDS px): (\(requested.x),\(requested.y)) \(requested.width)x\(requested.height)"
        )
        guard let actual else {
            print("    actual    (VDS px): (AX would not report back)")
            return
        }
        let dx = actual.x - requested.x
        let dy = actual.y - requested.y
        let dw = actual.width - requested.width
        let dh = actual.height - requested.height
        let exact = dx == 0 && dy == 0 && dw == 0 && dh == 0
        print(
            "    actual    (VDS px): (\(actual.x),\(actual.y)) \(actual.width)x\(actual.height)"
                + (exact ? "  [exact]" : "  [Δ pos (\(dx),\(dy))  Δ size (\(dw),\(dh))]"))
    }
}
