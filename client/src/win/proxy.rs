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
            return;
        }
        self.rtv = None; // drop the only back-buffer reference
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
    }

    /// Draw one frame and present. `source_tex` is the shared decoded VDS texture;
    /// `None` (or checkerboard mode) draws a diagnostic instead.
    pub fn render(&mut self, gpu: &Gpu, source_tex: Option<&SourceTexture>) {
        if self.ensure_rtv(gpu).is_err() {
            return;
        }
        let Some(rtv) = self.rtv.as_ref() else {
            return;
        };

        let mode = if self.checkerboard {
            RenderMode::Checkerboard
        } else if let Some(tex) = source_tex {
            RenderMode::Source {
                uv_rect: tex.uv_rect(self.source.x, self.source.y, self.source.w, self.source.h),
            }
        } else {
            RenderMode::Waiting
        };

        gpu.draw(rtv, self.width, self.height, mode, source_tex.map(|t| &t.srv));

        unsafe {
            // Do not let DWM backpressure block the Win32 UI thread. If the flip
            // queue is full, keeping the already-queued newest frame is better
            // than making native window movement wait for a redundant present.
            let _ = self.swapchain.Present(0, DXGI_PRESENT_DO_NOT_WAIT);
        }
    }

    /// The host reported this window's ACTUAL geometry (I-4). Update the source
    /// sub-rect used for sampling. Returns whether the source *size* changed,
    /// which the caller uses to decide whether to snap the OS window to match.
    pub fn set_source(&mut self, source: Rect) -> bool {
        let size_changed = self.source.w != source.w || self.source.h != source.h;
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
        self.in_size_move = true;
        self.last_live_send = None;
    }

    pub fn end_size_move(&mut self) {
        self.in_size_move = false;
        self.last_live_send = None;
    }
}
