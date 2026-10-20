/// Decides where a client pointer event lands on the virtual display, or that it
/// must not be posted at all (protocol.md §4 "Pointer routing").
///
/// A pointer event names one window and a point local to it, but the host can
/// only post it as a *global* HID event: whatever sits under the resulting point
/// receives it. Two rules keep an event meant for one window from reaching
/// another:
///
/// - **Bounds.** A point outside the window's rect is never posted. The client's
///   proxy can be larger than the Mac window for a moment (a clamped resize, a
///   monitor with a different DPI), and the pixels past the window's edge belong
///   to the gutter or to a neighbour.
/// - **Drag latch.** From the first `mouseDown` to the last `mouseUp`, every
///   event is translated against the rect the window had at the press. A drag can
///   move the window it started in (its title bar, a left or top resize edge). If
///   each move were translated against the window's *new* origin, the same local
///   point would land further along every time and the window would run away
///   from the pointer, across its neighbours.
///
/// Pure: no AX and no CoreGraphics, so it is unit tested with no Mac
/// (`Tests/TransomKitTests/PointerRouterTests`). `InputInjector` is the impure
/// half that supplies the rects and posts the result.
public struct PointerRouter: Sendable {

    /// One event to post, at a window-local point already confined to `rect`.
    public struct Post: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case down(MouseButton)
            case up(MouseButton)
            /// A move with this button held.
            case drag(MouseButton)
            case move
            case scroll(dx: Int32, dy: Int32)
        }

        public let kind: Kind
        public let x: UInt32
        public let y: UInt32
        /// The rect `x`/`y` are local to: the window's current rect, or the one
        /// latched at the press.
        public let rect: WireRect
    }

    public struct Route: Sendable, Equatable {
        public var posts: [Post] = []
        /// Why the event itself was not posted; nil when it was.
        public var dropped: String?
    }

    private struct Drag: Sendable {
        let id: UInt64
        let rect: WireRect
        /// Held buttons in press order; the first names the drag.
        var buttons: [MouseButton]
        /// Where the pointer was last posted, for a release that carries no
        /// usable point of its own.
        var x: UInt32
        var y: UInt32
    }

    private var drag: Drag?

    public init() {}

    /// True from the first `mouseDown` to the last `mouseUp`.
    public var isDragging: Bool { drag != nil }

    /// Route one pointer event addressed to window `id`. `rect` is that window's
    /// current VDS rect, or nil if the id is unknown. Key events route nowhere.
    public mutating func route(_ event: InputEvent, id: UInt64, rect: WireRect?) -> Route {
        var route = Route()
        switch event {
        case .mouseDown(let x, let y, let button):
            // A press while another window, or this same button, is still held
            // means the release never arrived. Let go before pressing again.
            if let held = drag, held.id != id || held.buttons.contains(button) {
                route.posts += releaseAll()
            }
            if var held = drag {
                (held.x, held.y) = Self.clamp(x, y, to: held.rect)
                held.buttons.append(button)
                drag = held
                route.posts.append(Post(kind: .down(button), x: held.x, y: held.y, rect: held.rect))
            } else {
                guard let rect else { return route.dropping(Self.unknownWindow) }
                guard Self.contains(x, y, in: rect) else { return route.dropping(Self.outside) }
                drag = Drag(id: id, rect: rect, buttons: [button], x: x, y: y)
                route.posts.append(Post(kind: .down(button), x: x, y: y, rect: rect))
            }

        case .mouseUp(let x, let y, let button):
            // Also drops the release of a press that was itself dropped.
            guard var held = drag, let index = held.buttons.firstIndex(of: button) else {
                return route.dropping("no matching mouseDown")
            }
            if held.id == id { (held.x, held.y) = Self.clamp(x, y, to: held.rect) }
            held.buttons.remove(at: index)
            route.posts.append(Post(kind: .up(button), x: held.x, y: held.y, rect: held.rect))
            drag = held.buttons.isEmpty ? nil : held

        case .mouseMove(let x, let y):
            if var held = drag {
                guard held.id == id else {
                    return route.dropping("another window holds the pointer")
                }
                (held.x, held.y) = Self.clamp(x, y, to: held.rect)
                drag = held
                route.posts.append(
                    Post(kind: .drag(held.buttons[0]), x: held.x, y: held.y, rect: held.rect))
            } else {
                guard let rect else { return route.dropping(Self.unknownWindow) }
                guard Self.contains(x, y, in: rect) else { return route.dropping(Self.outside) }
                route.posts.append(Post(kind: .move, x: x, y: y, rect: rect))
            }

        case .scroll(let x, let y, let dx, let dy):
            if let held = drag, held.id == id {
                let (cx, cy) = Self.clamp(x, y, to: held.rect)
                route.posts.append(
                    Post(kind: .scroll(dx: dx, dy: dy), x: cx, y: cy, rect: held.rect))
            } else {
                guard let rect else { return route.dropping(Self.unknownWindow) }
                guard Self.contains(x, y, in: rect) else { return route.dropping(Self.outside) }
                route.posts.append(Post(kind: .scroll(dx: dx, dy: dy), x: x, y: y, rect: rect))
            }

        case .keyDown, .keyUp:
            break
        }
        return route
    }

    /// End the drag, returning the releases to post for every button still held.
    /// Used when the client goes away mid-drag, so no button stays down on the Mac.
    public mutating func releaseAll() -> [Post] {
        guard let held = drag else { return [] }
        drag = nil
        return held.buttons.map { Post(kind: .up($0), x: held.x, y: held.y, rect: held.rect) }
    }

    private static let unknownWindow = "unknown window id"
    private static let outside = "outside the window"

    private static func contains(_ x: UInt32, _ y: UInt32, in rect: WireRect) -> Bool {
        x < rect.w && y < rect.h
    }

    /// The nearest point inside `rect` (window-local), for a drag that has left it.
    private static func clamp(_ x: UInt32, _ y: UInt32, to rect: WireRect) -> (UInt32, UInt32) {
        (min(x, max(rect.w, 1) - 1), min(y, max(rect.h, 1) - 1))
    }
}

extension PointerRouter.Route {
    fileprivate func dropping(_ reason: String) -> Self {
        var route = self
        route.dropped = reason
        return route
    }
}
