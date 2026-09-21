//! One proxy window: a native, borderless-but-resizable Win32 window that stands
//! in for a single Mac window (keyed by its `WindowId`), with its own flip-model
//! swapchain.
//!
//! The 1:1 guarantee lives in two rules this type enforces:
//!  * On every `WM_SIZE`, `ResizeBuffers` to the **exact physical client rect**
//!    (never a logical size), so swapchain size == client rect always.
//!  * The quad is point-sampled from the window's source sub-rect. When the
//!    window's client size equals the source size (the steady state after a
//!    snap), that is a pixel-exact blit; during a live drag the source is
//!    transiently stretched into the new size (the accepted resample, snapped
//!    away on `WM_EXITSIZEMOVE`).

use std::time::{Duration, Instant};

use windows::Win32::Foundation::HWND;
use windows::Win32::Graphics::Direct3D11::{ID3D11RenderTargetView, ID3D11Texture2D};
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_UNKNOWN;
use windows::Win32::Graphics::Dxgi::{
    IDXGISwapChain1, DXGI_PRESENT_DO_NOT_WAIT, DXGI_SWAP_CHAIN_FLAG,
};

use super::gpu::{Gpu, RenderMode, SourceTexture};
use crate::wire::Rect;

/// Client-side throttle for `Live` resize requests (~10Hz; protocol.md §5). The
/// host also coalesces, but there's no point flooding the wire from `WM_SIZING`.
const LIVE_RESIZE_INTERVAL: Duration = Duration::from_millis(100);

pub struct Proxy {
    pub hwnd: HWND,
    swapchain: IDXGISwapChain1,
    rtv: Option<ID3D11RenderTargetView>,
    /// Physical client size == swapchain buffer size. The invariant the M0 probe
    /// checks.
    pub width: u32,
    pub height: u32,
    /// The window's sub-rect of the shared VDS texture (physical pixels).
    pub source: Rect,
    /// True between `WM_ENTERSIZEMOVE` and `WM_EXITSIZEMOVE`.
    pub in_size_move: bool,
    pub resizing: bool,
    pub host_resize_pending: bool,
    pub resize_sync: crate::resize_sync::ResizeSync,
    pub dirty: bool,
    last_live_send: Option<Instant>,
    /// M0 diagnostic: draw a 1px checkerboard instead of sampling the stream.
    pub checkerboard: bool,
}

impl Proxy {
    pub fn new(
        gpu: &Gpu,
        hwnd: HWND,
        source: Rect,
        checkerboard: bool,
    ) -> windows::core::Result<Proxy> {
        let swapchain = gpu.create_swapchain(hwnd, source.w, source.h)?;
        let mut proxy = Proxy {
            hwnd,
            swapchain,
            rtv: None,
            width: source.w,
            height: source.h,
            source,
            in_size_move: false,
            resizing: false,
            host_resize_pending: false,
            resize_sync: Default::default(),
            dirty: true,
            last_live_send: None,
            checkerboard,
        };
        proxy.ensure_rtv(gpu)?;
        Ok(proxy)
    }

    /// (Re)create the render-target view over the current back buffer.
    fn ensure_rtv(&mut self, gpu: &Gpu) -> windows::core::Result<()> {
        if self.rtv.is_some() {
            return Ok(());
        }
        let backbuffer: ID3D11Texture2D = unsafe { self.swapchain.GetBuffer(0)? };
        let mut rtv = None;
        unsafe {
            gpu.device
                .CreateRenderTargetView(&backbuffer, None, Some(&mut rtv))?;
        }
        self.rtv = rtv;
        Ok(())
    }

    /// Resize the swapchain to an exact physical client rect (from `WM_SIZE`).
    /// Releases the RTV first, as `ResizeBuffers` requires no outstanding
    /// references to the back buffers.
    pub fn resize_swapchain(&mut self, gpu: &Gpu, width: u32, height: u32) {
        if width == 0 || height == 0 {
            return; // minimized; nothing to size to
        }
        if width == self.width && height == self.height && self.rtv.is_some() {
            self.report_pixel_size();
            return;
        }
        self.dirty = true;
        // The immediate context also retains the bound RTV after drawing. Drop
        // that reference before ResizeBuffers, not only our Rust COM handle.
        unsafe {
            gpu.context.OMSetRenderTargets(None, None);
        }
        self.rtv = None;
        let hr = unsafe {
            self.swapchain.ResizeBuffers(
                0, // keep buffer count
                width,
                height,
                DXGI_FORMAT_UNKNOWN, // keep format
                DXGI_SWAP_CHAIN_FLAG(0),
            )
        };
        if hr.is_ok() {
            self.width = width;
            self.height = height;
        }
        let _ = self.ensure_rtv(gpu);
        self.report_pixel_size();
    }

    fn report_pixel_size(&self) {
        if !self.checkerboard && std::env::var_os("TRANSOM_GEOMETRY_TRACE").is_none() {
            return;
        }
        use windows::Win32::Foundation::RECT;
        use windows::Win32::UI::WindowsAndMessaging::GetClientRect;
        let mut rect = RECT::default();
        unsafe {
            if GetClientRect(self.hwnd, &mut rect).is_ok() {
                if let Ok(desc) = self.swapchain.GetDesc1() {
                    let matches = desc.Width == (rect.right - rect.left) as u32
                        && desc.Height == (rect.bottom - rect.top) as u32;
                    println!(
                        "pixel-check: DPI={} physical={}x{} swapchain={}x{} {}",
                        super::dpi::dpi_for_window(self.hwnd),
                        rect.right - rect.left,
                        rect.bottom - rect.top,
                        desc.Width,
                        desc.Height,
                        if matches { "PASS" } else { "FAIL" }
                    );
                }
            }
        }
    }

    /// Draw one frame and present. `source_tex` is the shared decoded VDS texture;
    /// `None` (or checkerboard mode) draws a diagnostic instead.
    pub fn render(&mut self, gpu: &Gpu, source_tex: Option<&SourceTexture>, independent: bool) {
        if !self.dirty {
            return;
        }
        if self.ensure_rtv(gpu).is_err() {
            return;
        }
        let Some(rtv) = self.rtv.as_ref() else {
            return;
        };

        // While waiting for a resize acknowledgement, crop/letterbox at native
        // scale. Only an actual interactive resize may stretch the pixels.
        let source = if independent {
            let (w, h) = source_tex
                .map(|t| (t.width.min(self.source.w), t.height.min(self.source.h)))
                .unwrap_or((self.source.w, self.source.h));
            Rect { x: 0, y: 0, w, h }
        } else {
            self.source
        };
        let stretch = self.in_size_move && self.resizing;
        let draw_w = if stretch || self.checkerboard {
            self.width
        } else {
            self.width.min(source.w).max(1)
        };
        let draw_h = if stretch || self.checkerboard {
            self.height
        } else {
            self.height.min(source.h).max(1)
        };
        let crop_w = if stretch { source.w } else { draw_w };
        let crop_h = if stretch { source.h } else { draw_h };
        if draw_w != self.width || draw_h != self.height {
            unsafe {
                gpu.context
                    .ClearRenderTargetView(rtv, &[0.08, 0.10, 0.14, 1.0]);
            }
        }
        let mode = if self.checkerboard {
            RenderMode::Checkerboard
        } else if let Some(tex) = source_tex {
            RenderMode::Source {
                uv_rect: tex.uv_rect(source.x, source.y, crop_w, crop_h),
            }
        } else {
            RenderMode::Waiting
        };

        gpu.draw(rtv, draw_w, draw_h, mode, source_tex.map(|t| &t.srv));

        unsafe {
            // Do not let DWM backpressure block the Win32 UI thread. If the flip
            // queue is full, keeping the already-queued newest frame is better
            // than making native window movement wait for a redundant present.
            self.dirty = self.swapchain.Present(0, DXGI_PRESENT_DO_NOT_WAIT).is_err();
        }
    }

    /// The host reported this window's ACTUAL geometry (I-4). Update the source
    /// sub-rect used for sampling. Returns whether the source *size* changed,
    /// which the caller uses to decide whether to snap the OS window to match.
    pub fn set_source(&mut self, source: Rect) -> bool {
        let size_changed = self.source.w != source.w || self.source.h != source.h;
        self.dirty |= self.source != source;
        self.source = source;
        size_changed
    }

    /// Whether enough time has passed to send another `Live` resize request, and
    /// records the send if so. Keeps the wire near ~10Hz during a drag.
    pub fn should_send_live(&mut self, now: Instant) -> bool {
        match self.last_live_send {
            Some(prev) if now.duration_since(prev) < LIVE_RESIZE_INTERVAL => false,
            _ => {
                self.last_live_send = Some(now);
                true
            }
        }
    }

    pub fn begin_size_move(&mut self) {
        self.resize_sync.begin();
        self.in_size_move = true;
        self.resizing = false;
        self.last_live_send = None;
    }

    pub fn end_size_move(&mut self) {
        self.dirty = true;
        self.in_size_move = false;
        self.resizing = false;
        self.last_live_send = None;
    }
}
