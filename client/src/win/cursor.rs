//! Native cursor feedback. Never bake a pointer into delayed video frames.
use crate::wire::Rect;
use std::{
    cell::RefCell,
    collections::HashMap,
    time::{Duration, Instant},
};
use windows::Win32::{
    Foundation::{HWND, LPARAM, POINT},
    Graphics::Gdi::ScreenToClient,
    UI::WindowsAndMessaging::*,
};

struct Hint {
    text: bool,
    rect: Rect,
    ts: u64,
    received: Instant,
}
thread_local! { static HINTS: RefCell<HashMap<isize, Hint>> = RefCell::new(HashMap::new()); }
thread_local! {
    static TRACE: bool = std::env::var_os("TRANSOM_CURSOR_TRACE").is_some();
    static LAST_TRACE: RefCell<Option<(isize, bool)>> = const { RefCell::new(None) };
}

fn contains(rect: Rect, x: i32, y: i32) -> bool {
    x >= 0
        && y >= 0
        && (x as u32) >= rect.x
        && (y as u32) >= rect.y
        && (x as u32) < rect.x.saturating_add(rect.w)
        && (y as u32) < rect.y.saturating_add(rect.h)
}
pub fn update(hwnd: HWND, text: bool, rect: Rect, ts: u64) {
    // The host also polls a stationary pointer: its input timestamp can be old
    // while the shape is fresh (e.g. a text field appeared under that pointer).
    HINTS.with(|h| {
        let mut hints = h.borrow_mut();
        if hints.get(&(hwnd.0 as isize)).is_some_and(|old| old.ts > ts) {
            return;
        }
        hints.insert(
            hwnd.0 as isize,
            Hint {
                text,
                rect,
                ts,
                received: Instant::now(),
            },
        );
    });
    unsafe {
        let mut p = POINT::default();
        if GetCursorPos(&mut p).is_ok() && WindowFromPoint(p) == hwnd {
            let packed = LPARAM(((p.x as u16 as u32) | ((p.y as u16 as u32) << 16)) as isize);
            if super::frame::hit_test(hwnd, packed).0 == HTCLIENT as isize {
                apply(hwnd);
            }
        }
    }
}
pub fn clear(hwnd: HWND) {
    HINTS.with(|h| {
        h.borrow_mut().remove(&(hwnd.0 as isize));
    });
}
pub fn apply(hwnd: HWND) {
    unsafe {
        let mut p = POINT::default();
        let _ = GetCursorPos(&mut p);
        let _ = ScreenToClient(hwnd, &mut p);
        let text = HINTS.with(|h| {
            h.borrow().get(&(hwnd.0 as isize)).is_some_and(|hint| {
                hint.text
                    && hint.received.elapsed() < Duration::from_millis(600)
                    && contains(hint.rect, p.x, p.y)
            })
        });
        if let Ok(cursor) = LoadCursorW(None, if text { IDC_IBEAM } else { IDC_ARROW }) {
            SetCursor(cursor);
            if TRACE.with(|t| *t) {
                LAST_TRACE.with(|previous| {
                    let key = (hwnd.0 as isize, text);
                    if *previous.borrow() != Some(key) {
                        let mut info = CURSORINFO {
                            cbSize: std::mem::size_of::<CURSORINFO>() as u32,
                            ..Default::default()
                        };
                        let verified = GetCursorInfo(&mut info).is_ok() && info.hCursor == cursor;
                        eprintln!(
                            "cursor: {} at {},{}; native handle verified={verified}",
                            if text { "ibeam" } else { "arrow" },
                            p.x,
                            p.y
                        );
                        *previous.borrow_mut() = Some(key);
                    }
                });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn late_text_hint_only_applies_inside_its_field() {
        let r = Rect {
            x: 30,
            y: 40,
            w: 200,
            h: 24,
        };
        assert!(contains(r, 30, 40));
        assert!(contains(r, 229, 63));
        for (x, y) in [(-1, 40), (29, 40), (230, 40), (30, 64), (100, 20)] {
            assert!(!contains(r, x, y));
        }
        assert!(!contains(Rect { x: u32::MAX, ..r }, 100, 40));
    }
}
