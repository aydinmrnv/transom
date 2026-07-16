//! Win32 input messages → protocol `InputEvent`s.
//!
//! The client sends **Client-Space physical pixels and raw Windows VK codes**
//! and nothing else (protocol.md §4): the host owns CS→VDS→AX translation, the
//! VK→macOS-keycode map, and modifier state. So this module's whole job is a
//! faithful, lossless transcription of what Windows reports — no coordinate math
//! beyond client-relative, no key remapping, no synthesized repeats (Windows
//! already delivers one `WM_KEYDOWN` per repeat tick, which is exactly one
//! `keyDown` on the wire).
//!
//! Because the process is Per-Monitor-V2 aware, the `lParam` mouse coordinates
//! are already physical client pixels, so they *are* Client Space (I-2/I-3).

use windows::Win32::Foundation::{HWND, LPARAM, POINT, WPARAM};
use windows::Win32::Graphics::Gdi::ScreenToClient;
use windows::Win32::UI::WindowsAndMessaging::{
    WHEEL_DELTA, WM_KEYDOWN, WM_KEYUP, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MBUTTONDOWN, WM_MBUTTONUP,
    WM_MOUSEHWHEEL, WM_MOUSEMOVE, WM_MOUSEWHEEL, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_SYSKEYDOWN,
    WM_SYSKEYUP,
};

use crate::wire::{InputEvent, MouseButton};

/// The low 16 bits of an `isize`/`usize`, interpreted as a signed pixel value
/// (mouse coordinates can be negative when the pointer is captured off-window).
fn loword_signed(v: isize) -> i32 {
    (v & 0xFFFF) as i16 as i32
}
fn hiword_signed(v: isize) -> i32 {
    ((v >> 16) & 0xFFFF) as i16 as i32
}

/// Clamp a possibly-negative client coordinate into the `u32` the wire uses,
/// treating anything left/above the client area as the edge.
fn clamp_cs(v: i32) -> u32 {
    v.max(0) as u32
}

/// Translate one window message into an `InputEvent`, or `None` if it isn't an
/// input message we forward. `hwnd` is needed only to make wheel events (which
/// arrive in screen coordinates) client-relative.
pub fn event_for_message(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> Option<InputEvent> {
    match msg {
        WM_MOUSEMOVE => {
            let x = clamp_cs(loword_signed(lparam.0));
            let y = clamp_cs(hiword_signed(lparam.0));
            Some(InputEvent::MouseMove { x, y })
        }
        WM_LBUTTONDOWN => Some(mouse(lparam, MouseButton::Left, true)),
        WM_LBUTTONUP => Some(mouse(lparam, MouseButton::Left, false)),
        WM_RBUTTONDOWN => Some(mouse(lparam, MouseButton::Right, true)),
        WM_RBUTTONUP => Some(mouse(lparam, MouseButton::Right, false)),
        WM_MBUTTONDOWN => Some(mouse(lparam, MouseButton::Middle, true)),
        WM_MBUTTONUP => Some(mouse(lparam, MouseButton::Middle, false)),
        WM_MOUSEWHEEL => wheel(hwnd, wparam, lparam, false),
        WM_MOUSEHWHEEL => wheel(hwnd, wparam, lparam, true),
        WM_KEYDOWN | WM_SYSKEYDOWN => Some(InputEvent::KeyDown {
            vk: (wparam.0 & 0xFF) as u32,
        }),
        WM_KEYUP | WM_SYSKEYUP => Some(InputEvent::KeyUp {
            vk: (wparam.0 & 0xFF) as u32,
        }),
        _ => None,
    }
}

fn mouse(lparam: LPARAM, button: MouseButton, down: bool) -> InputEvent {
    let x = clamp_cs(loword_signed(lparam.0));
    let y = clamp_cs(hiword_signed(lparam.0));
    if down {
        InputEvent::MouseDown { x, y, button }
    } else {
        InputEvent::MouseUp { x, y, button }
    }
}

/// Wheel events carry a signed delta in `wParam`'s high word (multiples of
/// `WHEEL_DELTA` = 120) and a **screen** position in `lParam`. Convert the
/// position to client space and the delta to signed line steps.
fn wheel(hwnd: HWND, wparam: WPARAM, lparam: LPARAM, horizontal: bool) -> Option<InputEvent> {
    let delta = hiword_signed(wparam.0 as isize);
    let steps = delta / WHEEL_DELTA as i32;
    if steps == 0 {
        // Sub-notch high-resolution wheels: nothing to send yet.
        return None;
    }
    let mut pt = POINT {
        x: loword_signed(lparam.0),
        y: hiword_signed(lparam.0),
    };
    unsafe {
        let _ = ScreenToClient(hwnd, &mut pt);
    }
    let x = clamp_cs(pt.x);
    let y = clamp_cs(pt.y);
    if horizontal {
        Some(InputEvent::Scroll {
            x,
            y,
            dx: steps,
            dy: 0,
        })
    } else {
        Some(InputEvent::Scroll {
            x,
            y,
            dx: 0,
            dy: steps,
        })
    }
}
