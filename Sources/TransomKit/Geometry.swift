import CoreGraphics

/// Coordinate-space conversions, isolated here per invariant **I-3**.
///
/// Four spaces exist in Transom (see `docs/invariants.md` I-3). This file owns
/// the conversions the host needs, and it is the **only** place a scale factor
/// multiplies a coordinate. If you find that multiplication anywhere else, it is
/// a bug.
///
/// The spaces this host actually touches:
///
/// - **AX** — Accessibility global space. Unit: points. Origin: top-left of the
///   *main* display. Y **down**.
/// - **VDS** — Virtual Display Space, the host's canonical space. Unit: pixels.
///   Origin: top-left of the virtual display. Y **down**. Because the virtual
///   display is the main display, VDS and AX share an origin, so the only
///   conversion is the scale factor.
/// - **SCK** — capture space. Unit: pixels. Origin: top-left of the *captured*
///   display. Y **down**. When we capture a display at native size, SCK == that
///   display's local pixel space.
///
/// **Y is down in all of them.** Cocoa (`NSWindow.frame`, `NSScreen`) is
/// bottom-left, Y up — this host never mixes a Cocoa frame into AX math, which
/// is exactly the vertically-mirrored bug I-3 warns about. There is deliberately
/// no Cocoa conversion in this file.
public enum Coordinates {

    /// Convert an AX rect (points, global, top-left origin) into the pixel space
    /// of a specific display's capture (SCK space for that display).
    ///
    /// Two steps, in order:
    /// 1. Translate from AX global origin (main display top-left) to the target
    ///    display's local origin, in points.
    /// 2. Scale points → pixels by the display's backing scale factor.
    ///
    /// When the target display *is* the main display (the Transom virtual-display
    /// case, I-3), step 1 is a no-op because the origins coincide, and this
    /// reduces to `vds_pixels = ax_points * scale`.
    ///
    /// - Parameters:
    ///   - axRect: rectangle in AX global points.
    ///   - displayOriginPoints: the target display's origin in the AX/global
    ///     point space (`CGDisplayBounds(id).origin`).
    ///   - scale: the target display's backing scale factor (pixels per point).
    public static func displayPixels(
        fromAXRect axRect: CGRect,
        displayOriginPoints: CGPoint,
        scale: Double
    ) -> CGRect {
        let localX = (axRect.origin.x - displayOriginPoints.x) * scale
        let localY = (axRect.origin.y - displayOriginPoints.y) * scale
        return CGRect(
            x: localX,
            y: localY,
            width: axRect.size.width * scale,
            height: axRect.size.height * scale
        )
    }

    /// The pure scale-factor conversion for the canonical case where the target
    /// display is main and VDS/AX origins coincide: `vds_pixels = ax_points * scale`.
    ///
    /// This is the one named conversion I-3 asks for. `displayPixels(fromAXRect:…)`
    /// is its generalisation to non-main displays via an origin translation.
    public static func vdsPixels(fromAXPoints points: Double, scale: Double) -> Double {
        points * scale
    }

    /// The inverse of `displayPixels(fromAXRect:…)`: a display-local pixel rect
    /// (VDS/SCK space) back to an **AX global-point** rect, ready to hand to
    /// `AXUIElementSetAttributeValue`.
    ///
    /// Writing geometry crosses the same AX↔VDS boundary as reading it, just the
    /// other way, so the scale *division* lives here rather than being sprinkled
    /// at call sites — the mirror of the multiplication in `displayPixels`. If you
    /// find a `/ scale` on a coordinate anywhere else, it is a bug (I-2, I-3).
    ///
    /// - Parameters:
    ///   - rect: rectangle in the target display's local pixels (VDS when that
    ///     display is the virtual display).
    ///   - displayOriginPoints: the target display's origin in AX global points
    ///     (`CGDisplayBounds(id).origin`).
    ///   - scale: the target display's backing scale factor (pixels per point).
    public static func axGlobalRect(
        fromDisplayPixels rect: CGRect,
        displayOriginPoints: CGPoint,
        scale: Double
    ) -> CGRect {
        let globalX = displayOriginPoints.x + rect.origin.x / scale
        let globalY = displayOriginPoints.y + rect.origin.y / scale
        return CGRect(
            x: globalX,
            y: globalY,
            width: rect.size.width / scale,
            height: rect.size.height / scale
        )
    }
}
