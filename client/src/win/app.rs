//! The application: window class, the shared window procedure, the message pump,
//! and the proxy lifecycle driven by the control stream.
//!
//! Threading model: Win32 is single-threaded here. The `Session`'s reader threads
//! decode the protocol and post `SessionEvent`s onto an `mpsc`; the pump drains
//! that channel between message batches and turns `ModelEvent`s into proxy
//! windows. The window procedure reaches back into the `App` through a raw pointer
//! stashed in each window's `GWLP_USERDATA` — the standard Win32-in-Rust pattern,
//! sound because the pump never holds a Rust borrow of the `App` across
//! `DispatchMessageW`.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::{
    DwmSetWindowAttribute, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetWindowLongPtrW,
    LoadCursorW, MsgWaitForMultipleObjectsEx, PeekMessageW, PostQuitMessage, RegisterClassW,
    SetWindowLongPtrW, SetWindowPos, SetWindowTextW, ShowWindow, TranslateMessage, CREATESTRUCTW,
    GWLP_USERDATA, IDC_ARROW, MSG, MWMO_INPUTAVAILABLE, PM_REMOVE, QS_ALLINPUT, SWP_NOACTIVATE,
    SWP_NOMOVE, SWP_NOZORDER, SW_SHOW, WM_ACTIVATE, WM_CLOSE, WM_DESTROY, WM_DPICHANGED,
    WM_ENTERSIZEMOVE, WM_EXITSIZEMOVE, WM_KEYDOWN, WM_KEYUP, WM_LBUTTONDOWN, WM_LBUTTONUP,
    WM_MBUTTONDOWN, WM_MBUTTONUP, WM_MOUSEHWHEEL, WM_MOUSEMOVE, WM_MOUSEWHEEL, WM_NCCALCSIZE,
    WM_NCCREATE, WM_PAINT, WM_QUIT, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_SIZE, WM_SIZING,
    WM_SYSKEYDOWN, WM_SYSKEYUP, WNDCLASSW, WS_OVERLAPPEDWINDOW,
};

use super::connect::{Action, Dashboard};
use super::gpu::{Gpu, SourceTexture};
use crate::connections::Connection;
use std::sync::mpsc::{self, Receiver};
type ConnectResult = Result<(Connection, Session, Receiver<SessionEvent>), String>;
use super::input;
use super::proxy::Proxy;
use crate::model::ModelEvent;
use crate::session::{Session, SessionEvent, VideoEvent};
use crate::wire::{ClientMessage, InputEvent, Rect, ResizePhase, Size};

#[cfg(windows)]
use super::decode::DecoderWorker;

const CLASS_NAME: PCWSTR = w!("TransomProxyWindow");

/// Reconnect backoff after the control channel drops.
const RECONNECT_DELAY: Duration = Duration::from_secs(2);

pub struct AppConfig {
    pub host: String,
    pub control_port: u16,
    pub video_port: Option<u16>,
    pub checkerboard: bool,
}

pub struct App {
    gpu: Gpu,
    cfg: AppConfig,
    dashboard: Dashboard,
    selected: Option<Connection>,
    connecting: Option<Receiver<ConnectResult>>,
    active: bool,
    notice: Option<String>,
    session: Option<Session>,
    rx: Option<std::sync::mpsc::Receiver<SessionEvent>>,
    proxies: HashMap<u64, Proxy>,
    hwnd_to_id: HashMap<isize, u64>,
    source: Option<SourceTexture>,
    decoder: Option<DecoderWorker>,
    vds: Option<Size>,
    cascade: u32,
    /// Latest unsent hover move per proxy. High-polling-rate mice can emit far
    /// more messages than the control channel or Mac cursor needs; one per pump
    /// preserves the newest position without blocking the Win32 wndproc.
    pending_mouse_moves: HashMap<u64, InputEvent>,
    reconnect_at: Option<Instant>,
    now_epoch: Instant,
    /// Video-health counters. If access units keep arriving but none ever decode
    /// (the tell-tale of the in-box HEVC decoder rejecting the host's 4:4:4 10-bit
    /// stream), we warn once instead of silently showing the placeholder forever.
    video_in: u64,
    video_decoded: u64,
    warned_no_decode: bool,
}

impl App {
    pub fn new(gpu: Gpu, cfg: Option<AppConfig>, dashboard: Dashboard) -> App {
        let active = cfg.is_some();
        let cfg = cfg.unwrap_or(AppConfig {
            host: String::new(),
            control_port: crate::wire::DEFAULT_CONTROL_PORT,
            video_port: Some(crate::wire::DEFAULT_VIDEO_PORT),
            checkerboard: false,
        });
        let selected = if active {
            Connection::manual(
                &cfg.host,
                &cfg.control_port.to_string(),
                &cfg.video_port.map(|p| p.to_string()).unwrap_or_default(),
            )
            .ok()
        } else {
            None
        };
        App {
            gpu,
            cfg,
            dashboard,
            selected,
            connecting: None,
            active,
            notice: None,
            session: None,
            rx: None,
            proxies: HashMap::new(),
            hwnd_to_id: HashMap::new(),
            source: None,
            decoder: None,
            vds: None,
            cascade: 0,
            pending_mouse_moves: HashMap::new(),
            reconnect_at: None,
            now_epoch: Instant::now(),
            video_in: 0,
            video_decoded: 0,
            warned_no_decode: false,
        }
    }

    /// Milliseconds since the app started — the client's monotonic `ts` clock
    /// (protocol.md §4; opaque to the host).
    fn now_ms(&self) -> u64 {
        self.now_epoch.elapsed().as_millis() as u64
    }

    /// Attempt to (re)connect the session. Failures are logged and retried on the
    /// backoff; a live host is not required for the window manager to be up.
    fn connect(&mut self) {
        if !self.active || self.connecting.is_some() {
            return;
        }
        let Some(mut connection) = self.selected.clone() else {
            return;
        };
        self.dashboard
            .set_status(&format!("Connecting to {}…", connection.name), true);
        let (tx, rx) = mpsc::channel();
        self.connecting = Some(rx);
        std::thread::spawn(move || {
            let result = (|| {
                // Rediscover saved Bonjour identities before using an endpoint:
                // a DHCP lease may now belong to a different machine.
                if !connection.id.starts_with("manual:") {
                    connection = crate::discovery::scan()
                        .map_err(|e| e.to_string())?
                        .into_iter()
                        .find(|c| c.id == connection.id)
                        .ok_or(
                            "Mac is offline or not sharing. Open Transom Host and press Start.",
                        )?;
                }
                let (session, events) = Session::connect(
                    &connection.host,
                    connection.control_port,
                    connection.video_port,
                )
                .map_err(|e| e.to_string())?;
                Ok((connection, session, events))
            })();
            // If the user cancelled, dropping the failed delivery closes sockets.
            let _ = tx.send(result);
        });
    }

    fn poll_dashboard(&mut self) {
        match self.dashboard.tick() {
            Some(Action::Connect(c)) => {
                self.disconnect();
                self.cfg.host = c.host.clone();
                self.cfg.control_port = c.control_port;
                self.cfg.video_port = c.video_port;
                self.selected = Some(c);
                self.active = true;
                self.connect();
            }
            Some(Action::Disconnect) => {
                self.disconnect();
                self.dashboard
                    .set_status("Disconnected. Your Mac apps are still open.", false);
            }
            None => {}
        }
        let result = self.connecting.as_ref().and_then(|rx| rx.try_recv().ok());
        if let Some(result) = result {
            self.connecting = None;
            match result {
                Ok((c, session, rx)) => {
                    self.cfg.host = c.host.clone();
                    self.cfg.control_port = c.control_port;
                    self.cfg.video_port = c.video_port;
                    self.selected = Some(c.clone());
                    self.session = Some(session);
                    self.rx = Some(rx);
                    self.reconnect_at = None;
                    self.notice = None;
                    self.dashboard.remember(c);
                    self.update_status();
                }
                Err(e) => {
                    self.dashboard
                        .set_status(&format!("Could not connect: {e} Retrying…"), true);
                    self.reconnect_at = Some(Instant::now() + RECONNECT_DELAY);
                }
            }
        }
    }

    fn update_status(&mut self) {
        if let Some(c) = &self.selected {
            let state = if let Some(n) = &self.notice {
                n.clone()
            } else if self.cfg.video_port.is_none() {
                "Control only · video is off".into()
            } else if self.video_decoded > 0 {
                "Streaming".into()
            } else {
                "Waiting for video…".into()
            };
            self.dashboard.set_status(
                &format!("{} · {} · {} window(s)", c.name, state, self.proxies.len()),
                true,
            );
        }
    }

    fn clear_session(&mut self) {
        if let Some(s) = self.session.take() {
            s.shutdown();
        }
        self.rx = None;
        self.decoder = None;
        self.source = None;
        self.vds = None;
        self.video_in = 0;
        self.video_decoded = 0;
        self.warned_no_decode = false;
        self.notice = None;
        let ids: Vec<_> = self.proxies.keys().copied().collect();
        for id in ids {
            self.destroy_proxy(id);
        }
        self.pending_mouse_moves.clear();
        self.cascade = 0;
    }

    fn disconnect(&mut self) {
        self.active = false;
        self.connecting = None;
        self.reconnect_at = None;
        self.clear_session();
    }

    /// Send a message to the host, if connected.
    fn send(&self, msg: &ClientMessage) {
        if let Some(s) = &self.session {
            if let Err(e) = s.send(msg) {
                eprintln!("send failed: {e}");
            }
        }
    }

    // --- session event handling -----------------------------------------

    fn drain_session(&mut self, app_ptr: *mut App) {
        if !self.active {
            return;
        }
        // Reconnect if it's time; network work never blocks the Win32 pump.
        if self.session.is_none() {
            if self
                .reconnect_at
                .map(|t| Instant::now() >= t)
                .unwrap_or(true)
            {
                self.connect();
            }
            return;
        }

        // Move the receiver out to avoid borrowing self while we mutate it.
        let Some(rx) = self.rx.take() else { return };
        let mut disconnected = false;
        loop {
            match rx.try_recv() {
                Ok(SessionEvent::Control(ev)) => self.apply_model_event(ev, app_ptr),
                Ok(SessionEvent::Video(v)) => self.apply_video(v),
                Ok(SessionEvent::ControlClosed(reason)) => {
                    self.dashboard.set_status(
                        &format!("Connection lost{}. Retrying…", suffix(reason)),
                        true,
                    );
                    disconnected = true;
                    break;
                }
                Ok(SessionEvent::VideoClosed(reason)) => {
                    self.dashboard.set_status(
                        &format!("Video unavailable{}. Retrying…", suffix(reason)),
                        true,
                    );
                    // A video channel can die independently while control stays
                    // open. Reconnect the whole session so the host sends a fresh
                    // hvcC config and the decoder can recover without restarting
                    // the app.
                    disconnected = true;
                    break;
                }
                Err(std::sync::mpsc::TryRecvError::Empty) => break,
                Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                    disconnected = true;
                    break;
                }
            }
        }
        if disconnected {
            self.clear_session();
            self.reconnect_at = Some(Instant::now() + RECONNECT_DELAY);
        } else {
            self.rx = Some(rx);
        }
    }

    fn apply_model_event(&mut self, ev: ModelEvent, app_ptr: *mut App) {
        match ev {
            ModelEvent::Connected { vds } => {
                self.vds = Some(vds);
                self.ensure_source(vds);
            }
            ModelEvent::WindowAdded(w) => {
                if !self.proxies.contains_key(&w.id) {
                    if let Err(e) = self.create_proxy(w.id, w.source, &w.title, app_ptr) {
                        eprintln!("failed to create proxy for window {}: {e}", w.id);
                    }
                }
            }
            ModelEvent::WindowRectChanged { id, source, .. } => {
                self.update_source_rect(id, source);
            }
            ModelEvent::WindowTitleChanged { id, title } => self.update_title(id, &title),
            ModelEvent::WindowFocused { .. } => {}
            ModelEvent::WindowRemoved { id } => self.destroy_proxy(id),
            ModelEvent::Resynced { removed } => {
                for id in removed {
                    self.destroy_proxy(id);
                }
            }
            ModelEvent::HostError { code, message } => {
                self.notice = Some(format!("Host error {code}: {message}"));
            }
        }
        self.update_status();
    }

    fn apply_video(&mut self, v: VideoEvent) {
        match v {
            VideoEvent::Config { hvcc } => {
                if let Some(vds) = self.vds {
                    match DecoderWorker::start(hvcc, vds.w, vds.h) {
                        Ok(d) => self.decoder = Some(d),
                        Err(e) => eprintln!("failed to start decoder worker: {e}"),
                    }
                }
            }
            VideoEvent::Frame { data, keyframe, .. } => {
                self.video_in += 1;
                if let Some(decoder) = self.decoder.as_ref() {
                    decoder.submit(data, keyframe);
                }
                // Access units are arriving but nothing has decoded. The usual cause
                // is the in-box Media Foundation HEVC decoder refusing the host's
                // 4:4:4 10-bit stream (it tops out at Main10 4:2:0). Say so once, so
                // the placeholder checkerboard isn't a silent mystery.
                if !self.warned_no_decode && self.video_decoded == 0 && self.video_in >= 120 {
                    self.warned_no_decode = true;
                    self.notice=Some("Video cannot be decoded. Set the Mac to HEVC 4:2:0 and check the Windows HEVC decoder.".into());
                    self.update_status();
                    eprintln!(
                        "video: received {} access units but decoded 0 frames — the window \
                         will stay on the placeholder. The in-box HEVC decoder likely can't \
                         handle the host's 4:4:4 10-bit stream (decoder init {}).",
                        self.video_in,
                        if self.decoder.is_some() {
                            "worker started, but no output completed"
                        } else {
                            "failed; see the earlier 'decoder init failed' line"
                        }
                    );
                }
            }
        }
    }

    /// Upload at most the newest completed decode. The expensive hardware-decode
    /// drain and NV12→BGRA conversion happen on `transom-decode`; this UI-thread
    /// step is only the final D3D texture update.
    fn poll_decoder(&mut self) {
        let frame = self.decoder.as_ref().and_then(DecoderWorker::take_frame);
        if let (Some(bgra), Some(source)) = (frame, self.source.as_ref()) {
            source.update_bgra(&self.gpu, &bgra);
            self.video_decoded += 1;
            if self.video_decoded == 1 {
                self.notice = None;
                self.update_status();
            }
        }
    }

    fn ensure_source(&mut self, vds: Size) {
        let need_new = match &self.source {
            Some(s) => s.width != vds.w || s.height != vds.h,
            None => true,
        };
        if need_new {
            match SourceTexture::new(&self.gpu, vds.w, vds.h) {
                Ok(t) => self.source = Some(t),
                Err(e) => eprintln!("source texture creation failed: {e}"),
            }
        }
    }

    // --- proxy lifecycle -------------------------------------------------

    fn create_proxy(
        &mut self,
        id: u64,
        source: Rect,
        title: &str,
        app_ptr: *mut App,
    ) -> windows::core::Result<()> {
        let instance = unsafe { GetModuleHandleW(None)? };
        // Cascade the initial desktop position so windows don't stack exactly.
        let offset = (self.cascade % 8) * 48;
        self.cascade += 1;
        let spawn_x = 40 + offset as i32;
        let spawn_y = 40 + offset as i32;

        // Fit an oversized Retina source to a visibly windowed target. The helper
        // preserves exact size whenever it already fits and preserves aspect ratio
        // when it does not; after creation we ask the host to relayout to this
        // physical size so the transient fit snaps back to 1:1.
        let wa = super::dpi::work_area_at(spawn_x, spawn_y);
        let fitted = crate::window_fit::initial_proxy_size(
            Size {
                w: source.w,
                h: source.h,
            },
            Size {
                w: (wa.right - wa.left).max(1) as u32,
                h: (wa.bottom - wa.top).max(1) as u32,
            },
        );
        let win_w = fitted.w;
        let win_h = fitted.h;
        let clamped = win_w != source.w || win_h != source.h;
        let x = spawn_x.min(wa.right - win_w as i32).max(wa.left);
        let y = spawn_y.min(wa.bottom - win_h as i32).max(wa.top);

        let title_text = if title.trim().is_empty() {
            "Transom"
        } else {
            title
        };
        let title_w: Vec<u16> = title_text
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let hwnd = unsafe {
            CreateWindowExW(
                Default::default(),
                CLASS_NAME,
                PCWSTR(title_w.as_ptr()),
                WS_OVERLAPPEDWINDOW,
                x,
                y,
                win_w as i32,
                win_h as i32,
                None,
                None,
                HINSTANCE(instance.0),
                Some(app_ptr as *const _),
            )?
        };

        // Rounded corners to eventually match the macOS radius (the region trick
        // for true alpha comes later; HEVC has no alpha, so corners arrive opaque).
        unsafe {
            let pref = DWMWCP_ROUND;
            let _ = DwmSetWindowAttribute(
                hwnd,
                DWMWA_WINDOW_CORNER_PREFERENCE,
                &pref as *const _ as *const _,
                std::mem::size_of_val(&pref) as u32,
            );
        }

        let mut proxy = Proxy::new(&self.gpu, hwnd, source, self.cfg.checkerboard)?;
        // The window's client rect is the fitted size, not the source size, so bring
        // the swapchain to match up front (the creation-time WM_SIZE fires before the
        // proxy is registered and is ignored). Until the host relayouts, the fitted
        // window shows the whole source scaled to fit — the same transient resample
        // accepted during a live drag; the roundtrip below snaps it back to 1:1.
        proxy.resize_swapchain(&self.gpu, win_w, win_h);
        self.hwnd_to_id.insert(hwnd.0 as isize, id);
        self.proxies.insert(id, proxy);
        unsafe {
            let _ = ShowWindow(hwnd, SW_SHOW);
        }

        // If we had to shrink the window to fit the monitor, ask the host to resize
        // the Mac window to the fitted size. The host relayouts natively and reports
        // back the ACTUAL geometry (I-4), which snaps the swapchain to an exact 1:1
        // blit — the product's geometry-mirroring, applied at birth instead of only
        // on a user drag.
        if clamped {
            self.send(&ClientMessage::RequestResize {
                id,
                size: Size { w: win_w, h: win_h },
                phase: ResizePhase::End,
            });
        }

        // Always-visible diagnostic: the source size, the fitted window size, and
        // the DPI/scale the window landed on, so an oversize-source clamp or a
        // resampling regression (window on a scaled monitor) is easy to spot.
        let win_dpi = super::dpi::dpi_for_window(hwnd);
        println!(
            "window {id}: source {}x{} px -> {}x{} px proxy{} on {} DPI ({:.2}x scale)",
            source.w,
            source.h,
            win_w,
            win_h,
            if clamped {
                " [clamped to monitor, requested host resize]"
            } else {
                ""
            },
            win_dpi,
            super::dpi::scale_for_dpi(win_dpi)
        );
        Ok(())
    }

    fn destroy_proxy(&mut self, id: u64) {
        self.pending_mouse_moves.remove(&id);
        if let Some(proxy) = self.proxies.remove(&id) {
            self.hwnd_to_id.remove(&(proxy.hwnd.0 as isize));
            unsafe {
                let _ = DestroyWindow(proxy.hwnd);
            }
        }
    }

    fn update_title(&mut self, id: u64, title: &str) {
        let Some(proxy) = self.proxies.get(&id) else {
            return;
        };
        let title_text = if title.trim().is_empty() {
            "Transom"
        } else {
            title
        };
        let title_w: Vec<u16> = title_text
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        unsafe {
            let _ = SetWindowTextW(proxy.hwnd, PCWSTR(title_w.as_ptr()));
        }
    }

    /// Host reported ACTUAL geometry for `id`. Update the source sub-rect, and if
    /// the size changed and we're not mid-drag, snap the OS window's client size
    /// to match so the blit is 1:1 (I-4: "asked 2560x1440, got 2560x1438").
    fn update_source_rect(&mut self, id: u64, source: Rect) {
        let Some(proxy) = self.proxies.get_mut(&id) else {
            return;
        };
        let size_changed = proxy.set_source(source);
        if size_changed && !proxy.in_size_move {
            let hwnd = proxy.hwnd;
            unsafe {
                let _ = SetWindowPos(
                    hwnd,
                    None,
                    0,
                    0,
                    source.w as i32,
                    source.h as i32,
                    SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE,
                );
            }
            // The resulting WM_SIZE resizes the swapchain to the exact rect.
        }
    }

    fn render_all(&mut self) {
        let source = self.source.as_ref();
        for proxy in self.proxies.values_mut() {
            proxy.render(&self.gpu, source);
        }
    }

    // --- window procedure dispatch --------------------------------------

    /// Handle one message for a proxy window. Returns `Some(lresult)` if handled,
    /// `None` to fall through to `DefWindowProcW`.
    fn handle_message(
        &mut self,
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> Option<LRESULT> {
        let id = *self.hwnd_to_id.get(&(hwnd.0 as isize))?;

        match msg {
            // Eat the whole non-client area: borderless, but native resize/snap
            // stay because it's still a WS_OVERLAPPEDWINDOW (client AGENTS.md).
            WM_NCCALCSIZE if wparam.0 != 0 => Some(LRESULT(0)),

            WM_SIZE => {
                let w = (lparam.0 & 0xFFFF) as u32;
                let h = ((lparam.0 >> 16) & 0xFFFF) as u32;
                if let Some(proxy) = self.proxies.get_mut(&id) {
                    proxy.resize_swapchain(&self.gpu, w, h);
                    let source = self.source.as_ref();
                    if let Some(proxy) = self.proxies.get_mut(&id) {
                        proxy.render(&self.gpu, source);
                    }
                }
                Some(LRESULT(0))
            }

            WM_ENTERSIZEMOVE => {
                // Any queued hover belongs to the just-started local window
                // gesture, not to the remote Mac app.
                self.pending_mouse_moves.remove(&id);
                if let Some(proxy) = self.proxies.get_mut(&id) {
                    proxy.begin_size_move();
                    let size = Size {
                        w: proxy.width,
                        h: proxy.height,
                    };
                    self.send(&ClientMessage::RequestResize {
                        id,
                        size,
                        phase: ResizePhase::Begin,
                    });
                }
                Some(LRESULT(0))
            }

            WM_SIZING => {
                // lParam is a RECT* of the proposed *window* rect; with our
                // NCCALCSIZE the client fills it, so its size is the client size.
                let now = Instant::now();
                let (w, h) = unsafe {
                    let r = &*(lparam.0 as *const RECT);
                    (
                        (r.right - r.left).max(1) as u32,
                        (r.bottom - r.top).max(1) as u32,
                    )
                };
                if let Some(proxy) = self.proxies.get_mut(&id) {
                    if proxy.should_send_live(now) {
                        self.send(&ClientMessage::RequestResize {
                            id,
                            size: Size { w, h },
                            phase: ResizePhase::Live,
                        });
                    }
                    let source = self.source.as_ref();
                    if let Some(proxy) = self.proxies.get_mut(&id) {
                        proxy.render(&self.gpu, source);
                    }
                }
                // TRUE: we accept the proposed rect.
                Some(LRESULT(1))
            }

            WM_EXITSIZEMOVE => {
                if let Some(proxy) = self.proxies.get_mut(&id) {
                    proxy.end_size_move();
                    let size = Size {
                        w: proxy.width,
                        h: proxy.height,
                    };
                    // Authoritative 1:1 snap request.
                    self.send(&ClientMessage::RequestResize {
                        id,
                        size,
                        phase: ResizePhase::End,
                    });
                }
                Some(LRESULT(0))
            }

            WM_DPICHANGED => {
                // lParam: suggested new window rect in physical pixels for the new
                // monitor. Trust it; the subsequent WM_SIZE resizes the swapchain.
                let r = unsafe { &*(lparam.0 as *const RECT) };
                unsafe {
                    let _ = SetWindowPos(
                        hwnd,
                        None,
                        r.left,
                        r.top,
                        r.right - r.left,
                        r.bottom - r.top,
                        SWP_NOZORDER | SWP_NOACTIVATE,
                    );
                }
                Some(LRESULT(0))
            }

            WM_PAINT => {
                let source = self.source.as_ref();
                if let Some(proxy) = self.proxies.get_mut(&id) {
                    proxy.render(&self.gpu, source);
                }
                // Validate the whole window so we don't get flooded with WM_PAINT.
                unsafe {
                    let _ = windows::Win32::Graphics::Gdi::ValidateRect(hwnd, None);
                }
                Some(LRESULT(0))
            }

            WM_ACTIVATE if (wparam.0 & 0xFFFF) != 0 => {
                // Becoming active: ask the host to raise the Mac window so focus
                // and key routing line up (protocol.md §4 focus/raise).
                self.send(&ClientMessage::RequestFocus { id });
                Some(LRESULT(0))
            }

            WM_MOUSEMOVE => {
                let in_size_move = self
                    .proxies
                    .get(&id)
                    .map(|proxy| proxy.in_size_move)
                    .unwrap_or(false);
                if !in_size_move {
                    if let Some(event) = input::event_for_message(hwnd, msg, wparam, lparam) {
                        // Coalesce hover motion instead of doing a synchronous TCP
                        // write from the UI thread for every raw mouse message.
                        self.pending_mouse_moves.insert(id, event);
                    }
                }
                // DefWindowProc must still see movement during its modal move /
                // resize loop. We merely keep that local gesture off the wire.
                None
            }

            WM_LBUTTONDOWN | WM_LBUTTONUP | WM_RBUTTONDOWN | WM_RBUTTONUP | WM_MBUTTONDOWN
            | WM_MBUTTONUP | WM_MOUSEWHEEL | WM_MOUSEHWHEEL => {
                let in_size_move = self
                    .proxies
                    .get(&id)
                    .map(|proxy| proxy.in_size_move)
                    .unwrap_or(false);
                if !in_size_move {
                    // This event already carries its authoritative pointer
                    // coordinates, so an older queued hover can be discarded.
                    self.pending_mouse_moves.remove(&id);
                    if let Some(event) = input::event_for_message(hwnd, msg, wparam, lparam) {
                        self.send_input(id, event);
                    }
                }
                None
            }

            WM_KEYDOWN | WM_KEYUP | WM_SYSKEYDOWN | WM_SYSKEYUP => {
                if let Some(event) = input::event_for_message(hwnd, msg, wparam, lparam) {
                    self.send_input(id, event);
                }
                // Let DefWindowProc still run for system keys (Alt menu, etc.) by
                // not claiming the message, except we already forwarded it.
                None
            }

            WM_CLOSE => {
                // Ask the host to close the Mac window; the proxy is torn down when
                // the host replies with `windowDestroyed`.
                self.send(&ClientMessage::RequestClose { id });
                Some(LRESULT(0))
            }

            WM_DESTROY => {
                self.hwnd_to_id.remove(&(hwnd.0 as isize));
                self.proxies.remove(&id);
                Some(LRESULT(0))
            }

            _ => None,
        }
    }

    fn send_input(&self, id: u64, event: InputEvent) {
        self.send(&ClientMessage::Input {
            id,
            event,
            ts: self.now_ms(),
        });
    }

    fn flush_mouse_moves(&mut self) {
        for (id, event) in std::mem::take(&mut self.pending_mouse_moves) {
            self.send_input(id, event);
        }
    }
}

fn suffix(reason: Option<String>) -> String {
    reason.map(|r| format!(": {r}")).unwrap_or_default()
}

// ---------------------------------------------------------------------------
// Window class + procedure
// ---------------------------------------------------------------------------

/// Register the proxy window class once per process.
pub fn register_class() -> windows::core::Result<()> {
    let instance = unsafe { GetModuleHandleW(None)? };
    let cursor = unsafe { LoadCursorW(None, IDC_ARROW)? };
    let class = WNDCLASSW {
        lpfnWndProc: Some(wndproc),
        hInstance: instance.into(),
        lpszClassName: CLASS_NAME,
        hCursor: cursor,
        ..Default::default()
    };
    let atom = unsafe { RegisterClassW(&class) };
    if atom == 0 {
        return Err(windows::core::Error::from_win32());
    }
    Ok(())
}

extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    unsafe {
        // Stash the App pointer on NCCREATE, before any other message needs it.
        if msg == WM_NCCREATE {
            let cs = &*(lparam.0 as *const CREATESTRUCTW);
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, cs.lpCreateParams as isize);
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        }

        let app_ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut App;
        if app_ptr.is_null() {
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        }

        // Sound because the pump never holds a Rust borrow across DispatchMessageW.
        if let Some(result) = (*app_ptr).handle_message(hwnd, msg, wparam, lparam) {
            result
        } else {
            DefWindowProcW(hwnd, msg, wparam, lparam)
        }
    }
}

// ---------------------------------------------------------------------------
// Message pump
// ---------------------------------------------------------------------------

/// Run the app until all windows close (or `WM_QUIT`). Owns the `App` behind a
/// box so the raw pointer handed to each window stays valid for the whole run.
pub fn run_pump(mut app: Box<App>) {
    let app_ptr: *mut App = &mut *app;

    // Initial connect attempt; the pump keeps retrying on the backoff.
    unsafe { (*app_ptr).connect() };

    loop {
        unsafe { (*app_ptr).poll_dashboard() };
        // 1. Fold in any protocol events (may create/destroy windows).
        unsafe { (*app_ptr).drain_session(app_ptr) };
        unsafe { (*app_ptr).poll_decoder() };

        // 2. Pump all pending Win32 messages. No Rust borrow of App is held here,
        //    so the reentrant wndproc's `*app_ptr` access is sound.
        let mut msg = MSG::default();
        let mut quit = false;
        loop {
            let got = unsafe { PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE) };
            if !got.as_bool() {
                break;
            }
            if msg.message == WM_QUIT {
                quit = true;
                break;
            }
            if unsafe { (*app_ptr).dashboard.dialog_message(&msg) } {
                continue;
            }
            unsafe {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        if quit {
            break;
        }

        // 3. Send at most one hover position per window for this message batch,
        //    then render. Neither operation floods the UI thread during a drag.
        unsafe { (*app_ptr).flush_mouse_moves() };
        unsafe { (*app_ptr).render_all() };

        // 4. If every window has closed and we were connected, exit; otherwise
        //    wait briefly for input or the next channel poll.
        unsafe {
            if (*app_ptr).proxies.is_empty() && (*app_ptr).session.is_some() {
                // Still connected, just no windows yet — keep waiting.
            }
            // Wake on new input, or after ~8ms to re-poll the session channel.
            MsgWaitForMultipleObjectsEx(None, 8, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        }
    }

    // Clean shutdown of the session's threads.
    unsafe {
        if let Some(s) = (*app_ptr).session.take() {
            s.shutdown();
        }
    }
    let _ = app; // keep the box alive until here
}

/// Post `WM_QUIT` (used by a future tray/quit path).
#[allow(dead_code)]
pub fn quit() {
    unsafe { PostQuitMessage(0) };
}
