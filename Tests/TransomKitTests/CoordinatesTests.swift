import CoreGraphics
import Testing

@testable import TransomKit

/// Unit tests for the one place a scale factor is allowed to touch a coordinate
/// (I-3). These are the conversions that, if wrong, produce the vertically
/// mirrored / misaligned bugs the invariants warn about — pure, so tested here.
@Suite("Coordinates")
struct CoordinatesTests {

    private let epsilon = 1e-9

    @Test("vdsPixels is points * scale")
    func vdsPixelsScales() {
        #expect(Coordinates.vdsPixels(fromAXPoints: 100, scale: 2.0) == 200)
        #expect(Coordinates.vdsPixels(fromAXPoints: 100, scale: 1.0) == 100)
        #expect(Coordinates.vdsPixels(fromAXPoints: 0, scale: 2.0) == 0)
    }

    @Test("axPoints is the exact inverse of vdsPixels (a resize size crossing back)")
    func axPointsIsInverseOfVdsPixels() {
        // A RequestResize arrives in physical pixels; AX takes points. 1280px at
        // 2x is 640pt going in, and the pair round-trips exactly.
        #expect(Coordinates.axPoints(fromVDSPixels: 1280, scale: 2.0) == 640)
        #expect(Coordinates.axPoints(fromVDSPixels: 100, scale: 1.0) == 100)
        let px = 1337.0
        #expect(Coordinates.vdsPixels(fromAXPoints: Coordinates.axPoints(fromVDSPixels: px, scale: 2.0), scale: 2.0) == px)
    }

    @Test("on the main display (origin 0,0) AX points scale straight to pixels")
    func mainDisplayScale() {
        // The exact numbers from the M0 OQ-1 finding: File menu (99,31) 337x629 pt
        // at 2x reads back as 674x1258 px. This is that conversion.
        let axRect = CGRect(x: 99, y: 31, width: 337, height: 629)
        let px = Coordinates.displayPixels(
            fromAXRect: axRect, displayOriginPoints: .zero, scale: 2.0)
        #expect(px.origin.x == 198)
        #expect(px.origin.y == 62)
        #expect(px.size.width == 674)
        #expect(px.size.height == 1258)
    }

    @Test("a non-main display translates by its origin before scaling")
    func nonMainDisplayTranslates() {
        // Display origin at (100, 50) points; a window at global (150, 80) pt.
        // Local points: (50, 30). At scale 2 → pixels (100, 60).
        let axRect = CGRect(x: 150, y: 80, width: 200, height: 100)
        let px = Coordinates.displayPixels(
            fromAXRect: axRect, displayOriginPoints: CGPoint(x: 100, y: 50), scale: 2.0)
        #expect(px.origin.x == 100)
        #expect(px.origin.y == 60)
        #expect(px.size.width == 400)
        #expect(px.size.height == 200)
    }

    @Test("axGlobalRect is the exact inverse of displayPixels")
    func inverseRoundTrips() {
        let origin = CGPoint(x: 100, y: 50)
        let scale = 2.0
        // Start from a VDS pixel rect, go to AX points, and back.
        let vds = CGRect(x: 100, y: 60, width: 674, height: 1258)
        let ax = Coordinates.axGlobalRect(
            fromDisplayPixels: vds, displayOriginPoints: origin, scale: scale)
        let back = Coordinates.displayPixels(
            fromAXRect: ax, displayOriginPoints: origin, scale: scale)
        #expect(abs(back.origin.x - vds.origin.x) < epsilon)
        #expect(abs(back.origin.y - vds.origin.y) < epsilon)
        #expect(abs(back.size.width - vds.size.width) < epsilon)
        #expect(abs(back.size.height - vds.size.height) < epsilon)
    }

    @Test("axGlobalRect divides by scale and offsets by the display origin")
    func axGlobalRectConcrete() {
        // VDS pixel rect (200,100) 400x300 on a 2x display at origin (0,0):
        // AX points = (100,50) 200x150.
        let vds = CGRect(x: 200, y: 100, width: 400, height: 300)
        let ax = Coordinates.axGlobalRect(
            fromDisplayPixels: vds, displayOriginPoints: .zero, scale: 2.0)
        #expect(ax.origin.x == 100)
        #expect(ax.origin.y == 50)
        #expect(ax.size.width == 200)
        #expect(ax.size.height == 150)
    }

    // MARK: - Input: window-local pixels -> AX global point (issue #7)

    @Test("window-local click adds window origin, then divides by scale")
    func windowLocalToAXPoint() {
        // Window at VDS (1512, 60) on a 2x main display (origin 0,0). A click
        // 200px right, 100px down from the window's top-left is VDS (1712, 160),
        // which is AX point (856, 80).
        let ax = Coordinates.axGlobalPoint(
            fromWindowLocalPixels: CGPoint(x: 200, y: 100),
            windowOriginVDS: CGPoint(x: 1512, y: 60),
            displayOriginPoints: .zero,
            scale: 2.0)
        #expect(ax.x == 856)
        #expect(ax.y == 80)
    }

    @Test("the window's top-left maps to the window origin in points")
    func windowLocalOrigin() {
        // Local (0,0) is the window's top-left: VDS == window origin, / scale.
        let ax = Coordinates.axGlobalPoint(
            fromWindowLocalPixels: .zero,
            windowOriginVDS: CGPoint(x: 800, y: 600),
            displayOriginPoints: .zero,
            scale: 2.0)
        #expect(ax.x == 400)
        #expect(ax.y == 300)
    }

    @Test("Y is not flipped: a larger local-y yields a larger AX-y")
    func windowLocalYIsDown() {
        // The vertically-mirrored bug I-3 warns about would make this decrease.
        let top = Coordinates.axGlobalPoint(
            fromWindowLocalPixels: CGPoint(x: 0, y: 0),
            windowOriginVDS: .zero, displayOriginPoints: .zero, scale: 2.0)
        let lower = Coordinates.axGlobalPoint(
            fromWindowLocalPixels: CGPoint(x: 0, y: 1000),
            windowOriginVDS: .zero, displayOriginPoints: .zero, scale: 2.0)
        #expect(lower.y > top.y)
    }

    @Test("a non-main display offsets the click by its point origin")
    func windowLocalNonMainDisplay() {
        // Display origin (100,50) pt; window at VDS (200,100) px on a 2x display;
        // local (40,60) px -> VDS (240,160) px -> (120,80) pt -> +origin (220,130).
        let ax = Coordinates.axGlobalPoint(
            fromWindowLocalPixels: CGPoint(x: 40, y: 60),
            windowOriginVDS: CGPoint(x: 200, y: 100),
            displayOriginPoints: CGPoint(x: 100, y: 50),
            scale: 2.0)
        #expect(ax.x == 220)
        #expect(ax.y == 130)
    }

    @Test("input point is consistent with the rect conversion for the same corner")
    func windowLocalMatchesRectOrigin() {
        // The AX point for a window's local (0,0) must equal the AX origin the
        // rect round-trip produces for that same window rect — the two coordinate
        // paths cannot disagree about where a window's top-left is.
        let windowVDS = CGRect(x: 640, y: 200, width: 1280, height: 800)
        let axRect = Coordinates.axGlobalRect(
            fromDisplayPixels: windowVDS, displayOriginPoints: .zero, scale: 2.0)
        let axPoint = Coordinates.axGlobalPoint(
            fromWindowLocalPixels: .zero,
            windowOriginVDS: windowVDS.origin, displayOriginPoints: .zero, scale: 2.0)
        #expect(axPoint.x == axRect.origin.x)
        #expect(axPoint.y == axRect.origin.y)
    }
}
