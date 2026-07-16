//! DPI helpers.
//!
//! The process is Per-Monitor-V2 aware via the embedded manifest (`build.rs`), so
//! every window and GDI coordinate the client ever touches is already in physical
//! pixels — which is the whole point (invariants I-2). These helpers just read the
//! effective DPI so the diagnostics can report the scale factor, and so
//! `WM_DPICHANGED` can be handled by trusting the suggested physical rect.

use windows::Win32::Foundation::{HWND, POINT, RECT};
use windows::Win32::Graphics::Gdi::{
    GetMonitorInfoW, MonitorFromPoint, HMONITOR, MONITORINFO, MONITOR_DEFAULTTOPRIMARY,
};
use windows::Win32::UI::HiDpi::GetDpiForWindow;

/// The effective DPI of the monitor a window is on. 96 is 100%.
pub fn dpi_for_window(hwnd: HWND) -> u32 {
    // GetDpiForWindow never fails for a valid HWND; 0 would mean an invalid
    // window, so fall back to the 96 baseline rather than divide by it later.
    let dpi = unsafe { GetDpiForWindow(hwnd) };
    if dpi == 0 {
        96
    } else {
        dpi
    }
}

/// Scale factor for a DPI value (1.0 at 96 DPI / 100%).
pub fn scale_for_dpi(dpi: u32) -> f64 {
    dpi as f64 / 96.0
}

/// The work area (screen minus taskbar) in physical pixels of the monitor
/// containing the point `(x, y)`, falling back to the primary monitor. Used to fit
/// a proxy window to the client's screen: a macOS window's source rect is in the
/// host's physical pixels (Retina 2x, so often larger than the whole client
/// monitor), and creating a borderless window that big leaves it off-screen and
/// with no title bar to grab (invariants I-2 keep everything physical, so there is
/// no scaling to save us here).
pub fn work_area_at(x: i32, y: i32) -> RECT {
    unsafe {
        let monitor: HMONITOR = MonitorFromPoint(POINT { x, y }, MONITOR_DEFAULTTOPRIMARY);
        let mut info = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if GetMonitorInfoW(monitor, &mut info).as_bool() {
            info.rcWork
        } else {
            // No monitor info: fall back to a sane 1080p so callers still clamp to
            // *something* rather than trusting a Retina-sized source.
            RECT {
                left: 0,
                top: 0,
                right: 1920,
                bottom: 1080,
            }
        }
    }
}
