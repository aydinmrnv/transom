import Testing

@testable import TransomKit

/// Unit tests for pointer routing (protocol.md §4): the two rules that keep an
/// event addressed to one window from landing on another. Pure, so the runaway
/// drag is reproduced here as arithmetic rather than only observed on the Mac.
@Suite("PointerRouter")
struct PointerRouterTests {

    private typealias Post = PointerRouter.Post

    private let a = WireRect(x: 100, y: 200, w: 800, h: 600)
    private let b = WireRect(x: 1100, y: 200, w: 800, h: 600)

    private func down(_ x: UInt32, _ y: UInt32, _ button: MouseButton = .left) -> InputEvent {
        .mouseDown(x: x, y: y, button: button)
    }
    private func up(_ x: UInt32, _ y: UInt32, _ button: MouseButton = .left) -> InputEvent {
        .mouseUp(x: x, y: y, button: button)
    }

    // MARK: bounds

    @Test("a hover inside the window is posted against its current rect")
    func hoverInside() {
        var router = PointerRouter()
        let route = router.route(.mouseMove(x: 10, y: 20), id: 1, rect: a)
        #expect(route.posts == [Post(kind: .move, x: 10, y: 20, rect: a)])
        #expect(route.dropped == nil)
    }

    @Test("a press, hover or scroll past the window's edge is dropped, not posted on a neighbour")
    func outsideIsDropped() {
        var router = PointerRouter()
        // x == w is the first pixel past the right edge.
        for event in [
            down(800, 10), .mouseMove(x: 10, y: 600), .scroll(x: 5000, y: 10, dx: 0, dy: 1),
        ] {
            let route = router.route(event, id: 1, rect: a)
            #expect(route.posts.isEmpty)
            #expect(route.dropped != nil)
        }
        #expect(!router.isDragging)
    }

    @Test("an event for an unknown window is dropped")
    func unknownWindow() {
        var router = PointerRouter()
        #expect(router.route(down(1, 1), id: 9, rect: nil).posts.isEmpty)
        #expect(router.route(.mouseMove(x: 1, y: 1), id: 9, rect: nil).posts.isEmpty)
    }

    @Test("the release of a dropped press is dropped too")
    func releaseOfDroppedPress() {
        var router = PointerRouter()
        _ = router.route(down(900, 10), id: 1, rect: a)
        let route = router.route(up(900, 10), id: 1, rect: a)
        #expect(route.posts.isEmpty)
        #expect(route.dropped != nil)
    }

    // MARK: drag latch

    @Test("a drag that moves its own window keeps translating against the rect at the press")
    func dragLatchesTheRect() {
        var router = PointerRouter()
        _ = router.route(down(400, 10), id: 1, rect: a)

        // The pointer moves 50px right; the window follows, so the registry now
        // reports it 50px along. Translating against that would post 100px along.
        let moved = WireRect(x: a.x + 50, y: a.y, w: a.w, h: a.h)
        let route = router.route(.mouseMove(x: 450, y: 10), id: 1, rect: moved)
        #expect(route.posts == [Post(kind: .drag(.left), x: 450, y: 10, rect: a)])

        let release = router.route(up(450, 10), id: 1, rect: moved)
        #expect(release.posts == [Post(kind: .up(.left), x: 450, y: 10, rect: a)])
        #expect(!router.isDragging)

        // Once released, the window's new rect is the truth again.
        let hover = router.route(.mouseMove(x: 450, y: 10), id: 1, rect: moved)
        #expect(hover.posts == [Post(kind: .move, x: 450, y: 10, rect: moved)])
    }

    @Test("a drag that leaves the window is held at its edge")
    func dragClampsToTheWindow() {
        var router = PointerRouter()
        _ = router.route(down(400, 300), id: 1, rect: a)
        let route = router.route(.mouseMove(x: 5000, y: 10_000), id: 1, rect: a)
        #expect(route.posts == [Post(kind: .drag(.left), x: 799, y: 599, rect: a)])
        let release = router.route(up(5000, 0), id: 1, rect: a)
        #expect(release.posts == [Post(kind: .up(.left), x: 799, y: 0, rect: a)])
    }

    @Test("the drag is named by the first button pressed and ends with the last released")
    func multipleButtons() {
        var router = PointerRouter()
        _ = router.route(down(10, 10, .right), id: 1, rect: a)
        _ = router.route(down(10, 10, .left), id: 1, rect: a)
        #expect(
            router.route(.mouseMove(x: 20, y: 20), id: 1, rect: a).posts
                == [Post(kind: .drag(.right), x: 20, y: 20, rect: a)])
        _ = router.route(up(20, 20, .right), id: 1, rect: a)
        #expect(router.isDragging)
        #expect(
            router.route(.mouseMove(x: 30, y: 30), id: 1, rect: a).posts
                == [Post(kind: .drag(.left), x: 30, y: 30, rect: a)])
        _ = router.route(up(30, 30, .left), id: 1, rect: a)
        #expect(!router.isDragging)
    }

    @Test("while one window is dragged, a hover addressed to another is dropped")
    func dragOwnsThePointer() {
        var router = PointerRouter()
        _ = router.route(down(10, 10), id: 1, rect: a)
        let route = router.route(.mouseMove(x: 10, y: 10), id: 2, rect: b)
        #expect(route.posts.isEmpty)
        #expect(route.dropped != nil)
    }

    // MARK: lost releases

    @Test("a press on another window first releases the button the client never let go of")
    func pressElsewhereReleasesTheLostDrag() {
        var router = PointerRouter()
        _ = router.route(down(10, 10), id: 1, rect: a)
        _ = router.route(.mouseMove(x: 40, y: 50), id: 1, rect: a)
        let route = router.route(down(5, 5), id: 2, rect: b)
        #expect(
            route.posts == [
                Post(kind: .up(.left), x: 40, y: 50, rect: a),
                Post(kind: .down(.left), x: 5, y: 5, rect: b),
            ])
    }

    @Test("pressing a button that is already held releases it first and re-latches")
    func repeatedPressRelatches() {
        var router = PointerRouter()
        _ = router.route(down(10, 10), id: 1, rect: a)
        let moved = WireRect(x: 0, y: 0, w: a.w, h: a.h)
        let route = router.route(down(20, 20), id: 1, rect: moved)
        #expect(
            route.posts == [
                Post(kind: .up(.left), x: 10, y: 10, rect: a),
                Post(kind: .down(.left), x: 20, y: 20, rect: moved),
            ])
    }

    @Test("a release addressed to another window still lets go, where the drag last was")
    func releaseFromAnotherWindow() {
        var router = PointerRouter()
        _ = router.route(down(10, 10), id: 1, rect: a)
        let route = router.route(up(700, 500), id: 2, rect: b)
        #expect(route.posts == [Post(kind: .up(.left), x: 10, y: 10, rect: a)])
        #expect(!router.isDragging)
    }

    @Test("releaseAll lets go of every held button and ends the drag")
    func releaseAll() {
        var router = PointerRouter()
        _ = router.route(down(10, 10), id: 1, rect: a)
        _ = router.route(down(12, 12, .middle), id: 1, rect: a)
        #expect(
            router.releaseAll() == [
                Post(kind: .up(.left), x: 12, y: 12, rect: a),
                Post(kind: .up(.middle), x: 12, y: 12, rect: a),
            ])
        #expect(!router.isDragging)
        #expect(router.releaseAll().isEmpty)
    }

    // MARK: scroll and keys

    @Test("a scroll during a drag uses the latched rect")
    func scrollDuringDrag() {
        var router = PointerRouter()
        _ = router.route(down(10, 10), id: 1, rect: a)
        let moved = WireRect(x: 0, y: 0, w: a.w, h: a.h)
        let route = router.route(.scroll(x: 30, y: 40, dx: 0, dy: -2), id: 1, rect: moved)
        #expect(route.posts == [Post(kind: .scroll(dx: 0, dy: -2), x: 30, y: 40, rect: a)])
    }

    @Test("key events route nowhere")
    func keysAreIgnored() {
        var router = PointerRouter()
        #expect(router.route(.keyDown(vk: 0x41), id: 1, rect: a) == PointerRouter.Route())
    }
}
