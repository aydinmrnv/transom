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
//! `PointerGate` keeps the ones that fall outside the streamed content off the
//! wire.

use windows::Win32::Foundation::{HWND, LPARAM, POINT, WPARAM};
use windows::Win32::Graphics::Gdi::ScreenToClient;
use windows::Win32::UI::WindowsAndMessaging::{
    WHEEL_DELTA, WM_KEYDOWN, WM_KEYUP, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MBUTTONDOWN, WM_MBUTTONUP,
    WM_MOUSEHWHEEL, WM_MOUSEMOVE, WM_MOUSEWHEEL, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_SYSKEYDOWN,
    WM_SYSKEYUP,
};

use crate::pointer::PointerGate;
use crate::wire::{InputEvent, MouseButton, Size};

pub const DISCONNECT_SHORTCUT: &str = "Ctrl + Alt + Shift + D";

/// Reserved locally before translating/forwarding a key to the Mac. Use queue
/// modifier state (GetKeyState), so a quick press/release still matches its D.
pub fn disconnect_chord(vk: u32, ctrl: bool, alt: bool, shift: bool, win: bool) -> bool {
    vk == b'D' as u32 && ctrl && alt && shift && !win
}

pub fn is_disconnect_message(message: &windows::Win32::UI::WindowsAndMessaging::MSG) -> bool {
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        GetKeyState, VK_CONTROL, VK_LWIN, VK_MENU, VK_RWIN, VK_SHIFT,
    };
    if ![WM_KEYDOWN, WM_SYSKEYDOWN].contains(&message.message) {
        return false;
    }
    unsafe {
        disconnect_chord(
            message.wParam.0 as u32,
            GetKeyState(VK_CONTROL.0 as i32) < 0,
            GetKeyState(VK_MENU.0 as i32) < 0,
            GetKeyState(VK_SHIFT.0 as i32) < 0,
            GetKeyState(VK_LWIN.0 as i32) < 0 || GetKeyState(VK_RWIN.0 as i32) < 0,
        )
    }
}

/// The low 16 bits of an `isize`/`usize`, interpreted as a signed pixel value
/// (mouse coordinates can be negative when the pointer is captured off-window).
fn loword_signed(v: isize) -> i32 {
    (v & 0xFFFF) as i16 as i32
}
fn hiword_signed(v: isize) -> i32 {
    ((v >> 16) & 0xFFFF) as i16 as i32
}

/// Translate one window message into an `InputEvent`, or `None` if it isn't an
/// input message we forward. `hwnd` is needed only to make wheel events (which
/// arrive in screen coordinates) client-relative. `content` is the size of the
/// Mac window the proxy shows; `gate` drops pointer positions outside it.
pub fn event_for_message(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    gate: &mut PointerGate,
    content: Size,
) -> Option<InputEvent> {
    let x = loword_signed(lparam.0);
    let y = hiword_signed(lparam.0);
    match msg {
        WM_MOUSEMOVE => gate.motion(x, y, content),
        WM_LBUTTONDOWN => gate.press(MouseButton::Left, x, y, content),
        WM_LBUTTONUP => gate.release(MouseButton::Left, x, y, content),
        WM_RBUTTONDOWN => gate.press(MouseButton::Right, x, y, content),
        WM_RBUTTONUP => gate.release(MouseButton::Right, x, y, content),
        WM_MBUTTONDOWN => gate.press(MouseButton::Middle, x, y, content),
        WM_MBUTTONUP => gate.release(MouseButton::Middle, x, y, content),
        WM_MOUSEWHEEL => wheel(hwnd, wparam, lparam, false, gate, content),
        WM_MOUSEHWHEEL => wheel(hwnd, wparam, lparam, true, gate, content),
        WM_KEYDOWN | WM_SYSKEYDOWN => Some(InputEvent::KeyDown {
            vk: (wparam.0 & 0xFF) as u32,
        }),
        WM_KEYUP | WM_SYSKEYUP => Some(InputEvent::KeyUp {
            vk: (wparam.0 & 0xFF) as u32,
        }),
        _ => None,
    }
}

/// Wheel events carry a signed delta in `wParam`'s high word (multiples of
/// `WHEEL_DELTA` = 120) and a **screen** position in `lParam`. Convert the
/// position to client space and the delta to signed line steps.
fn wheel(
    hwnd: HWND,
    wparam: WPARAM,
    lparam: LPARAM,
    horizontal: bool,
    gate: &PointerGate,
    content: Size,
) -> Option<InputEvent> {
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
    if horizontal {
        gate.scroll(pt.x, pt.y, steps, 0, content)
    } else {
        gate.scroll(pt.x, pt.y, 0, steps, content)
    }
}

#[cfg(test)]
mod shortcut_tests {
    use super::*;

    #[test]
    fn disconnect_requires_the_exact_chord() {
        for modifiers in 0..16 {
            assert_eq!(
                disconnect_chord(
                    b'D' as u32,
                    modifiers & 1 != 0,
                    modifiers & 2 != 0,
                    modifiers & 4 != 0,
                    modifiers & 8 != 0
                ),
                modifiers == 7
            );
        }
        assert!(!disconnect_chord(b'C' as u32, true, true, true, false));
    }

    #[test]
    fn release_and_character_messages_are_not_disconnect_commands() {
        use windows::Win32::UI::WindowsAndMessaging::{MSG, WM_CHAR};
        for message in [WM_KEYUP, WM_SYSKEYUP, WM_CHAR] {
            assert!(!is_disconnect_message(&MSG {
                message,
                wParam: WPARAM(b'D' as usize),
                ..Default::default()
            }));
        }
    }
}
