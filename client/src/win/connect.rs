use windows::Win32::UI::Shell::{DefSubclassProc, RemoveWindowSubclass, SetWindowSubclass};
// Native acrylic dashboard; controls queue actions for the application pump.
use super::{
    gallery::{Card, CARD_BASE, CARD_COUNT},
    glass::{self, rect, Glass, Paint},
};
use crate::{
    connections::{self, Connection},
    model::Window,
    wire::{Rect, Size, WindowKind},
};
use std::{
    collections::VecDeque,
    ffi::c_void,
    path::PathBuf,
    sync::mpsc,
    time::{Duration, Instant},
};
use windows::{
    core::{w, PCWSTR},
    Win32::{
        Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM},
        Graphics::Gdi::*,
        System::LibraryLoader::GetModuleHandleW,
        UI::{
            Controls::{SetWindowTheme, EM_SETLIMITTEXT, WM_MOUSELEAVE},
            HiDpi::GetDpiForWindow,
            Input::KeyboardAndMouse::{
                EnableWindow, GetFocus, IsWindowEnabled, SetFocus, TrackMouseEvent, TME_LEAVE,
                TRACKMOUSEEVENT,
            },
            WindowsAndMessaging::*,
        },
    },
};
const CLASS: PCWSTR = w!("TransomDashboard");
const CONNECT: usize = 1;
const SCREEN: usize = 2;
const MENU: usize = 3;
const NAV_CONNECTIONS: usize = 10;
const NAV_APPS: usize = 11;
const NAV_RECENTS: usize = 12;
const NAV_SETTINGS: usize = 13;
const TAB_APPS: usize = 20;
const TAB_DESKTOP: usize = 21;
const TAB_FILES: usize = 22;
const SEARCH: usize = 30;
const SORT: usize = 31;
const GRID: usize = 32;
const LIST: usize = 33;
const PREVIOUS: usize = 40;
const NEXT: usize = 41;
const OPEN_ANY: usize = 42;
const MORE_APPS: usize = 43;
const HELP: usize = 44;
const HOST: usize = 50;
const CONTROL: usize = 51;
const VIDEO: usize = 52;
const MANUAL: usize = 53;
const UPDATE: usize = 54;
const REFRESH: usize = 55;
const MINIMIZE: usize = 60;
const MAXIMIZE: usize = 61;
const CLOSE: usize = 62;
const SHOW_MENU: u32 = WM_APP + 30;
const SHOW_CARD_MENU: u32 = WM_APP + 31;
const CARD_MENU_BASE: usize = 2000;
const SIDEBAR: i32 = 236;
pub enum Action {
    Connect(Connection),
    Disconnect,
    OpenWindow(u64),
    HideWindow(u64),
}
struct Control {
    hwnd: HWND,
    id: usize,
}
struct State {
    hwnd: HWND,
    controls: Vec<Control>,
    font: HFONT,
    brush: HBRUSH,
    glass: Option<Glass>,
    dpi: u32,
    actions: VecDeque<Action>,
    saved: Vec<Connection>,
    nearby: Vec<Connection>,
    rows: Vec<Connection>,
    selected_device: usize,
    preferences: PathBuf,
    scan: Option<mpsc::Receiver<std::io::Result<Vec<Connection>>>>,
    next_scan: Instant,
    active: bool,
    connected: bool,
    status: String,
    discovery: String,
    cards: Vec<Card>,
    desktop: Card,
    visible: Vec<usize>,
    page: usize,
    page_size: usize,
    query: String,
    view: usize,
    list: bool,
    sort_name: bool,
    recents: Vec<u64>,
    last_preview: Instant,
}
pub struct Dashboard {
    pub hwnd: HWND,
    state: Box<State>,
}
impl Dashboard {
    pub fn new() -> windows::core::Result<Self> {
        let instance = unsafe { GetModuleHandleW(None)? };
        unsafe {
            RegisterClassW(&WNDCLASSW {
                hCursor: LoadCursorW(None, IDC_ARROW)?,
                hIcon: LoadIconW(HINSTANCE(instance.0), PCWSTR(101usize as *const u16))
                    .unwrap_or_default(),
                hInstance: HINSTANCE(instance.0),
                lpfnWndProc: Some(window_proc),
                lpszClassName: CLASS,
                ..Default::default()
            });
        }
        let preferences = std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir)
            .join("Transom")
            .join("connections.json");
        let (saved, status) = match connections::load(&preferences) {
            Ok(s) => (s, "Choose a Mac to get started.".into()),
            Err(e) => (vec![], format!("Could not load saved Macs: {e}")),
        };
        let mut state = Box::new(State {
            hwnd: HWND::default(),
            controls: vec![],
            font: HFONT::default(),
            brush: unsafe { CreateSolidBrush(COLORREF(0x002C1D11)) },
            glass: None,
            dpi: 96,
            actions: VecDeque::new(),
            saved,
            nearby: vec![],
            rows: vec![],
            selected_device: 0,
            preferences,
            scan: None,
            next_scan: Instant::now(),
            active: false,
            connected: false,
            status,
            discovery: "Looking for nearby Macs…".into(),
            cards: vec![],
            desktop: Card::new(
                Window {
                    id: 0,
                    title: "Shared display".into(),
                    kind: WindowKind::Normal,
                    source: Rect {
                        x: 0,
                        y: 0,
                        w: 0,
                        h: 0,
                    },
                },
                false,
            ),
            visible: vec![],
            page: 0,
            page_size: 8,
            query: String::new(),
            view: NAV_CONNECTIONS,
            list: false,
            sort_name: true,
            recents: vec![],
            last_preview: Instant::now() - Duration::from_secs(1),
        });
        let hwnd = unsafe {
            CreateWindowExW(
                WS_EX_APPWINDOW | WS_EX_CONTROLPARENT,
                CLASS,
                w!("Transom"),
                WS_OVERLAPPEDWINDOW,
                CW_USEDEFAULT,
                CW_USEDEFAULT,
                1464,
                934,
                None,
                None,
                HINSTANCE(instance.0),
                Some((&mut *state as *mut State).cast::<c_void>()),
            )?
        };
        unsafe {
            state.hwnd = hwnd;
            state.dpi = GetDpiForWindow(hwnd).max(96);
            state.rebuild_font();
            let work = super::dpi::work_area_at(40, 40);
            let width = scale(1464, state.dpi).min(work.right - work.left - 64);
            let height = scale(934, state.dpi).min(work.bottom - work.top - 64);
            let _ = SetWindowPos(
                hwnd,
                None,
                work.left + 32,
                work.top + 32,
                width,
                height,
                SWP_NOZORDER,
            );
            state.glass = Some(Glass::new(hwnd, state.dpi)?);
            state.rebuild_rows();
            state.layout();
            let _ = ShowWindow(hwnd, SW_SHOW);
            let _ = SetFocus(state.control(CONNECT));
        }
        Ok(Self { hwnd, state })
    }
    pub fn tick(&mut self) -> Option<Action> {
        let result = self.state.scan.as_ref().and_then(|rx| rx.try_recv().ok());
        if let Some(result) = result {
            self.state.scan = None;
            match result {
                Ok(found) => {
                    self.state.nearby = found;
                    self.state.discovery = if self.state.nearby.is_empty() {
                        "No nearby Macs. Start sharing in Transom Host.".into()
                    } else {
                        format!("{} Mac(s) available nearby", self.state.nearby.len())
                    };
                    unsafe {
                        self.state.rebuild_rows();
                    }
                }
                Err(e) => self.state.discovery = format!("Discovery unavailable: {e}"),
            }
            self.state.next_scan = Instant::now() + Duration::from_secs(8);
            unsafe {
                self.state.invalidate();
            }
        }
        if self.state.scan.is_none() && Instant::now() >= self.state.next_scan {
            self.state.start_scan();
        }
        self.state.actions.pop_front()
    }
    pub fn set_status(&mut self, text: &str, active: bool) {
        if self.state.status != text || self.state.active != active {
            self.state.status = text.into();
            self.state.active = active;
            unsafe {
                set_text(
                    self.state.control(CONNECT),
                    if active { "Disconnect" } else { "Connect" },
                );
                self.state.layout();
            }
        }
    }
    pub fn set_connected(&mut self, connected: bool) {
        self.state.connected = connected;
        unsafe {
            self.state.invalidate();
        }
    }
    pub fn remember(&mut self, c: Connection) {
        let id = c.id.clone();
        connections::remember(&mut self.state.saved, c);
        if let Err(e) = connections::save(&self.state.preferences, &self.state.saved) {
            self.state.discovery = format!("Connected, but could not save this Mac: {e}");
        }
        unsafe {
            self.state.rebuild_rows();
        }
        if let Some(i) = self.state.rows.iter().position(|c| c.id == id) {
            self.state.selected_device = i;
        }
        unsafe {
            self.state.invalidate();
        }
    }
    pub fn set_windows(&mut self, windows: Vec<(Window, bool)>) {
        let mut old = std::mem::take(&mut self.state.cards);
        self.state.cards = windows
            .into_iter()
            .map(|(w, opened)| {
                if let Some(i) = old.iter().position(|c| c.window.id == w.id) {
                    let mut card = old.remove(i);
                    if card.window.source != w.source {
                        card.pixels.clear();
                        card.size = Size { w: 0, h: 0 };
                    }
                    card.window = w;
                    card.opened = opened;
                    card
                } else {
                    Card::new(w, opened)
                }
            })
            .collect();
        if self.state.cards.is_empty() {
            self.state.desktop.pixels.clear();
            self.state.desktop.size = Size { w: 0, h: 0 };
        }
        unsafe {
            self.state.layout();
        }
    }
    pub fn update_previews(&mut self, pixels: &[u8], display: Size) {
        if self.state.last_preview.elapsed() < Duration::from_millis(250) {
            return;
        }
        self.state.last_preview = Instant::now();
        for c in &mut self.state.cards {
            c.update_preview(pixels, display);
        }
        self.state.desktop.window.source = Rect {
            x: 0,
            y: 0,
            w: display.w,
            h: display.h,
        };
        self.state
            .desktop
            .update_preview_sized(pixels, display, 1280, 720);
        unsafe {
            for slot in 0..CARD_COUNT {
                let _ = InvalidateRect(self.state.control(CARD_BASE + slot), None, false);
            }
            self.state.invalidate();
        }
    }
    pub fn dialog_message(&self, message: &MSG) -> bool {
        unsafe {
            (message.hwnd == self.hwnd || IsChild(self.hwnd, message.hwnd).as_bool())
                && IsDialogMessageW(self.hwnd, message).as_bool()
        }
    }
}
impl Drop for Dashboard {
    fn drop(&mut self) {
        unsafe {
            if IsWindow(self.hwnd).as_bool() {
                let _ = DestroyWindow(self.hwnd);
            }
            let _ = DeleteObject(self.state.font);
            let _ = DeleteObject(self.state.brush);
        }
    }
}
impl State {
    fn control(&self, id: usize) -> HWND {
        self.controls
            .iter()
            .find(|c| c.id == id)
            .map(|c| c.hwnd)
            .unwrap_or_default()
    }
    fn selected(&self) -> Option<Connection> {
        self.rows.get(self.selected_device).cloned()
    }
    unsafe fn invalidate(&self) {
        let _ = InvalidateRect(self.hwnd, None, false);
    }
    fn start_scan(&mut self) {
        let (tx, rx) = mpsc::channel();
        self.scan = Some(rx);
        std::thread::spawn(move || {
            let _ = tx.send(crate::discovery::scan());
        });
    }
    unsafe fn rebuild_rows(&mut self) {
        let selected = self.selected().map(|c| c.id);
        let mut rows = self.nearby.clone();
        for c in &self.saved {
            if !rows.iter().any(|n| n.id == c.id) {
                rows.push(c.clone());
            }
        }
        self.rows = rows;
        self.selected_device = selected
            .and_then(|id| self.rows.iter().position(|c| c.id == id))
            .unwrap_or(0);
        self.layout();
    }
    unsafe fn rebuild_font(&mut self) {
        let old = self.font;
        self.font = CreateFontW(
            -scale(14, self.dpi),
            0,
            0,
            0,
            400,
            0,
            0,
            0,
            DEFAULT_CHARSET.0 as u32,
            0,
            0,
            5,
            0,
            w!("Segoe UI"),
        );
        for c in &self.controls {
            SendMessageW(c.hwnd, WM_SETFONT, WPARAM(self.font.0 as usize), LPARAM(0));
        }
        let _ = DeleteObject(old);
    }
    unsafe fn place(&self, id: usize, x: i32, y: i32, w: i32, h: i32, visible: bool) {
        let hwnd = self.control(id);
        let _ = ShowWindow(hwnd, if visible { SW_SHOW } else { SW_HIDE });
        if visible {
            let _ = MoveWindow(
                hwnd,
                scale(x, self.dpi),
                scale(y, self.dpi),
                scale(w, self.dpi),
                scale(h, self.dpi),
                false,
            );
            let _ = InvalidateRect(hwnd, None, false);
        }
    }
    fn matches(&self) -> Vec<usize> {
        let mut entries: Vec<_> = self
            .cards
            .iter()
            .enumerate()
            .filter(|(_, c)| {
                let title = c.window.title.to_lowercase();
                title.contains(&self.query)
                    && (self.view != NAV_RECENTS || self.recents.contains(&c.window.id))
                    && (self.view != TAB_FILES || title.contains("finder"))
            })
            .map(|(i, _)| i)
            .collect();
        if self.view == NAV_RECENTS {
            entries.sort_by_key(|&i| {
                self.recents
                    .iter()
                    .position(|id| *id == self.cards[i].window.id)
            });
        } else if self.sort_name {
            entries.sort_by_key(|&i| self.cards[i].window.title.to_lowercase());
        }
        entries
    }
    unsafe fn layout(&mut self) {
        if self.hwnd.is_invalid() {
            return;
        }
        let mut r = RECT::default();
        let _ = GetClientRect(self.hwnd, &mut r);
        let w = r.right * 96 / self.dpi as i32;
        let h = r.bottom * 96 / self.dpi as i32;
        for (id, y) in [
            (NAV_CONNECTIONS, 112),
            (NAV_APPS, 164),
            (NAV_RECENTS, 216),
            (NAV_SETTINGS, 268),
        ] {
            self.place(id, 10, y, 210, 50, true);
        }
        self.place(MINIMIZE, w - 140, 0, 46, 32, true);
        self.place(MAXIMIZE, w - 94, 0, 46, 32, true);
        self.place(CLOSE, w - 48, 0, 46, 32, true);
        self.place(CONNECT, w - 450, 96, 162, 52, true);
        self.place(SCREEN, w - 274, 96, 164, 52, true);
        self.place(MENU, w - 96, 96, 52, 52, true);
        self.place(MORE_APPS, 16, h - 172, 192, 100, true);
        self.place(HELP, 178, h - 55, 34, 30, true);
        for (id, x, ww) in [
            (TAB_APPS, 240, 168),
            (TAB_DESKTOP, 420, 140),
            (TAB_FILES, 572, 110),
        ] {
            self.place(id, x, 215, ww, 52, true);
        }
        let gallery = self.view != NAV_SETTINGS && self.view != TAB_DESKTOP;
        self.place(SEARCH, w - 290, 227, 250, 27, gallery);
        self.place(SORT, w - 216, 288, 124, 34, gallery);
        self.place(GRID, w - 86, 289, 36, 34, gallery);
        self.place(LIST, w - 46, 289, 32, 34, gallery);
        let cols = ((w - SIDEBAR - 30) / 274).clamp(1, 4) as usize;
        let rows = ((h - 348 - 62) / 204).clamp(1, 3) as usize;
        self.page_size = if self.list {
            ((h - 422) / 84).clamp(1, 12) as usize
        } else {
            (cols * rows).min(CARD_COUNT)
        };
        let matches = self.matches();
        self.page = self
            .page
            .min(matches.len().saturating_sub(1) / self.page_size);
        self.visible = matches
            .iter()
            .skip(self.page * self.page_size)
            .take(self.page_size)
            .copied()
            .collect();
        let cw = (w - SIDEBAR - 18 - (cols as i32 - 1) * 16) / cols as i32;
        for slot in 0..CARD_COUNT {
            if let Some(&index) = self.visible.get(slot).filter(|_| gallery) {
                set_text(
                    self.control(CARD_BASE + slot),
                    &super::gallery::accessible_title(&self.cards[index]),
                );
                if self.list {
                    self.place(
                        CARD_BASE + slot,
                        SIDEBAR + 2,
                        348 + slot as i32 * 84,
                        w - SIDEBAR - 18,
                        72,
                        true,
                    );
                } else {
                    self.place(
                        CARD_BASE + slot,
                        SIDEBAR + 2 + (slot % cols) as i32 * (cw + 16),
                        348 + (slot / cols) as i32 * 204,
                        cw,
                        188,
                        true,
                    );
                }
            } else {
                self.place(CARD_BASE + slot, 0, 0, 1, 1, false);
            }
        }
        for slot in 0..CARD_COUNT {
            if let Some(&index) = self.visible.get(slot).filter(|_| gallery) {
                set_text(
                    self.control(CARD_MENU_BASE + slot),
                    &format!("Options for {}", self.cards[index].window.title),
                );
                // Sibling buttons overlap the card; keep their native hit targets above it.
                let _ = SetWindowPos(
                    self.control(CARD_MENU_BASE + slot),
                    HWND_TOP,
                    0,
                    0,
                    0,
                    0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
                );
                if self.list {
                    self.place(
                        CARD_MENU_BASE + slot,
                        w - 65,
                        365 + slot as i32 * 84,
                        34,
                        32,
                        true,
                    );
                } else {
                    self.place(
                        CARD_MENU_BASE + slot,
                        SIDEBAR + 2 + (slot % cols) as i32 * (cw + 16) + cw - 44,
                        348 + (slot / cols) as i32 * 204 + 148,
                        32,
                        30,
                        true,
                    );
                }
            } else {
                self.place(CARD_MENU_BASE + slot, 0, 0, 1, 1, false);
            }
        }
        let used_rows = self.visible.len().div_ceil(cols);
        let add_y = 348 + used_rows as i32 * 204;
        self.place(
            OPEN_ANY,
            SIDEBAR + 2,
            add_y,
            cw,
            144,
            gallery && !self.list && add_y + 144 < h - 24 && !self.visible.is_empty(),
        );
        self.place(
            PREVIOUS,
            w - 416,
            h - 52,
            92,
            30,
            gallery && matches.len() > self.page_size,
        );
        self.place(
            NEXT,
            w - 316,
            h - 52,
            80,
            30,
            gallery && matches.len() > self.page_size,
        );
        let _ = EnableWindow(self.control(PREVIOUS), self.page > 0);
        let _ = EnableWindow(
            self.control(NEXT),
            (self.page + 1) * self.page_size < matches.len(),
        );
        let settings = self.view == NAV_SETTINGS;
        self.place(HOST, 268, 402, 470, 36, settings);
        self.place(CONTROL, 268, 496, 210, 36, settings);
        self.place(VIDEO, 500, 496, 238, 36, settings);
        self.place(MANUAL, 268, 560, 210, 44, settings);
        self.place(REFRESH, 492, 560, 160, 44, settings);
        self.place(UPDATE, 268, 652, 210, 40, settings);
        let _ = EnableWindow(self.control(CONNECT), self.active || !self.rows.is_empty());
        let _ = EnableWindow(self.control(MANUAL), !self.active);
        self.invalidate();
    }
    unsafe fn paint(&mut self) {
        let mut ps = PAINTSTRUCT::default();
        let _ = BeginPaint(self.hwnd, &mut ps);
        let mut r = RECT::default();
        let _ = GetClientRect(self.hwnd, &mut r);
        if self.glass.is_none() {
            self.glass = Glass::new(self.hwnd, self.dpi).ok();
        }
        if let Some(g) = &self.glass {
            if let Ok(p) = g.begin(r.right.max(1) as u32, r.bottom.max(1) as u32, self.dpi) {
                self.draw_shell(
                    &p,
                    r.right as f32 * 96. / self.dpi as f32,
                    r.bottom as f32 * 96. / self.dpi as f32,
                );
                for c in &self.controls {
                    if [SEARCH, HOST, CONTROL, VIDEO].contains(&c.id)
                        || !IsWindowVisible(c.hwnd).as_bool()
                    {
                        continue;
                    }
                    let mut r = RECT::default();
                    let _ = GetWindowRect(c.hwnd, &mut r);
                    let mut origin = POINT {
                        x: r.left,
                        y: r.top,
                    };
                    let _ = ScreenToClient(self.hwnd, &mut origin);
                    p.rt.SetTransform(&windows::Foundation::Numerics::Matrix3x2 {
                        M11: 1.,
                        M12: 0.,
                        M21: 0.,
                        M22: 1.,
                        M31: origin.x as f32 * 96. / self.dpi as f32,
                        M32: origin.y as f32 * 96. / self.dpi as f32,
                    });
                    self.draw_control(
                        &p,
                        c.id,
                        c.hwnd,
                        (r.right - r.left) as f32 * 96. / self.dpi as f32,
                        (r.bottom - r.top) as f32 * 96. / self.dpi as f32,
                    );
                }
                p.rt.SetTransform(&windows::Foundation::Numerics::Matrix3x2 {
                    M11: 1.,
                    M12: 0.,
                    M21: 0.,
                    M22: 1.,
                    M31: 0.,
                    M32: 0.,
                });
                if let Err(e) = g.end() {
                    eprintln!("dashboard render: {e}");
                    self.glass = None;
                }
            }
        }
        let _ = EndPaint(self.hwnd, &ps);
    }
    unsafe fn draw_shell(&self, p: &Paint<'_>, w: f32, h: f32) {
        p.glow(
            rect(0., 0., w, h),
            w * 0.60,
            80.,
            580.,
            390.,
            0x204FA9,
            0.17,
        );
        p.fill(rect(0., 0., 222., h), 0., 0x0E1929, 0.24);
        p.line(222., 32., 222., h, 0x18283B, 1.);
        p.logo(26., 28.);
        p.text(
            "Transom",
            rect(83., 24., 135., 35.),
            24.,
            true,
            glass::TEXT,
            false,
        );
        p.text(
            "Your Mac apps, anywhere.",
            rect(36., 64., 174., 23.),
            12.,
            false,
            glass::MUTED,
            false,
        );
        p.text(
            concat!("Transom v", env!("CARGO_PKG_VERSION")),
            rect(22., h - 50., 145., 25.),
            12.,
            false,
            0x8798B4,
            false,
        );
        let hero = rect(236., 38., w - 250., 156.);
        p.gradient(hero, 14., 0x233044, 0x111C2B, 0.67);
        p.glow(hero, w * 0.62, 80., 380., 250., 0x2D62E5, 0.23);
        p.stroke(hero, 14., glass::LINE, 0.7, 0.8);
        let compact = w < 1300.;
        let info_x = if compact { 440. } else { 520. };
        let info_width = (w - 450. - info_x - 24.).max(150.);
        p.mac(
            if compact { 266. } else { 280. },
            82.,
            if compact { 148. } else { 190. },
        );
        let selected = self.selected();
        let name = selected
            .as_ref()
            .map(|c| c.name.as_str())
            .unwrap_or("My Mac");
        p.text(
            name,
            rect(info_x, 58., info_width, 34.),
            24.,
            true,
            glass::TEXT,
            false,
        );
        let online = self.connected
            || selected
                .as_ref()
                .map(|c| self.nearby.iter().any(|n| n.id == c.id))
                .unwrap_or(false);
        p.dot(
            info_x + 6.,
            110.,
            4.,
            if online { glass::GREEN } else { 0x8694AA },
        );
        p.text(
            if online {
                "Online"
            } else if selected.is_some() {
                "Saved Mac"
            } else {
                "Choose a Mac"
            },
            rect(info_x + 18., 97., 140., 25.),
            13.,
            false,
            if online { glass::GREEN } else { glass::MUTED },
            false,
        );
        p.text(
            selected
                .as_ref()
                .map(|c| c.host.as_str())
                .unwrap_or("Start Transom Host to discover your Mac"),
            rect(info_x, 128., info_width, 28.),
            14.,
            false,
            glass::MUTED,
            false,
        );
        p.fill(rect(236., 212., w - 250., 59.), 14., 0x101B2C, 0.38);
        p.stroke(rect(236., 212., w - 250., 59.), 14., glass::LINE, 0.50, 0.8);
        if self.view != NAV_SETTINGS && self.view != TAB_DESKTOP {
            p.fill(rect(w - 326., 220., 310., 43.), 12., 0x111D2C, 0.82);
            p.stroke(rect(w - 326., 220., 310., 43.), 12., glass::LINE, 0.9, 1.);
            p.icon(
                "\u{E721}",
                rect(w - 319., 226., 24., 28.),
                18.,
                glass::MUTED,
            );
            let heading = if self.view == NAV_RECENTS {
                "Recently opened"
            } else if self.view == TAB_FILES {
                "Finder windows"
            } else {
                "Launch an app"
            };
            p.text(
                heading,
                rect(246., 286., 450., 29.),
                16.,
                true,
                glass::TEXT,
                false,
            );
            p.text(
                if self.view == TAB_FILES {
                    "Use Finder on your Mac to browse your files."
                } else {
                    "Select an app to open in a window on this PC."
                },
                rect(246., 314., (w - 480.).max(280.), 25.),
                13.,
                false,
                glass::MUTED,
                false,
            );
            if self.visible.is_empty() {
                let (title, detail) = if !self.query.is_empty() {
                    ("No matching apps", "Try another app or window title.")
                } else if !self.connected {
                    (
                        "Your Mac apps belong here",
                        "Connect to your Mac to see its shared windows.",
                    )
                } else if self.view == NAV_RECENTS {
                    (
                        "Your recent windows",
                        "Windows you open in this session will appear here.",
                    )
                } else if self.view == TAB_FILES {
                    (
                        "Share Finder from your Mac",
                        "Select Finder in Transom Host to browse its windows here.",
                    )
                } else {
                    (
                        "Choose apps on your Mac",
                        "Select the apps you want to share in Transom Host.",
                    )
                };
                p.stroke(rect(246., 365., w - 280., 220.), 12., glass::LINE, 0.8, 1.);
                p.icon("\u{E8A7}", rect(270., 390., 52., 52.), 32., glass::MUTED);
                p.text(
                    title,
                    rect(338., 391., w - 398., 44.),
                    21.,
                    true,
                    glass::TEXT,
                    false,
                );
                p.text(
                    detail,
                    rect(338., 436., w - 398., 30.),
                    14.,
                    false,
                    glass::MUTED,
                    false,
                );
                p.text(
                    &self.discovery,
                    rect(270., 525., w - 320., 30.),
                    13.,
                    false,
                    glass::MUTED,
                    false,
                );
            }
        } else if self.view == TAB_DESKTOP {
            p.text(
                "Shared display",
                rect(246., 290., 450., 30.),
                18.,
                true,
                glass::TEXT,
                false,
            );
            p.text(
                "Live preview of the Mac sharing display. Open an app for control.",
                rect(246., 320., w - 280., 30.),
                13.,
                false,
                glass::MUTED,
                false,
            );
            let area = rect(246., 370., w - 280., h - 445.);
            p.fill(area, 10., 0x070D16, 0.9);
            if self.desktop.size.w > 0 {
                let sw = self.desktop.size.w as f32;
                let sh = self.desktop.size.h as f32;
                let k = ((area.right - area.left) / sw).min((area.bottom - area.top) / sh);
                p.bitmap(
                    &self.desktop.pixels,
                    self.desktop.size.w,
                    self.desktop.size.h,
                    rect(
                        area.left + (area.right - area.left - sw * k) / 2.,
                        area.top + (area.bottom - area.top - sh * k) / 2.,
                        sw * k,
                        sh * k,
                    ),
                );
            } else {
                p.text(
                    "Waiting for a video connection",
                    area,
                    17.,
                    false,
                    glass::MUTED,
                    true,
                );
            }
        } else {
            p.text(
                "Connection settings",
                rect(268., 292., 600., 36.),
                22.,
                true,
                glass::TEXT,
                false,
            );
            p.text(
                "Connect manually or manage your local connection.",
                rect(268., 330., 650., 28.),
                14.,
                false,
                glass::MUTED,
                false,
            );
            p.text(
                "Mac hostname or IP address",
                rect(268., 374., 470., 25.),
                13.,
                true,
                glass::MUTED,
                false,
            );
            p.text(
                "Control port",
                rect(268., 466., 210., 25.),
                13.,
                true,
                glass::MUTED,
                false,
            );
            p.text(
                "Video port",
                rect(500., 466., 238., 25.),
                13.,
                true,
                glass::MUTED,
                false,
            );
            p.text(
                "Leave video blank for control only. Use a trusted local network.",
                rect(268., 610., 700., 30.),
                13.,
                false,
                glass::MUTED,
                false,
            );
            for (x, y, ww) in [(262., 396., 482.), (262., 490., 222.), (494., 490., 250.)] {
                p.stroke(rect(x, y, ww, 48.), 8., glass::LINE, 1., 1.);
            }
        }
        p.text(
            &self.status,
            rect(550., h - 48., (w - 740.).max(170.), 30.),
            12.,
            false,
            glass::MUTED,
            false,
        );
        p.fill(rect(w - 154., h - 56., 136., 38.), 13., 0x142338, 0.6);
        p.stroke(
            rect(w - 154., h - 56., 136., 38.),
            13.,
            glass::LINE,
            0.8,
            1.,
        );
        p.dot(
            w - 132.,
            h - 37.,
            5.,
            if self.connected {
                glass::GREEN
            } else {
                0x7E8DA3
            },
        );
        p.text(
            if self.connected {
                "Connected"
            } else if self.active {
                "Connecting"
            } else {
                "Offline"
            },
            rect(w - 117., h - 52., 90., 30.),
            12.,
            false,
            glass::TEXT,
            false,
        );
    }
    unsafe fn draw_control(&self, p: &Paint<'_>, id: usize, hwnd: HWND, w: f32, h: f32) {
        let focused = GetFocus() == hwnd;
        let pressed =
            SendMessageW(hwnd, BM_GETSTATE, WPARAM(0), LPARAM(0)).0 as u32 & BST_PUSHED != 0;
        let disabled = !IsWindowEnabled(hwnd).as_bool();
        let mut point = POINT::default();
        let _ = GetCursorPos(&mut point);
        let _ = ScreenToClient(hwnd, &mut point);
        let mut client = RECT::default();
        let _ = GetClientRect(hwnd, &mut client);
        let hovered =
            point.x >= 0 && point.y >= 0 && point.x < client.right && point.y < client.bottom;
        if hovered && !disabled {
            p.fill(rect(1., 1., w - 2., h - 2.), 10., 0x89AEED, 0.06);
        }

        if (CARD_BASE..CARD_BASE + CARD_COUNT).contains(&id) {
            if let Some(&i) = self.visible.get(id - CARD_BASE) {
                super::gallery::draw_glass(
                    &self.cards[i],
                    p,
                    w,
                    h,
                    focused || pressed || hovered,
                    self.list,
                );
            }
        } else if (CARD_MENU_BASE..CARD_MENU_BASE + CARD_COUNT).contains(&id) {
            p.icon("\u{E712}", rect(0., 0., w, h), 17., glass::MUTED);
        } else if [NAV_CONNECTIONS, NAV_APPS, NAV_RECENTS, NAV_SETTINGS].contains(&id) {
            let active = self.view == id
                || (id == NAV_APPS && [TAB_APPS, TAB_DESKTOP, TAB_FILES].contains(&self.view));
            if active {
                p.gradient(rect(1., 1., w - 2., h - 2.), 11., 0x203D83, 0x1C2D60, 0.94);
                p.fill(rect(1., 10., 3., h - 20.), 1.5, 0x4A86FF, 1.);
            }
            let (icon, name) = match id {
                NAV_CONNECTIONS => ("\u{E977}", "Connections"),
                NAV_APPS => ("\u{E80A}", "Apps"),
                NAV_RECENTS => ("\u{E81C}", "Recents"),
                _ => ("\u{E713}", "Settings"),
            };
            p.icon(icon, rect(14., 10., 35., 30.), 21., glass::MUTED);
            p.text(
                name,
                rect(65., 8., w - 70., 34.),
                14.,
                false,
                glass::TEXT,
                false,
            );
        } else if [TAB_APPS, TAB_DESKTOP, TAB_FILES].contains(&id) {
            let active = self.view == id
                || (id == TAB_APPS
                    && [NAV_CONNECTIONS, NAV_APPS, NAV_RECENTS].contains(&self.view));
            if active {
                p.gradient(rect(1., 1., w - 2., h - 2.), 12., 0x213C79, 0x1B2C56, 1.);
                p.stroke(rect(1., 1., w - 2., h - 2.), 12., 0x426AB8, 0.9, 0.8);
            }
            let (icon, name) = match id {
                TAB_APPS => ("\u{E80A}", "Applications"),
                TAB_DESKTOP => ("\u{E7F4}", "Desktop"),
                _ => ("\u{E8B7}", "Files"),
            };
            p.icon(icon, rect(18., 10., 30., 32.), 21., glass::MUTED);
            p.text(
                name,
                rect(59., 9., w - 62., 34.),
                14.,
                active,
                glass::TEXT,
                false,
            );
        } else if id == MORE_APPS {
            p.gradient(rect(1., 1., w - 2., h - 2.), 12., 0x16253F, 0x111D32, 0.93);
            p.stroke(rect(1., 1., w - 2., h - 2.), 12., glass::LINE, 0.6, 0.8);
            p.icon("\u{E8A7}", rect(14., 15., 26., 26.), 20., 0x87B8FF);
            p.text(
                "Share more apps",
                rect(50., 15., w - 56., 26.),
                13.,
                true,
                glass::TEXT,
                false,
            );
            p.text(
                "Choose apps in Transom Host",
                rect(16., 48., w - 26., 22.),
                11.,
                false,
                glass::MUTED,
                false,
            );
            p.text(
                "and open them here.",
                rect(16., 68., w - 26., 20.),
                11.,
                false,
                glass::MUTED,
                false,
            );
        } else if id == OPEN_ANY {
            p.dashed(rect(1., 1., w - 2., h - 2.), 11., 0x677F9F);
            p.line(w / 2., 29., w / 2., 53., glass::MUTED, 2.);
            p.line(w / 2. - 12., 41., w / 2. + 12., 41., glass::MUTED, 2.);
            p.text(
                "Open Any App",
                rect(8., 65., w - 16., 28.),
                14.,
                false,
                glass::TEXT,
                true,
            );
            p.text(
                "Find a shared app on your Mac.",
                rect(8., 93., w - 16., 25.),
                12.,
                false,
                0x8D9EB9,
                true,
            );
        } else if [MINIMIZE, MAXIMIZE, CLOSE].contains(&id) {
            if pressed {
                p.fill(
                    rect(0., 0., w, h),
                    0.,
                    if id == CLOSE { 0xB92B3C } else { 0x26374D },
                    1.,
                );
            }
            p.icon(
                match id {
                    MINIMIZE => "\u{E921}",
                    MAXIMIZE => "\u{E922}",
                    _ => "\u{E8BB}",
                },
                rect(0., 0., w, h),
                11.,
                glass::MUTED,
            );
        } else {
            let primary = id == CONNECT || id == MANUAL;
            let bare = [SORT, HELP].contains(&id);
            let selected = (id == GRID && !self.list) || (id == LIST && self.list);
            if !bare {
                p.gradient(
                    rect(1., 1., w - 2., h - 2.),
                    9.,
                    if primary { glass::BLUE } else { 0x233044 },
                    if primary { 0x245FF0 } else { 0x182333 },
                    1.,
                );
                p.stroke(
                    rect(1., 1., w - 2., h - 2.),
                    9.,
                    if selected { 0x628BCA } else { glass::LINE },
                    0.8,
                    0.8,
                );
            }
            let text = read_text(hwnd);
            let col = if disabled { 0x66748C } else { glass::TEXT };
            match id {
                CONNECT => {
                    p.icon(
                        if self.active { "\u{E8BB}" } else { "\u{E71B}" },
                        rect(20., 10., 30., h - 20.),
                        21.,
                        col,
                    );
                    p.text(
                        &text,
                        rect(57., 5., w - 64., h - 10.),
                        14.,
                        true,
                        col,
                        false,
                    );
                }
                SCREEN => {
                    p.icon("\u{E7F4}", rect(14., 10., 28., h - 20.), 20., col);
                    p.text(
                        "Screen View",
                        rect(53., 5., w - 59., h - 10.),
                        14.,
                        false,
                        col,
                        false,
                    );
                }
                MENU => p.icon("\u{E712}", rect(0., 0., w, h), 19., col),
                GRID => p.icon("\u{E80A}", rect(0., 0., w, h), 17., col),
                LIST => p.icon("\u{E8FD}", rect(0., 0., w, h), 17., col),
                HELP => p.icon("\u{E897}", rect(0., 0., w, h), 19., glass::MUTED),
                SORT => {
                    p.text(
                        if self.sort_name {
                            "Sort:  Name"
                        } else {
                            "Sort:  Host order"
                        },
                        rect(0., 0., w - 17., h),
                        12.,
                        false,
                        glass::MUTED,
                        false,
                    );
                    p.icon("\u{E70D}", rect(w - 16., 0., 16., h), 10., glass::MUTED);
                }
                _ => p.text(&text, rect(7., 0., w - 14., h), 13., false, col, true),
            }
        }
        if focused && !(CARD_BASE..CARD_BASE + CARD_COUNT).contains(&id) {
            p.stroke(rect(2., 2., w - 4., h - 4.), 8., 0x77AAFF, 1., 1.3);
        }
    }
}
unsafe extern "system" fn window_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if msg == WM_NCCREATE {
        let cs = &*(lp.0 as *const CREATESTRUCTW);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, cs.lpCreateParams as isize);
    }
    let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut State;
    if ptr.is_null() {
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
    if msg == SHOW_CARD_MENU {
        let snapshot = {
            let state = &*ptr;
            state
                .visible
                .get(wp.0)
                .and_then(|&i| state.cards.get(i))
                .map(|c| (c.window.id, c.opened))
        };
        if let Some((id, opened)) = snapshot {
            if let Ok(menu) = CreatePopupMenu() {
                let _ = AppendMenuW(
                    menu,
                    MF_STRING,
                    1,
                    if opened {
                        w!("Show window")
                    } else {
                        w!("Open on this PC")
                    },
                );
                let _ = AppendMenuW(
                    menu,
                    MF_STRING | if opened { MF_ENABLED } else { MF_GRAYED },
                    2,
                    w!("Hide from this PC"),
                );
                let mut point = POINT::default();
                let _ = GetCursorPos(&mut point);
                let choice = TrackPopupMenu(
                    menu,
                    TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTALIGN,
                    point.x,
                    point.y,
                    0,
                    hwnd,
                    None,
                )
                .0;
                let _ = DestroyMenu(menu);
                let state = &mut *ptr;
                if choice == 1 {
                    state.actions.push_back(Action::OpenWindow(id));
                    state.recents.retain(|v| *v != id);
                    state.recents.insert(0, id);
                } else if choice == 2 {
                    state.actions.push_back(Action::HideWindow(id));
                }
            }
        }
        return LRESULT(0);
    }
    // Popup menus pump messages. Do not retain a State borrow through that loop.
    if msg == SHOW_MENU {
        let rows = (*ptr).rows.clone();
        let selected = (*ptr).selected_device;
        let active = (*ptr).active;
        if let Ok(menu) = CreatePopupMenu() {
            for (i, c) in rows.iter().enumerate() {
                let name = wide(&c.name);
                let flags = MF_STRING
                    | if active { MF_GRAYED } else { MF_ENABLED }
                    | if i == selected {
                        MF_CHECKED
                    } else {
                        MF_UNCHECKED
                    };
                let _ = AppendMenuW(menu, flags, 2000 + i, PCWSTR(name.as_ptr()));
            }
            let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
            let _ = AppendMenuW(menu, MF_STRING, 100000, w!("Refresh nearby Macs"));
            let _ = AppendMenuW(menu, MF_STRING, 100001, w!("Connection settings"));
            if !rows.is_empty() {
                let _ = AppendMenuW(menu, MF_STRING, 100002, w!("Forget saved Mac"));
            }
            let mut pt = POINT::default();
            let _ = GetCursorPos(&mut pt);
            let chosen = TrackPopupMenu(
                menu,
                TPM_RETURNCMD | TPM_NONOTIFY,
                pt.x,
                pt.y,
                0,
                hwnd,
                None,
            )
            .0 as usize;
            let _ = DestroyMenu(menu);
            let s = &mut *ptr;
            if (2000..2000 + rows.len()).contains(&chosen) {
                if let Some(i) = s.rows.iter().position(|c| c.id == rows[chosen - 2000].id) {
                    s.selected_device = i;
                }
            } else if chosen == 100000 && s.scan.is_none() {
                s.start_scan();
            } else if chosen == 100001 {
                s.view = NAV_SETTINGS;
            } else if chosen == 100002 {
                if let Some(c) = rows.get(selected) {
                    s.saved.retain(|n| n.id != c.id);
                    if let Err(e) = connections::save(&s.preferences, &s.saved) {
                        s.status = format!("Could not save connections: {e}");
                    }
                    s.rebuild_rows();
                }
            }
            s.layout();
        }
        return LRESULT(0);
    }
    let s = &mut *ptr;
    match msg {
        WM_NCCALCSIZE => LRESULT(0),
        WM_CREATE => {
            s.hwnd = hwnd;
            create_controls(s);
            LRESULT(0)
        }
        WM_NCHITTEST => {
            let mut r = RECT::default();
            let _ = GetWindowRect(hwnd, &mut r);
            let x = (lp.0 as u16 as i16) as i32 - r.left;
            let y = ((lp.0 >> 16) as u16 as i16) as i32 - r.top;
            let w = r.right - r.left;
            let h = r.bottom - r.top;
            let b = scale(6, s.dpi);
            if !IsZoomed(hwnd).as_bool() {
                let l = x < b;
                let rr = x >= w - b;
                let t = y < b;
                let bb = y >= h - b;
                let hit = match (l, rr, t, bb) {
                    (true, _, true, _) => HTTOPLEFT,
                    (_, true, true, _) => HTTOPRIGHT,
                    (true, _, _, true) => HTBOTTOMLEFT,
                    (_, true, _, true) => HTBOTTOMRIGHT,
                    (true, _, _, _) => HTLEFT,
                    (_, true, _, _) => HTRIGHT,
                    (_, _, true, _) => HTTOP,
                    (_, _, _, true) => HTBOTTOM,
                    _ => HTCLIENT,
                };
                if hit != HTCLIENT {
                    return LRESULT(hit as isize);
                }
            }
            LRESULT(if y < scale(32, s.dpi) && x < w - scale(144, s.dpi) {
                HTCAPTION
            } else {
                HTCLIENT
            } as isize)
        }
        WM_COMMAND => {
            let id = wp.0 & 0xffff;
            let notice = (wp.0 >> 16) & 0xffff;
            if (CARD_BASE..CARD_BASE + CARD_COUNT).contains(&id) && notice == BN_CLICKED as usize {
                if let Some(&index) = s.visible.get(id - CARD_BASE) {
                    let wid = s.cards[index].window.id;
                    s.actions.push_back(Action::OpenWindow(wid));
                    s.recents.retain(|id| *id != wid);
                    s.recents.insert(0, wid);
                }
            } else if (CARD_MENU_BASE..CARD_MENU_BASE + CARD_COUNT).contains(&id)
                && notice == BN_CLICKED as usize
            {
                let _ = PostMessageW(hwnd, SHOW_CARD_MENU, WPARAM(id - CARD_MENU_BASE), LPARAM(0));
            } else if id == SEARCH && notice == EN_CHANGE as usize {
                s.query = read_text(s.control(SEARCH)).to_lowercase();
                s.page = 0;
                s.layout();
            } else if notice == BN_CLICKED as usize {
                match id {
                    CONNECT => {
                        if s.active {
                            s.actions.push_back(Action::Disconnect);
                        } else if let Some(c) = s.selected() {
                            s.actions.push_back(Action::Connect(c));
                        }
                    }
                    MENU => {
                        let _ = PostMessageW(hwnd, SHOW_MENU, WPARAM(0), LPARAM(0));
                    }
                    NAV_CONNECTIONS | NAV_APPS | NAV_RECENTS | NAV_SETTINGS | TAB_APPS
                    | TAB_DESKTOP | TAB_FILES => {
                        s.view = id;
                        s.page = 0;
                        s.layout();
                    }
                    SCREEN => {
                        s.view = TAB_DESKTOP;
                        s.layout();
                    }
                    SORT => {
                        s.sort_name = !s.sort_name;
                        s.layout();
                    }
                    GRID | LIST => {
                        s.list = id == LIST;
                        s.page = 0;
                        s.layout();
                    }
                    PREVIOUS => {
                        s.page = s.page.saturating_sub(1);
                        s.layout();
                    }
                    NEXT => {
                        s.page += 1;
                        s.layout();
                    }
                    OPEN_ANY => {
                        s.view = TAB_APPS;
                        s.query.clear();
                        s.page = 0;
                        set_text(s.control(SEARCH), "");
                        s.layout();
                        let _ = SetFocus(s.control(SEARCH));
                    }
                    MORE_APPS | HELP => {
                        s.status="On your Mac, choose apps in Transom Host and start sharing. Connect here, then open an app card.".into();
                        s.invalidate();
                    }
                    MANUAL if !s.active => {
                        match Connection::manual(
                            &read_text(s.control(HOST)),
                            &read_text(s.control(CONTROL)),
                            &read_text(s.control(VIDEO)),
                        ) {
                            Ok(c) => s.actions.push_back(Action::Connect(c)),
                            Err(e) => {
                                s.status = e;
                                s.invalidate();
                            }
                        }
                    }
                    REFRESH => {
                        if s.scan.is_none() {
                            s.start_scan();
                        }
                    }
                    UPDATE => {
                        s.status = match launch_updater() {
                            Ok(()) => "Checking for updates…".into(),
                            Err(e) => e,
                        };
                        s.invalidate();
                    }
                    MINIMIZE | MAXIMIZE | CLOSE => {
                        let command = match id {
                            MINIMIZE => SC_MINIMIZE,
                            MAXIMIZE => {
                                if IsZoomed(hwnd).as_bool() {
                                    SC_RESTORE
                                } else {
                                    SC_MAXIMIZE
                                }
                            }
                            _ => SC_CLOSE,
                        };
                        let _ =
                            PostMessageW(hwnd, WM_SYSCOMMAND, WPARAM(command as usize), LPARAM(0));
                    }
                    _ => {}
                }
            }
            LRESULT(0)
        }
        WM_DRAWITEM => LRESULT(1),
        WM_SIZE => {
            s.layout();
            LRESULT(0)
        }
        WM_DPICHANGED => {
            s.dpi = (wp.0 & 0xffff) as u32;
            s.rebuild_font();
            let r = *(lp.0 as *const RECT);
            let _ = SetWindowPos(
                hwnd,
                None,
                r.left,
                r.top,
                r.right - r.left,
                r.bottom - r.top,
                SWP_NOZORDER | SWP_NOACTIVATE,
            );
            LRESULT(0)
        }
        WM_GETMINMAXINFO => {
            let m = &mut *(lp.0 as *mut MINMAXINFO);
            m.ptMinTrackSize = POINT {
                x: scale(1100, s.dpi),
                y: scale(720, s.dpi),
            };
            let monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
            let mut info = MONITORINFO {
                cbSize: std::mem::size_of::<MONITORINFO>() as u32,
                ..Default::default()
            };
            if GetMonitorInfoW(monitor, &mut info).as_bool() {
                m.ptMaxPosition = POINT {
                    x: info.rcWork.left - info.rcMonitor.left,
                    y: info.rcWork.top - info.rcMonitor.top,
                };
                m.ptMaxSize = POINT {
                    x: info.rcWork.right - info.rcWork.left,
                    y: info.rcWork.bottom - info.rcWork.top,
                };
            }
            LRESULT(0)
        }
        WM_PAINT => {
            s.paint();
            LRESULT(0)
        }
        WM_CTLCOLOREDIT => {
            let dc = HDC(wp.0 as *mut c_void);
            SetBkColor(dc, COLORREF(0x002C1D11));
            SetTextColor(dc, COLORREF(0x00FCF6F3));
            LRESULT(s.brush.0 as isize)
        }
        WM_ERASEBKGND => LRESULT(1),
        WM_CLOSE => {
            let _ = DestroyWindow(hwnd);
            LRESULT(0)
        }
        WM_DESTROY => {
            PostQuitMessage(0);
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wp, lp),
    }
}
unsafe fn create_controls(s: &mut State) {
    let instance = HINSTANCE(GetModuleHandleW(None).unwrap().0);
    let mut add = |class: PCWSTR, text: &str, id: usize, style: u32| {
        let title = wide(text);
        if let Ok(hwnd) = CreateWindowExW(
            if [SEARCH, HOST, CONTROL, VIDEO].contains(&id) {
                WS_EX_LAYERED
            } else {
                WS_EX_TRANSPARENT
            },
            class,
            PCWSTR(title.as_ptr()),
            WS_CHILD | WS_TABSTOP | WINDOW_STYLE(style),
            0,
            0,
            1,
            1,
            s.hwnd,
            HMENU(id as *mut c_void),
            instance,
            None,
        ) {
            let _ = SetWindowTheme(hwnd, w!(""), w!(""));
            if [SEARCH, HOST, CONTROL, VIDEO].contains(&id) {
                let _ = SetLayeredWindowAttributes(hwnd, COLORREF(0), 255, LWA_ALPHA);
            }
            if ![SEARCH, HOST, CONTROL, VIDEO].contains(&id) {
                let _ = SetWindowSubclass(hwnd, Some(button_proc), 1, 0);
            }
            s.controls.push(Control { hwnd, id });
        }
    };
    for (id, name) in [
        (CONNECT, "Connect"),
        (SCREEN, "Screen View"),
        (MENU, "Choose Mac and connection options"),
        (NAV_CONNECTIONS, "Connections"),
        (NAV_APPS, "Apps"),
        (NAV_RECENTS, "Recents"),
        (NAV_SETTINGS, "Settings"),
        (TAB_APPS, "Applications"),
        (TAB_DESKTOP, "Desktop"),
        (TAB_FILES, "Files"),
        (SORT, "Sort windows"),
        (GRID, "Grid view"),
        (LIST, "List view"),
        (PREVIOUS, "Previous"),
        (NEXT, "Next"),
        (OPEN_ANY, "Open Any App"),
        (MORE_APPS, "Share more apps"),
        (HELP, "Help"),
        (MANUAL, "Connect manually"),
        (UPDATE, "Check for updates"),
        (REFRESH, "Refresh Macs"),
        (MINIMIZE, "Minimize"),
        (MAXIMIZE, "Maximize or restore"),
        (CLOSE, "Close"),
    ] {
        add(w!("BUTTON"), name, id, BS_OWNERDRAW as u32);
    }
    for slot in 0..CARD_COUNT {
        add(
            w!("BUTTON"),
            "Open window",
            CARD_BASE + slot,
            BS_OWNERDRAW as u32,
        );
    }
    for slot in 0..CARD_COUNT {
        add(
            w!("BUTTON"),
            "Window options",
            CARD_MENU_BASE + slot,
            BS_OWNERDRAW as u32,
        );
    }
    for (id, value) in [
        (SEARCH, ""),
        (HOST, ""),
        (CONTROL, "47100"),
        (VIDEO, "47101"),
    ] {
        add(w!("EDIT"), value, id, ES_AUTOHSCROLL as u32);
    }
    let cue = wide("Search Mac apps…");
    SendMessageW(
        s.control(SEARCH),
        0x1501,
        WPARAM(0),
        LPARAM(cue.as_ptr() as isize),
    );
    for id in [HOST, SEARCH] {
        SendMessageW(s.control(id), EM_SETLIMITTEXT, WPARAM(253), LPARAM(0));
    }
    for id in [CONTROL, VIDEO] {
        SendMessageW(s.control(id), EM_SETLIMITTEXT, WPARAM(5), LPARAM(0));
    }
}
fn scale(n: i32, dpi: u32) -> i32 {
    n * dpi as i32 / 96
}
fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}
unsafe fn set_text(hwnd: HWND, s: &str) {
    let s = wide(s);
    let _ = SetWindowTextW(hwnd, PCWSTR(s.as_ptr()));
}
unsafe fn read_text(hwnd: HWND) -> String {
    let mut b = vec![0u16; GetWindowTextLengthW(hwnd) as usize + 1];
    let n = GetWindowTextW(hwnd, &mut b);
    String::from_utf16_lossy(&b[..n as usize])
}
pub fn show_error(hwnd: HWND, message: &str) {
    let s = wide(message);
    unsafe {
        MessageBoxW(
            hwnd,
            PCWSTR(s.as_ptr()),
            w!("Transom"),
            MB_OK | MB_ICONERROR,
        );
    }
}
fn launch_updater() -> Result<(), String> {
    std::env::current_exe()
        .and_then(|p| {
            std::process::Command::new(p.with_file_name("transom-updater.exe"))
                .args(["--check", "--current-version", env!("CARGO_PKG_VERSION")])
                .spawn()
        })
        .map(|_| ())
        .map_err(|e| {
            format!("Could not start the updater. Install Transom using its setup file. {e}")
        })
}

// Keep native button semantics and accessibility while drawing every visual on
// one alpha-correct D2D surface. GDI child painting destroys acrylic's alpha.
unsafe extern "system" fn button_proc(
    hwnd: HWND,
    msg: u32,
    wp: WPARAM,
    lp: LPARAM,
    _id: usize,
    _data: usize,
) -> LRESULT {
    match msg {
        WM_PAINT => {
            let mut ps = PAINTSTRUCT::default();
            let _ = BeginPaint(hwnd, &mut ps);
            let _ = EndPaint(hwnd, &ps);
            LRESULT(0)
        }
        WM_ERASEBKGND => LRESULT(1),
        WM_MOUSEMOVE => {
            let mut tracking = TRACKMOUSEEVENT {
                cbSize: std::mem::size_of::<TRACKMOUSEEVENT>() as u32,
                dwFlags: TME_LEAVE,
                hwndTrack: hwnd,
                dwHoverTime: 0,
            };
            let _ = TrackMouseEvent(&mut tracking);
            if let Ok(parent) = GetParent(hwnd) {
                let _ = InvalidateRect(parent, None, false);
            }
            DefSubclassProc(hwnd, msg, wp, lp)
        }
        WM_MOUSELEAVE => {
            if let Ok(parent) = GetParent(hwnd) {
                let _ = InvalidateRect(parent, None, false);
            }
            DefSubclassProc(hwnd, msg, wp, lp)
        }
        WM_NCDESTROY => {
            let _ = RemoveWindowSubclass(hwnd, Some(button_proc), 1);
            DefSubclassProc(hwnd, msg, wp, lp)
        }
        _ => {
            let result = DefSubclassProc(hwnd, msg, wp, lp);
            if [
                WM_SETFOCUS,
                WM_KILLFOCUS,
                BM_SETSTATE,
                BM_SETSTYLE,
                WM_ENABLE,
            ]
            .contains(&msg)
            {
                if let Ok(parent) = GetParent(hwnd) {
                    let _ = InvalidateRect(parent, None, false);
                }
            }
            result
        }
    }
}
