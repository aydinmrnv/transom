//! Input events the client posts at a proxy window (protocol.md §4 `Input`,
//! issue #7). The mirror of the host's `InputEvent`.
//!
//! Two rules the wire encodes and this module must not violate:
//!
//!  * **Coordinates are window-local physical pixels** (Client Space, I-2/I-3):
//!    origin at the proxy window's top-left, Y down. The client sends CS and
//!    nothing else; the host owns the CS → VDS → AX-point translation. We never
//!    put a monitor-global or DIP coordinate on the wire.
//!  * **Keys are Windows virtual-key codes** (`vk`), never macOS keycodes. We send
//!    what the physical keyboard reports; the host maps VK → macOS keycode and
//!    tracks modifier state. We attach no per-event modifier flags and synthesize
//!    no key repeats (the host expects one `keyDown` per OS repeat tick).

use super::json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseButton {
    Left,
    Right,
    Middle,
}

impl MouseButton {
    fn wire(self) -> &'static str {
        match self {
            MouseButton::Left => "left",
            MouseButton::Right => "right",
            MouseButton::Middle => "middle",
        }
    }
}

/// One input event, in Client Space physical pixels / Windows VK codes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputEvent {
    MouseDown { x: u32, y: u32, button: MouseButton },
    MouseUp { x: u32, y: u32, button: MouseButton },
    MouseMove { x: u32, y: u32 },
    /// Signed line deltas; positive `dy` scrolls content up (a wheel roll away).
    Scroll { x: u32, y: u32, dx: i32, dy: i32 },
    KeyDown { vk: u32 },
    KeyUp { vk: u32 },
}

impl InputEvent {
    /// Build the nested `event` object exactly as the host's `InputEvent` decoder
    /// expects: a `"kind"` discriminator plus the event's own fields.
    pub fn to_value(self) -> Value {
        match self {
            InputEvent::MouseDown { x, y, button } => Value::object(vec![
                ("kind", Value::str("mouseDown")),
                ("x", Value::uint(x as u64)),
                ("y", Value::uint(y as u64)),
                ("button", Value::str(button.wire())),
            ]),
            InputEvent::MouseUp { x, y, button } => Value::object(vec![
                ("kind", Value::str("mouseUp")),
                ("x", Value::uint(x as u64)),
                ("y", Value::uint(y as u64)),
                ("button", Value::str(button.wire())),
            ]),
            InputEvent::MouseMove { x, y } => Value::object(vec![
                ("kind", Value::str("mouseMove")),
                ("x", Value::uint(x as u64)),
                ("y", Value::uint(y as u64)),
            ]),
            InputEvent::Scroll { x, y, dx, dy } => Value::object(vec![
                ("kind", Value::str("scroll")),
                ("x", Value::uint(x as u64)),
                ("y", Value::uint(y as u64)),
                ("dx", Value::int(dx as i64)),
                ("dy", Value::int(dy as i64)),
            ]),
            InputEvent::KeyDown { vk } => Value::object(vec![
                ("kind", Value::str("keyDown")),
                ("vk", Value::uint(vk as u64)),
            ]),
            InputEvent::KeyUp { vk } => Value::object(vec![
                ("kind", Value::str("keyUp")),
                ("vk", Value::uint(vk as u64)),
            ]),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mouse_down_matches_protocol_example() {
        // protocol.md §4 concrete example: the nested event object.
        let ev = InputEvent::MouseDown {
            x: 400,
            y: 300,
            button: MouseButton::Left,
        };
        assert_eq!(
            ev.to_value().to_json(),
            r#"{"kind":"mouseDown","x":400,"y":300,"button":"left"}"#
        );
    }

    #[test]
    fn scroll_keeps_signed_deltas() {
        let ev = InputEvent::Scroll {
            x: 10,
            y: 20,
            dx: -3,
            dy: 5,
        };
        assert_eq!(
            ev.to_value().to_json(),
            r#"{"kind":"scroll","x":10,"y":20,"dx":-3,"dy":5}"#
        );
    }

    #[test]
    fn key_events_carry_raw_vk() {
        assert_eq!(
            InputEvent::KeyDown { vk: 0x41 }.to_value().to_json(),
            r#"{"kind":"keyDown","vk":65}"#
        );
        assert_eq!(
            InputEvent::KeyUp { vk: 0x11 }.to_value().to_json(),
            r#"{"kind":"keyUp","vk":17}"#
        );
    }
}
