//! Native Windows chrome is outside the exact-pixel streamed client viewport.
use crate::wire::Size;
use windows::Win32::{
    Foundation::RECT,
    UI::{
        HiDpi::AdjustWindowRectExForDpi,
        Input::KeyboardAndMouse::{GetAsyncKeyState, VK_MENU},
        WindowsAndMessaging::*,
    },
};
pub fn hit_test(native: u32) -> u32 {
    if native == HTCLIENT && unsafe { GetAsyncKeyState(VK_MENU.0 as i32) } < 0 {
        HTCAPTION
    } else {
        native
    }
}
pub fn outer_size(w: u32, h: u32, dpi: u32) -> (i32, i32) {
    let mut r = RECT {
        left: 0,
        top: 0,
        right: w as i32,
        bottom: h as i32,
    };
    unsafe {
        let _ =
            AdjustWindowRectExForDpi(&mut r, WS_OVERLAPPEDWINDOW, false, Default::default(), dpi);
    }
    (r.right - r.left, r.bottom - r.top)
}
pub fn client_size(w: u32, h: u32, dpi: u32) -> Size {
    let inset = outer_size(0, 0, dpi);
    Size {
        w: (w as i32 - inset.0).max(1) as u32,
        h: (h as i32 - inset.1).max(1) as u32,
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn chrome_is_excluded_at_every_dpi() {
        for dpi in [96, 144, 192] {
            let outer = outer_size(1234, 789, dpi);
            assert_eq!(
                client_size(outer.0 as u32, outer.1 as u32, dpi),
                Size { w: 1234, h: 789 }
            );
        }
    }
}
