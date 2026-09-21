//! Mac chrome is already in the video. Keep native Windows sizing, but make
//! the whole window an exact-pixel client viewport.
use crate::wire::Size;
use windows::Win32::{
    Foundation::{HWND, LPARAM, LRESULT, RECT},
    UI::{
        Input::KeyboardAndMouse::{GetAsyncKeyState, VK_MENU},
        WindowsAndMessaging::*,
    },
};
pub fn hit_test(hwnd: HWND, point: LPARAM) -> LRESULT {
    let mut rect = RECT::default();
    unsafe {
        let _ = GetWindowRect(hwnd, &mut rect);
    }
    let x = (point.0 as u16 as i16) as i32 - rect.left;
    let y = ((point.0 >> 16) as u16 as i16) as i32 - rect.top;
    LRESULT(hit_at(
        x,
        y,
        rect.right - rect.left,
        rect.bottom - rect.top,
        super::dpi::dpi_for_window(hwnd),
        unsafe { IsZoomed(hwnd).as_bool() },
        unsafe { GetAsyncKeyState(VK_MENU.0 as i32) < 0 },
    ) as isize)
}
#[allow(clippy::too_many_arguments)]
fn hit_at(x: i32, y: i32, w: i32, h: i32, dpi: u32, maximized: bool, alt: bool) -> u32 {
    let edge = ((6 * dpi / 96) as i32).max(5);
    let corner = edge * 3;
    if !maximized {
        let left = x < edge;
        let right = x >= w - edge;
        let top = y < edge;
        let bottom = y >= h - edge;
        if (top && x < corner) || (left && y < corner) {
            return HTTOPLEFT;
        }
        if (top && x >= w - corner) || (right && y < corner) {
            return HTTOPRIGHT;
        }
        if (bottom && x < corner) || (left && y >= h - corner) {
            return HTBOTTOMLEFT;
        }
        if (bottom && x >= w - corner) || (right && y >= h - corner) {
            return HTBOTTOMRIGHT;
        }
        if left {
            return HTLEFT;
        }
        if right {
            return HTRIGHT;
        }
        if top {
            return HTTOP;
        }
        if bottom {
            return HTBOTTOM;
        }
    }
    // The clear strip above Mac toolbar controls moves the local window.
    // Preserve the actual toolbar buttons; Alt+drag works anywhere as well.
    if alt || (y < edge + 12 && x >= 90 && x < w - corner) {
        HTCAPTION
    } else {
        HTCLIENT
    }
}
pub fn outer_size(w: u32, h: u32, _dpi: u32) -> (i32, i32) {
    (w as i32, h as i32)
}
pub fn client_size(w: u32, h: u32, _dpi: u32) -> Size {
    Size {
        w: w.max(1),
        h: h.max(1),
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exact_viewport_and_corners_at_every_dpi() {
        for dpi in [96, 144, 192] {
            assert_eq!(outer_size(1234, 789, dpi), (1234, 789));
            assert_eq!(client_size(1234, 789, dpi), Size { w: 1234, h: 789 });
            assert_eq!(hit_at(999, 700, 1000, 800, dpi, false, false), HTRIGHT);
            assert_eq!(
                hit_at(997, 794, 1000, 800, dpi, false, false),
                HTBOTTOMRIGHT
            );
            assert_eq!(hit_at(300, 16, 1000, 800, dpi, false, false), HTCAPTION);
            assert_eq!(hit_at(30, 28, 1000, 800, dpi, false, false), HTCLIENT);
            assert_eq!(hit_at(300, 40, 1000, 800, dpi, false, false), HTCLIENT);
            assert_eq!(hit_at(300, 400, 1000, 800, dpi, false, true), HTCAPTION);
            assert_eq!(hit_at(999, 700, 1000, 800, dpi, true, false), HTCLIENT);
        }
    }
}

thread_local! {
    static LIMITS: std::cell::RefCell<std::collections::HashMap<isize, Size>> = std::cell::RefCell::new(std::collections::HashMap::new());
}
pub fn set_limit(hwnd: HWND, size: Option<Size>) {
    LIMITS.with(|limits| {
        let mut limits = limits.borrow_mut();
        if let Some(size) = size.filter(|s| s.w > 0 && s.h > 0) {
            limits.insert(hwnd.0 as isize, size);
        } else {
            limits.remove(&(hwnd.0 as isize));
        }
    });
}
pub fn apply_limit(hwnd: HWND, param: LPARAM) {
    use windows::Win32::Graphics::Gdi::{
        GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTONEAREST,
    };
    let info = unsafe { &mut *(param.0 as *mut MINMAXINFO) };
    let mut monitor = MONITORINFO {
        cbSize: std::mem::size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    if unsafe {
        GetMonitorInfoW(
            MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
            &mut monitor,
        )
        .as_bool()
    } {
        info.ptMaxPosition.x = monitor.rcWork.left - monitor.rcMonitor.left;
        info.ptMaxPosition.y = monitor.rcWork.top - monitor.rcMonitor.top;
        info.ptMaxSize.x = monitor.rcWork.right - monitor.rcWork.left;
        info.ptMaxSize.y = monitor.rcWork.bottom - monitor.rcWork.top;
    }
    let limit = LIMITS.with(|limits| limits.borrow().get(&(hwnd.0 as isize)).copied());
    if let Some(limit) = limit {
        let w = (limit.w.min(i32::MAX as u32) as i32).max(info.ptMinTrackSize.x);
        let h = (limit.h.min(i32::MAX as u32) as i32).max(info.ptMinTrackSize.y);
        info.ptMaxTrackSize.x = info.ptMaxTrackSize.x.min(w);
        info.ptMaxTrackSize.y = info.ptMaxTrackSize.y.min(h);
        info.ptMaxSize.x = info.ptMaxSize.x.min(w);
        info.ptMaxSize.y = info.ptMaxSize.y.min(h);
    }
}
