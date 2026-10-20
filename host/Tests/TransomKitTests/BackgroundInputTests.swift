import CoreGraphics
import Testing

@testable import TransomKit

/// The pure half of background input delivery: which WindowServer window an
/// event is addressed to, the click count it carries, and the one Cocoa-boundary
/// coordinate flip. Posting the events can only be verified on the Mac (I-7).
@Suite("Background input")
struct BackgroundInputTests {

    private let app: pid_t = 100
    private let other: pid_t = 200

    /// Front-to-back, as `CGWindowListCopyWindowInfo` returns it: another app's
    /// window lying on top of the shared one.
    private var covered: [WindowServerWindow] {
        [
            WindowServerWindow(
                id: 9, pid: other, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            WindowServerWindow(
                id: 1, pid: app, layer: 0, bounds: CGRect(x: 100, y: 100, width: 800, height: 600),
                title: "Doc"),
        ]
    }

    // MARK: - Hit-testing the target app's own windows

    @Test("a window of another app on top does not take the click")
    func otherAppOnTopIsIgnored() {
        let hit = WindowServerWindows.topmost(at: CGPoint(x: 300, y: 300), pid: app, in: covered)
        #expect(hit?.id == 1)
    }

    @Test("an open menu of the same app beats the window under it")
    func menuOfSameAppWins() {
        let menu = WindowServerWindow(
            id: 5, pid: app, layer: 101, bounds: CGRect(x: 250, y: 250, width: 150, height: 106))
        let windows = [menu] + covered
        #expect(WindowServerWindows.topmost(at: CGPoint(x: 300, y: 300), pid: app, in: windows)?.id == 5)
        // Outside the menu the shared window still takes it.
        #expect(WindowServerWindows.topmost(at: CGPoint(x: 600, y: 600), pid: app, in: windows)?.id == 1)
    }

    @Test("a fully transparent window never takes the click")
    func transparentWindowIsSkipped() {
        let ghost = WindowServerWindow(
            id: 7, pid: app, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            alpha: 0)
        let hit = WindowServerWindows.topmost(
            at: CGPoint(x: 300, y: 300), pid: app, in: [ghost] + covered)
        #expect(hit?.id == 1)
    }

    @Test("a point outside every window of the app hits nothing")
    func missReturnsNil() {
        #expect(WindowServerWindows.topmost(at: CGPoint(x: 50, y: 50), pid: app, in: covered) == nil)
    }

    // MARK: - AX window → WindowServer window (OQ-3)

    @Test("an AX frame matches the same-pid normal window with that frame")
    func matchByFrame() {
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(WindowServerWindows.match(frame: frame, title: nil, pid: app, in: covered)?.id == 1)
        // The other app's window is never a candidate, whatever its frame.
        let theirs = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(WindowServerWindows.match(frame: theirs, title: nil, pid: app, in: covered) == nil)
    }

    @Test("a frame match tolerates a point of rounding and no more")
    func matchTolerance() {
        let near = CGRect(x: 100.5, y: 99.5, width: 800, height: 600.5)
        #expect(WindowServerWindows.match(frame: near, title: nil, pid: app, in: covered)?.id == 1)
        let far = CGRect(x: 103, y: 100, width: 800, height: 600)
        #expect(WindowServerWindows.match(frame: far, title: nil, pid: app, in: covered) == nil)
    }

    @Test("a menu with the window's frame is not mistaken for the window")
    func matchIgnoresNonNormalLayers() {
        let overlay = WindowServerWindow(
            id: 5, pid: app, layer: 101, bounds: CGRect(x: 100, y: 100, width: 800, height: 600))
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(
            WindowServerWindows.match(frame: frame, title: nil, pid: app, in: [overlay] + covered)?
                .id == 1)
    }

    @Test("identical frames are told apart by title, else the frontmost wins")
    func matchTieBreak() {
        let bounds = CGRect(x: 100, y: 100, width: 800, height: 600)
        let windows = [
            WindowServerWindow(id: 2, pid: app, layer: 0, bounds: bounds, title: ""),
            WindowServerWindow(id: 1, pid: app, layer: 0, bounds: bounds, title: "Doc"),
        ]
        #expect(WindowServerWindows.match(frame: bounds, title: "Doc", pid: app, in: windows)?.id == 1)
        #expect(WindowServerWindows.match(frame: bounds, title: nil, pid: app, in: windows)?.id == 2)
        #expect(
            WindowServerWindows.match(frame: bounds, title: "Missing", pid: app, in: windows)?.id
                == 2)
    }

    // MARK: - Click counting

    @Test("two quick clicks in place count 1 then 2; a third counts 3")
    func doubleAndTripleClick() {
        var clicks = ClickCounter()
        let p = CGPoint(x: 10, y: 10)
        #expect(clicks.down(button: .left, windowID: 1, at: p, time: 0.00, interval: 0.5) == 1)
        #expect(clicks.down(button: .left, windowID: 1, at: p, time: 0.20, interval: 0.5) == 2)
        #expect(clicks.down(button: .left, windowID: 1, at: p, time: 0.40, interval: 0.5) == 3)
    }

    @Test("a slow second click starts over")
    func slowClickResets() {
        var clicks = ClickCounter()
        let p = CGPoint(x: 10, y: 10)
        #expect(clicks.down(button: .left, windowID: 1, at: p, time: 0.0, interval: 0.5) == 1)
        #expect(clicks.down(button: .left, windowID: 1, at: p, time: 0.6, interval: 0.5) == 1)
    }

    @Test("moving away, changing button, or changing window starts over")
    func differentTargetResets() {
        let p = CGPoint(x: 10, y: 10)
        var moved = ClickCounter()
        _ = moved.down(button: .left, windowID: 1, at: p, time: 0, interval: 0.5)
        #expect(
            moved.down(
                button: .left, windowID: 1, at: CGPoint(x: 10 + ClickCounter.slop + 1, y: 10),
                time: 0.1, interval: 0.5) == 1)

        var button = ClickCounter()
        _ = button.down(button: .left, windowID: 1, at: p, time: 0, interval: 0.5)
        #expect(button.down(button: .right, windowID: 1, at: p, time: 0.1, interval: 0.5) == 1)

        var window = ClickCounter()
        _ = window.down(button: .left, windowID: 1, at: p, time: 0, interval: 0.5)
        #expect(window.down(button: .left, windowID: 2, at: p, time: 0.1, interval: 0.5) == 1)
    }

    // MARK: - The Cocoa-boundary flip

    @Test("the pre-flip cancels NSEvent's flip against the main display height")
    func foreignWindowEventLocationFlip() {
        // The measured case (architecture.md §8): window-local (164,255) on a
        // 1080pt-tall main display is handed to NSEvent as (164, 825); NSEvent's
        // own conversion flips it back to (164,255) for the receiving window.
        let location = Coordinates.foreignWindowEventLocation(
            fromWindowLocalPoints: CGPoint(x: 164, y: 255), mainDisplayHeightPoints: 1080)
        #expect(location == CGPoint(x: 164, y: 825))
        #expect(1080 - location.y == 255)
    }

    @Test("a point above-left of the window stays outside it after the flip")
    func foreignWindowEventLocationOutside() {
        let location = Coordinates.foreignWindowEventLocation(
            fromWindowLocalPoints: CGPoint(x: -10_000, y: -10_000), mainDisplayHeightPoints: 1080)
        #expect(location == CGPoint(x: -10_000, y: 11_080))
    }
}
