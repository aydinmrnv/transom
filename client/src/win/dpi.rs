//! DPI helpers.
//!
//! The process is Per-Monitor-V2 aware via the embedded manifest (`build.rs`), so
//! every window and GDI coordinate the client ever touches is already in physical
//! pixels — which is the whole point (invariants I-2). These helpers just read the
//! effective DPI so the diagnostics can report the scale factor, and so
//! `WM_DPICHANGED` can be handled by trusting the suggested physical rect.

use windows::Win32::Foundation::HWND;
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
