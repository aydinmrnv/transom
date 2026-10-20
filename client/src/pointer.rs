//! Pure pointer gating: which proxy-window pointer positions go on the wire.
//!
//! A proxy's client area and the Mac window it shows are the same size once a
//! resize has settled, but not always: the host can clamp a resize, and a move
//! to a monitor with a different DPI rescales the proxy before the host has
//! relaid the window out. Pixels past the streamed content are not part of the
//! Mac window, so a point there is never sent (protocol.md §4 "Pointer
//! routing"); the host would have to post it on whatever lies beyond the
//! window's edge. A drag that leaves the content is held at its edge instead, so
//! the button it started with is always released.

use crate::wire::{InputEvent, MouseButton, Size};

/// Per-proxy pointer state: the buttons the host has been told are down.
#[derive(Debug, Default)]
pub struct PointerGate {
    held: u8,
    /// Where the pointer was last sent, for a release that has no position of
    /// its own (mouse capture taken away mid-drag).
    last: (u32, u32),
}

fn bit(button: MouseButton) -> u8 {
    match button {
        MouseButton::Left => 1,
        MouseButton::Right => 2,
        MouseButton::Middle => 4,
    }
}

impl PointerGate {
    /// A button went down at client pixel `(x, y)`. `None` if it is outside the
    /// content and no drag is under way.
    pub fn press(
        &mut self,
        button: MouseButton,
        x: i32,
        y: i32,
        content: Size,
    ) -> Option<InputEvent> {
        let (x, y) = self.point(x, y, content)?;
        self.held |= bit(button);
        self.last = (x, y);
        Some(InputEvent::MouseDown { x, y, button })
    }

    /// A button went up. `None` if its press was never sent.
    pub fn release(
        &mut self,
        button: MouseButton,
        x: i32,
        y: i32,
        content: Size,
    ) -> Option<InputEvent> {
        if self.held & bit(button) == 0 {
            return None;
        }
        let (x, y) = self.point(x, y, content)?;
        self.held &= !bit(button);
        self.last = (x, y);
        Some(InputEvent::MouseUp { x, y, button })
    }

    pub fn motion(&mut self, x: i32, y: i32, content: Size) -> Option<InputEvent> {
        let (x, y) = self.point(x, y, content)?;
        self.last = (x, y);
        Some(InputEvent::MouseMove { x, y })
    }

    pub fn scroll(&self, x: i32, y: i32, dx: i32, dy: i32, content: Size) -> Option<InputEvent> {
        let (x, y) = self.point(x, y, content)?;
        Some(InputEvent::Scroll { x, y, dx, dy })
    }

    /// The pointer was taken away mid-drag: release every button still down.
    pub fn release_all(&mut self) -> Vec<InputEvent> {
        let (x, y) = self.last;
        let held = std::mem::take(&mut self.held);
        [MouseButton::Left, MouseButton::Right, MouseButton::Middle]
            .into_iter()
            .filter(|&button| held & bit(button) != 0)
            .map(|button| InputEvent::MouseUp { x, y, button })
            .collect()
    }

    /// Client pixel → content pixel: held at the nearest edge during a drag,
    /// otherwise `None` outside the content.
    fn point(&self, x: i32, y: i32, content: Size) -> Option<(u32, u32)> {
        let max_x = content.w.max(1) - 1;
        let max_y = content.h.max(1) - 1;
        if self.held != 0 {
            return Some(((x.max(0) as u32).min(max_x), (y.max(0) as u32).min(max_y)));
        }
        if x < 0 || y < 0 || x as u32 >= content.w || y as u32 >= content.h {
            return None;
        }
        Some((x as u32, y as u32))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CONTENT: Size = Size { w: 800, h: 600 };

    #[test]
    fn points_inside_the_content_pass_through() {
        let mut gate = PointerGate::default();
        assert_eq!(
            gate.motion(799, 599, CONTENT),
            Some(InputEvent::MouseMove { x: 799, y: 599 })
        );
        assert_eq!(
            gate.scroll(10, 20, 0, -1, CONTENT),
            Some(InputEvent::Scroll {
                x: 10,
                y: 20,
                dx: 0,
                dy: -1
            })
        );
    }

    #[test]
    fn the_margin_past_the_content_sends_nothing() {
        // A proxy left larger than its Mac window letterboxes; x == w is the
        // first pixel of the margin.
        let mut gate = PointerGate::default();
        assert_eq!(gate.motion(800, 10, CONTENT), None);
        assert_eq!(gate.motion(10, -1, CONTENT), None);
        assert_eq!(gate.scroll(10, 600, 0, 1, CONTENT), None);
        assert_eq!(gate.press(MouseButton::Left, 900, 10, CONTENT), None);
        // The press was never sent, so neither is its release.
        assert_eq!(gate.release(MouseButton::Left, 900, 10, CONTENT), None);
    }

    #[test]
    fn a_drag_that_leaves_the_content_is_held_at_its_edge() {
        let mut gate = PointerGate::default();
        assert!(gate.press(MouseButton::Left, 400, 300, CONTENT).is_some());
        assert_eq!(
            gate.motion(2000, -50, CONTENT),
            Some(InputEvent::MouseMove { x: 799, y: 0 })
        );
        assert_eq!(
            gate.release(MouseButton::Left, -5, 9000, CONTENT),
            Some(InputEvent::MouseUp {
                x: 0,
                y: 599,
                button: MouseButton::Left
            })
        );
        // Drag over: the margin is dead again.
        assert_eq!(gate.motion(2000, 10, CONTENT), None);
    }

    #[test]
    fn losing_the_pointer_releases_every_held_button_once() {
        let mut gate = PointerGate::default();
        gate.press(MouseButton::Left, 10, 10, CONTENT);
        gate.press(MouseButton::Middle, 12, 14, CONTENT);
        gate.motion(30, 40, CONTENT);
        assert_eq!(
            gate.release_all(),
            vec![
                InputEvent::MouseUp {
                    x: 30,
                    y: 40,
                    button: MouseButton::Left
                },
                InputEvent::MouseUp {
                    x: 30,
                    y: 40,
                    button: MouseButton::Middle
                },
            ]
        );
        assert!(gate.release_all().is_empty());
        assert_eq!(gate.release(MouseButton::Left, 30, 40, CONTENT), None);
    }
}
