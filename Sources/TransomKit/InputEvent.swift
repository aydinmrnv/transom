import Foundation

/// The input events the client posts into a proxy window (issue #7, protocol.md
/// §4 `Input`). Carried as the `event` field of a `ClientMessage.input`.
///
/// **Coordinates are window-local physical pixels** (Client Space, I-3): origin
/// at the proxy window's top-left, Y **down**. The client does *not* know about
/// VDS, AX, points, or the virtual display's scale factor — translating a
/// window-local pixel into a postable AX point is entirely the host's job
/// (`Coordinates.axGlobalPoint`). Keeping the wire in CS is what invariant I-2/I-3
/// require and what lets the client stay ignorant of the host's coordinate spaces.
///
/// **Keys are Windows virtual-key codes** (`vk`), *not* macOS keycodes. The
/// client sends what its physical keyboard reports; the host maps VK → macOS
/// keycode (`Keymap`) and tracks modifier state (`ModifierState`). See
/// protocol.md §4 for the exact JSON shapes and the key-repeat / modifier rules.
public enum InputEvent: Sendable, Equatable {
    case mouseDown(x: UInt32, y: UInt32, button: MouseButton)
    case mouseUp(x: UInt32, y: UInt32, button: MouseButton)
    case mouseMove(x: UInt32, y: UInt32)
    /// Wheel/trackpad scroll at a point. `dx`/`dy` are signed line deltas
    /// (positive `dy` scrolls content up, matching a wheel roll away from you).
    case scroll(x: UInt32, y: UInt32, dx: Int32, dy: Int32)
    /// A physical key press (Windows VK). The client sends one of these per OS
    /// key-repeat tick; the host does not synthesize repeats (protocol.md §4).
    case keyDown(vk: UInt32)
    case keyUp(vk: UInt32)
}

/// Which mouse button an event refers to. String-valued on the wire so the JSON
/// is self-describing across languages.
public enum MouseButton: String, Codable, Sendable {
    case left
    case right
    case middle
}

extension InputEvent: Codable {
    private enum Key: String, CodingKey {
        case kind, x, y, button, dx, dy, vk
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .mouseDown(let x, let y, let button):
            try c.encode("mouseDown", forKey: .kind)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(button, forKey: .button)
        case .mouseUp(let x, let y, let button):
            try c.encode("mouseUp", forKey: .kind)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(button, forKey: .button)
        case .mouseMove(let x, let y):
            try c.encode("mouseMove", forKey: .kind)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
        case .scroll(let x, let y, let dx, let dy):
            try c.encode("scroll", forKey: .kind)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(dx, forKey: .dx)
            try c.encode(dy, forKey: .dy)
        case .keyDown(let vk):
            try c.encode("keyDown", forKey: .kind)
            try c.encode(vk, forKey: .vk)
        case .keyUp(let vk):
            try c.encode("keyUp", forKey: .kind)
            try c.encode(vk, forKey: .vk)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "mouseDown":
            self = .mouseDown(
                x: try c.decode(UInt32.self, forKey: .x),
                y: try c.decode(UInt32.self, forKey: .y),
                button: try c.decode(MouseButton.self, forKey: .button))
        case "mouseUp":
            self = .mouseUp(
                x: try c.decode(UInt32.self, forKey: .x),
                y: try c.decode(UInt32.self, forKey: .y),
                button: try c.decode(MouseButton.self, forKey: .button))
        case "mouseMove":
            self = .mouseMove(
                x: try c.decode(UInt32.self, forKey: .x),
                y: try c.decode(UInt32.self, forKey: .y))
        case "scroll":
            self = .scroll(
                x: try c.decode(UInt32.self, forKey: .x),
                y: try c.decode(UInt32.self, forKey: .y),
                dx: try c.decode(Int32.self, forKey: .dx),
                dy: try c.decode(Int32.self, forKey: .dy))
        case "keyDown":
            self = .keyDown(vk: try c.decode(UInt32.self, forKey: .vk))
        case "keyUp":
            self = .keyUp(vk: try c.decode(UInt32.self, forKey: .vk))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown InputEvent kind \"\(kind)\"")
        }
    }
}
