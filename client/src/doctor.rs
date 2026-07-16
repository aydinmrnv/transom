//! `doctor` — console-only health check for the Windows client.
//!
//! Reports, in order:
//!   1. D3D11 device creation (result, feature level, adapter name, VRAM)
//!   2. The process DPI-awareness context, to prove the embedded manifest took
//!      effect (we expect Per-Monitor V2)
//!   3. Every monitor: handle, physical bounds, DPI, scale factor, refresh rate
//!
//! No window is created — that is deliberate. DPI awareness is fixed at process
//! start by the manifest, so we can observe it without ever opening a window.

use std::process::ExitCode;

use windows::core::{Interface, PCWSTR};
use windows::Win32::Foundation::{BOOL, HMODULE, LPARAM, RECT};
use windows::Win32::Graphics::Direct3D::{
    D3D_DRIVER_TYPE_HARDWARE, D3D_FEATURE_LEVEL, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_11_1,
    D3D_FEATURE_LEVEL_12_0, D3D_FEATURE_LEVEL_12_1,
};
use windows::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, ID3D11Device, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_SDK_VERSION,
};
use windows::Win32::Graphics::Dxgi::IDXGIDevice;
use windows::Win32::Graphics::Gdi::{
    EnumDisplayMonitors, EnumDisplaySettingsW, GetMonitorInfoW, DEVMODEW, ENUM_CURRENT_SETTINGS,
    HDC, HMONITOR, MONITORINFO, MONITORINFOEXW,
};
use windows::Win32::UI::HiDpi::{
    AreDpiAwarenessContextsEqual, GetDpiForMonitor, GetThreadDpiAwarenessContext,
    DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
    DPI_AWARENESS_CONTEXT_SYSTEM_AWARE, DPI_AWARENESS_CONTEXT_UNAWARE, MDT_EFFECTIVE_DPI,
};

/// The primary monitor sets this bit in `MONITORINFO::dwFlags`. windows-rs does
/// not always emit it as a constant, so define it locally.
const MONITORINFOF_PRIMARY: u32 = 0x0000_0001;

pub fn run() -> ExitCode {
    println!("transom-client doctor");
    println!("=====================\n");

    let d3d_ok = report_d3d11();
    report_dpi_awareness();
    report_monitors();

    println!();
    if d3d_ok {
        println!("Summary: ready.");
        ExitCode::SUCCESS
    } else {
        println!("Summary: NOT ready — D3D11 device creation failed.");
        ExitCode::FAILURE
    }
}

// ---------------------------------------------------------------------------
// Direct3D 11
// ---------------------------------------------------------------------------

fn report_d3d11() -> bool {
    println!("Direct3D 11");
    println!("-----------");

    let levels = [
        D3D_FEATURE_LEVEL_12_1,
        D3D_FEATURE_LEVEL_12_0,
        D3D_FEATURE_LEVEL_11_1,
        D3D_FEATURE_LEVEL_11_0,
    ];

    let mut device: Option<ID3D11Device> = None;
    let mut level = D3D_FEATURE_LEVEL_11_0;

    let result = unsafe {
        D3D11CreateDevice(
            None,
            D3D_DRIVER_TYPE_HARDWARE,
            HMODULE::default(),
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            Some(&levels),
            D3D11_SDK_VERSION,
            Some(&mut device),
            Some(&mut level),
            None,
        )
    };

    match result {
        Ok(()) => {
            println!("  device creation: OK");
            println!("  feature level:   {}", feature_level_name(level));
            if let Some(device) = device {
                match adapter_info(&device) {
                    Ok((name, vram)) => {
                        println!("  adapter:         {name}");
                        println!(
                            "  dedicated VRAM:  {:.2} GB ({vram} bytes)",
                            vram as f64 / 1_000_000_000.0
                        );
                    }
                    Err(err) => println!("  adapter query:   FAILED ({err})"),
                }
            }
            true
        }
        Err(err) => {
            println!("  device creation: FAILED ({err})");
            false
        }
    }
}

/// Walk device -> IDXGIDevice -> adapter to read the adapter description.
fn adapter_info(device: &ID3D11Device) -> windows::core::Result<(String, usize)> {
    unsafe {
        let dxgi: IDXGIDevice = device.cast()?;
        let adapter = dxgi.GetAdapter()?;
        let desc = adapter.GetDesc()?;
        Ok((wide_to_string(&desc.Description), desc.DedicatedVideoMemory))
    }
}

fn feature_level_name(level: D3D_FEATURE_LEVEL) -> String {
    match level {
        D3D_FEATURE_LEVEL_12_1 => "12_1".to_string(),
        D3D_FEATURE_LEVEL_12_0 => "12_0".to_string(),
        D3D_FEATURE_LEVEL_11_1 => "11_1".to_string(),
        D3D_FEATURE_LEVEL_11_0 => "11_0".to_string(),
        other => format!("0x{:04X}", other.0),
    }
}

// ---------------------------------------------------------------------------
// DPI awareness (proves the manifest took effect)
// ---------------------------------------------------------------------------

fn report_dpi_awareness() {
    println!("\nDPI awareness");
    println!("-------------");

    unsafe {
        let ctx = GetThreadDpiAwarenessContext();

        let label = if AreDpiAwarenessContextsEqual(ctx, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
            .as_bool()
        {
            "Per-Monitor V2"
        } else if AreDpiAwarenessContextsEqual(ctx, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE)
            .as_bool()
        {
            "Per-Monitor V1"
        } else if AreDpiAwarenessContextsEqual(ctx, DPI_AWARENESS_CONTEXT_SYSTEM_AWARE).as_bool() {
            "System aware"
        } else if AreDpiAwarenessContextsEqual(ctx, DPI_AWARENESS_CONTEXT_UNAWARE).as_bool() {
            "Unaware"
        } else {
            "Unknown"
        };

        println!("  process context: {label}");

        let is_v2 =
            AreDpiAwarenessContextsEqual(ctx, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2).as_bool();
        if is_v2 {
            println!("  manifest:        OK (Per-Monitor V2 declared at load time)");
        } else {
            println!("  manifest:        WARNING — expected Per-Monitor V2 from the manifest");
        }
    }
}

// ---------------------------------------------------------------------------
// Monitors
// ---------------------------------------------------------------------------

unsafe extern "system" fn monitor_enum_proc(
    monitor: HMONITOR,
    _hdc: HDC,
    _clip: *mut RECT,
    lparam: LPARAM,
) -> BOOL {
    let monitors = &mut *(lparam.0 as *mut Vec<HMONITOR>);
    monitors.push(monitor);
    BOOL(1)
}

fn report_monitors() {
    println!("\nMonitors");
    println!("--------");

    let mut monitors: Vec<HMONITOR> = Vec::new();
    unsafe {
        let _ = EnumDisplayMonitors(
            HDC::default(),
            None,
            Some(monitor_enum_proc),
            LPARAM(&mut monitors as *mut _ as isize),
        );
    }

    if monitors.is_empty() {
        println!("  (none enumerated)");
        return;
    }

    for (i, monitor) in monitors.iter().enumerate() {
        unsafe {
            let mut info = MONITORINFOEXW::default();
            info.monitorInfo.cbSize = std::mem::size_of::<MONITORINFOEXW>() as u32;

            let ok = GetMonitorInfoW(
                *monitor,
                &mut info as *mut MONITORINFOEXW as *mut MONITORINFO,
            )
            .as_bool();
            if !ok {
                println!("  monitor {i}: GetMonitorInfoW failed");
                continue;
            }

            let rect = info.monitorInfo.rcMonitor;
            let is_primary = (info.monitorInfo.dwFlags & MONITORINFOF_PRIMARY) != 0;

            let mut dpi_x = 0u32;
            let mut dpi_y = 0u32;
            let dpi = match GetDpiForMonitor(*monitor, MDT_EFFECTIVE_DPI, &mut dpi_x, &mut dpi_y) {
                Ok(()) => dpi_x,
                Err(_) => 96,
            };
            let scale = dpi as f64 / 96.0;

            let device = wide_to_string(&info.szDevice);
            let hz = refresh_hz(&info.szDevice);

            println!(
                "  monitor {i}{}",
                if is_primary { " (primary)" } else { "" }
            );
            println!("    handle:  {monitor:?}");
            println!("    device:  {device}");
            println!(
                "    bounds:  ({}, {}) {} x {} px",
                rect.left,
                rect.top,
                rect.right - rect.left,
                rect.bottom - rect.top
            );
            println!("    dpi:     {dpi} (scale {scale:.2}x)");
            println!("    refresh: {hz} Hz");
        }
    }
}

/// Current refresh rate for a device via `EnumDisplaySettingsW`, or 0 if unknown.
fn refresh_hz(device: &[u16]) -> u32 {
    unsafe {
        let mut mode = DEVMODEW {
            dmSize: std::mem::size_of::<DEVMODEW>() as u16,
            ..Default::default()
        };
        if EnumDisplaySettingsW(PCWSTR(device.as_ptr()), ENUM_CURRENT_SETTINGS, &mut mode).as_bool()
        {
            mode.dmDisplayFrequency
        } else {
            0
        }
    }
}

/// Convert a NUL-terminated (or full) UTF-16 slice to a `String`.
fn wide_to_string(wide: &[u16]) -> String {
    let end = wide.iter().position(|&c| c == 0).unwrap_or(wide.len());
    String::from_utf16_lossy(&wide[..end])
}
