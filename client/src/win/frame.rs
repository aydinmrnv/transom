//! Keep Windows in charge of moving, sizing and snapping a borderless proxy.
//! Removing the non-client area also removes default hit testing; return native
//! HT codes, never implement a separate drag loop. See Microsoft's DWM customframe.
use windows::Win32::Foundation::{HWND, LPARAM, RECT};
use windows::Win32::UI::HiDpi::{GetDpiForWindow, GetSystemMetricsForDpi};
use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_MENU};
use windows::Win32::UI::WindowsAndMessaging::*;

pub fn hit_test(hwnd: HWND, point: LPARAM) -> u32 {
    unsafe {
        let mut rect = RECT::default();
        if GetWindowRect(hwnd, &mut rect).is_err() {
            return HTCLIENT;
        }
        let dpi = GetDpiForWindow(hwnd);
        let border = GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi)
            + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
        let x = (point.0 & 0xffff) as i16 as i32;
        let y = ((point.0 >> 16) & 0xffff) as i16 as i32;
        classify(
            rect,
            x,
            y,
            if IsZoomed(hwnd).as_bool() { 0 } else { border },
            GetAsyncKeyState(VK_MENU.0 as i32) < 0,
        )
    }
}

fn classify(r: RECT, x: i32, y: i32, border: i32, move_window: bool) -> u32 {
    let left = x < r.left + border;
    let right = x >= r.right - border;
    let top = y < r.top + border;
    let bottom = y >= r.bottom - border;
    match (left, right, top, bottom) {
        (true, _, true, _) => HTTOPLEFT,
        (_, true, true, _) => HTTOPRIGHT,
        (true, _, _, true) => HTBOTTOMLEFT,
        (_, true, _, true) => HTBOTTOMRIGHT,
        (true, _, _, _) => HTLEFT,
        (_, true, _, _) => HTRIGHT,
        (_, _, true, _) => HTTOP,
        (_, _, _, true) => HTBOTTOM,
        _ if move_window => HTCAPTION,
        _ => HTCLIENT,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn negative_monitor_coordinates_and_corners() {
        let r = RECT {
            left: -1200,
            top: 80,
            right: -400,
            bottom: 680,
        };
        assert_eq!(classify(r, -1199, 81, 16, false), HTTOPLEFT);
        assert_eq!(classify(r, -401, 679, 16, false), HTBOTTOMRIGHT);
        assert_eq!(classify(r, -800, 300, 16, false), HTCLIENT);
        assert_eq!(classify(r, -800, 300, 16, true), HTCAPTION);
        assert_eq!(classify(r, -1199, 81, 0, false), HTCLIENT);
    }
}
