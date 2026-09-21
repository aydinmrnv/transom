use windows::Win32::UI::Shell::{DefSubclassProc, RemoveWindowSubclass, SetWindowSubclass};
// Native acrylic dashboard; controls queue actions for the application pump.
use super::{
    gallery::{Card, CARD_BASE, CARD_COUNT},
    glass::{self, rect, Glass, Paint},
};
use crate::{
    connections::{self, Connection},
    model::Window,
    wire::Size,
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
const NAV_CONNECTIONS: usize = 10;
const NAV_APPS: usize = 11;
const NAV_SETTINGS: usize = 13;
const SEARCH: usize = 30;
const SORT: usize = 31;
const GRID: usize = 32;
const LIST: usize = 33;
const PREVIOUS: usize = 40;
const NEXT: usize = 41;
const HOST: usize = 50;
const CONTROL: usize = 51;
const VIDEO: usize = 52;
const MANUAL: usize = 53;
const UPDATE: usize = 54;
const REFRESH: usize = 55;
const MINIMIZE: usize = 60;
const MAXIMIZE: usize = 61;
const CLOSE: usize = 62;
const SHOW_CARD_MENU: u32 = WM_APP + 31;
const SHOW_SORT_MENU: u32 = WM_APP + 32;
const CARD_MENU_BASE: usize = 2000;
const MAC_BASE: usize = 3000;
const FORGET: usize = 56;
const ADD_MAC: usize = 57;
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
    visible: Vec<usize>,
    page: usize,
    page_size: usize,
    query: String,
    view: usize,
    list: bool,
    sort_name: bool,
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
            visible: vec![],
            page: 0,
            page_size: 8,
            query: String::new(),
            view: NAV_APPS,
            list: false,
            sort_name: true,
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
                        let count = self.state.nearby.len();
                        format!(
                            "{} {} available nearby",
                            count,
                            if count == 1 { "Mac" } else { "Macs" }
                        )
                    };
                    unsafe {
                        self.state.rebuild_rows();
                    }
                }
                Err(e) => self.state.discovery = format!("Discovery unavailable: {e}"),
            }
            self.state.next_scan = Instant::now() + Duration::from_secs(8);
            unsafe {
                self.state.layout();
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
        if connected && !self.state.connected {
            self.state.view = NAV_APPS;
            self.state.page = 0;
        }
        self.state.connected = connected;
        unsafe {
            self.state.layout();
        }
    }
    pub fn remember(&mut self, c: Connection) {
        connections::remember(&mut self.state.saved, c.clone());
        if let Err(e) = connections::save(&self.state.preferences, &self.state.saved) {
            self.state.discovery = format!("Connected, but could not save this Mac: {e}");
        }
        unsafe {
            self.state.rebuild_rows();
        }
        if let Some(i) = self
            .state
            .rows
            .iter()
            .position(|row| row.same_destination(&c))
        {
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
        unsafe {
            self.state.layout();
        }
    }
    pub fn previews_due(&self) -> bool {
        self.state.view == NAV_APPS
            && !self.state.cards.is_empty()
            && self.state.last_preview.elapsed() >= Duration::from_millis(250)
            && unsafe { IsWindowVisible(self.hwnd).as_bool() && !IsIconic(self.hwnd).as_bool() }
    }
    pub fn update_previews(&mut self, pixels: &[u8], display: Size, native_display: Size) {
        self.state.last_preview = Instant::now();
        for c in &mut self.state.cards {
            c.update_preview_atlas(pixels, display, native_display);
        }
        unsafe {
            for slot in 0..CARD_COUNT {
                let _ = InvalidateRect(self.state.control(CARD_BASE + slot), None, false);
            }
            self.state.invalidate();
        }
    }
    pub fn dialog_message(&mut self, message: &MSG) -> bool {
        unsafe {
            // Enter in search opens its only result; never triggers Disconnect.
            if message.message == WM_KEYDOWN
                && message.wParam.0 == 13
                && GetFocus() == self.state.control(SEARCH)
            {
                let matches = self.state.matches();
                if matches.len() == 1 {
                    self.state
                        .actions
                        .push_back(Action::OpenWindow(self.state.cards[matches[0]].window.id));
                }
                return true;
            }
            if message.message == WM_KEYDOWN
                && message.wParam.0 == 13
                && [HOST, CONTROL, VIDEO]
                    .iter()
                    .any(|id| GetFocus() == self.state.control(*id))
            {
                if !self.state.active {
                    let _ = PostMessageW(self.hwnd, WM_COMMAND, WPARAM(MANUAL), LPARAM(0));
                }
                return true;
            }
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
        unsafe {
            self.layout();
        }
        std::thread::spawn(move || {
            let _ = tx.send(crate::discovery::scan());
        });
    }
    unsafe fn rebuild_rows(&mut self) {
        let selected = self.selected();
        self.rows = connections::available(&self.nearby, &self.saved);
        self.selected_device = selected
            .and_then(|old| self.rows.iter().position(|c| c.same_destination(&old)))
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
            .filter(|(_, c)| c.window.title.to_lowercase().contains(&self.query))
            .map(|(i, _)| i)
            .collect();
        if self.sort_name {
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
        self.place(NAV_APPS, 10, 112, 210, 50, true);
        self.place(NAV_CONNECTIONS, 10, 164, 210, 50, true);
        self.place(NAV_SETTINGS, 10, h - 114, 210, 50, true);
        self.place(MINIMIZE, w - 140, 0, 46, 32, true);
        self.place(MAXIMIZE, w - 94, 0, 46, 32, true);
        self.place(CLOSE, w - 48, 0, 46, 32, true);
        self.place(CONNECT, w - 216, 94, 174, 48, true);
        let gallery = self.view == NAV_APPS;
        let macs = self.view == NAV_CONNECTIONS;
        self.place(SEARCH, 280, 299, (w - 590).min(440), 27, gallery);
        self.place(SORT, w - 280, 294, 164, 36, gallery);
        self.place(GRID, w - 104, 294, 36, 36, gallery);
        self.place(LIST, w - 62, 294, 36, 36, gallery);
        set_text(
            self.control(SORT),
            if self.sort_name {
                "Sort: Name"
            } else {
                "Sort: Host order"
            },
        );
        self.place(ADD_MAC, w - 366, 226, 154, 40, macs);
        self.place(REFRESH, w - 198, 226, 172, 40, macs);
        self.place(FORGET, w - 216, 292, 190, 36, macs);
        let can_forget = self
            .selected()
            .is_some_and(|c| self.saved.iter().any(|n| n.same_destination(&c)));
        let _ = EnableWindow(self.control(FORGET), can_forget && !self.active);
        let _ = EnableWindow(self.control(REFRESH), self.scan.is_none());
        let cols = ((w - SIDEBAR - 30) / 274).clamp(1, 4) as usize;
        let rows = ((h - 348 - 62) / 204).clamp(1, 3) as usize;
        self.page_size = if macs {
            ((h - 410) / 88).clamp(1, CARD_COUNT as i32) as usize
        } else if self.list {
            ((h - 422) / 84).clamp(1, 12) as usize
        } else {
            (cols * rows).min(CARD_COUNT)
        };
        let matches = if macs {
            (0..self.rows.len()).collect()
        } else {
            self.matches()
        };
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
        for slot in 0..CARD_COUNT {
            if let Some(&i) = self.visible.get(slot).filter(|_| macs) {
                set_text(
                    self.control(MAC_BASE + slot),
                    &format!("Select {} ({})", self.rows[i].name, self.rows[i].host),
                );
                self.place(
                    MAC_BASE + slot,
                    246,
                    348 + slot as i32 * 88,
                    w - 274,
                    76,
                    true,
                );
                let _ = EnableWindow(self.control(MAC_BASE + slot), !self.active);
            } else {
                self.place(MAC_BASE + slot, 0, 0, 1, 1, false);
            }
        }
        let pages = (gallery || macs) && matches.len() > self.page_size;
        self.place(PREVIOUS, w - 240, h - 52, 98, 32, pages);
        self.place(NEXT, w - 132, h - 52, 98, 32, pages);
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
        self.place(UPDATE, 800, 380, 220, 40, settings);
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
            0.12,
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
        let hero = rect(236., 48., w - 260., 148.);
        p.gradient(hero, 12., 0x233044, 0x111C2B, 0.67);
        p.stroke(hero, 12., glass::LINE, 0.65, 0.8);
        if self.active {
            p.text(
                super::input::DISCONNECT_SHORTCUT,
                rect(w - 240., 149., 222., 24.),
                11.,
                false,
                glass::MUTED,
                true,
            );
        }
        let selected = self.selected();
        let name = selected
            .as_ref()
            .map(|c| c.name.as_str())
            .unwrap_or("No Mac selected");
        // The protocol does not identify hardware. Only use Studio artwork when
        // the selected host's name identifies it; otherwise use a neutral Mac.
        if name.to_lowercase().contains("studio") {
            p.mac(rect(260., 60., 184., 128.));
        } else {
            p.icon("\u{E7F4}", rect(282., 80., 136., 90.), 52., glass::MUTED);
        }
        p.text(
            name,
            rect(474., 72., w - 720., 36.),
            24.,
            true,
            glass::TEXT,
            false,
        );
        let nearby = selected
            .as_ref()
            .is_some_and(|c| self.nearby.iter().any(|n| n.same_destination(c)));
        let label = if self.connected {
            "Connected"
        } else if self.active {
            "Connecting…"
        } else if nearby {
            "Available nearby"
        } else if selected.is_some() {
            "Saved Mac"
        } else {
            "Select a device in Macs"
        };
        p.dot(
            479.,
            125.,
            4.,
            if self.connected {
                glass::GREEN
            } else {
                glass::MUTED
            },
        );
        p.text(
            label,
            rect(492., 110., w - 740., 28.),
            13.,
            false,
            glass::MUTED,
            false,
        );
        p.text(
            selected.as_ref().map(|c| c.host.as_str()).unwrap_or(""),
            rect(474., 145., w - 720., 24.),
            12.,
            false,
            glass::MUTED,
            false,
        );

        if self.view == NAV_APPS {
            p.text(
                "Shared windows",
                rect(246., 220., 460., 36.),
                22.,
                true,
                glass::TEXT,
                false,
            );
            let detail = if self.connected {
                format!(
                    "{} windows · {} open on this PC",
                    self.cards.len(),
                    self.cards.iter().filter(|c| c.opened).count()
                )
            } else {
                "Connect to your Mac to browse its shared windows.".into()
            };
            p.text(
                &detail,
                rect(246., 256., w - 280., 26.),
                13.,
                false,
                glass::MUTED,
                false,
            );
            p.fill(
                rect(246., 291., (w - 556.).min(474.), 44.),
                8.,
                0x111D2C,
                0.96,
            );
            p.stroke(
                rect(246., 291., (w - 556.).min(474.), 44.),
                8.,
                glass::LINE,
                0.8,
                0.8,
            );
            p.icon("\u{E721}", rect(252., 300., 24., 24.), 15., glass::MUTED);
            if self.visible.is_empty() {
                let (title, detail) = if !self.query.is_empty() {
                    ("No matching windows", "Try another window title.")
                } else if self.connected {
                    (
                        "No shared windows",
                        "On your Mac, select apps with open windows in Transom Host.",
                    )
                } else {
                    (
                        "Connect to a Mac",
                        "Choose a nearby or saved device in Macs, then connect.",
                    )
                };
                p.icon("\u{E8A7}", rect(270., 403., 48., 48.), 28., glass::MUTED);
                p.text(
                    title,
                    rect(336., 399., w - 388., 40.),
                    20.,
                    true,
                    glass::TEXT,
                    false,
                );
                p.text(
                    detail,
                    rect(336., 443., w - 388., 30.),
                    14.,
                    false,
                    glass::MUTED,
                    false,
                );
            }
        } else if self.view == NAV_CONNECTIONS {
            p.text(
                "Macs",
                rect(246., 220., 430., 36.),
                22.,
                true,
                glass::TEXT,
                false,
            );
            p.text(
                if self.active {
                    "Disconnect before selecting another Mac."
                } else {
                    "Select a Mac, then connect. Nearby Macs appear automatically."
                },
                rect(246., 265., w - 500., 28.),
                13.,
                false,
                glass::MUTED,
                false,
            );
            p.text(
                if self.scan.is_some() {
                    "Looking for nearby Macs…"
                } else {
                    &self.discovery
                },
                rect(246., 303., w - 490., 25.),
                12.,
                false,
                glass::MUTED,
                false,
            );
            if self.rows.is_empty() {
                p.text(
                    "No Macs found",
                    rect(270., 390., w - 320., 40.),
                    20.,
                    true,
                    glass::TEXT,
                    false,
                );
                p.text(
                    "Start Transom Host on your Mac, or add its hostname manually.",
                    rect(270., 436., w - 320., 30.),
                    14.,
                    false,
                    glass::MUTED,
                    false,
                );
            }
        } else {
            p.text(
                "Settings",
                rect(268., 238., 600., 36.),
                22.,
                true,
                glass::TEXT,
                false,
            );
            p.text(
                "Manual connection",
                rect(268., 300., 600., 30.),
                16.,
                true,
                glass::TEXT,
                false,
            );
            p.text(
                "Use this when your Mac does not appear in the nearby list.",
                rect(268., 335., 680., 28.),
                13.,
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
                if self.active {
                    "Disconnect to start a manual connection."
                } else {
                    "Leave video blank for control only."
                },
                rect(268., 610., 700., 30.),
                13.,
                false,
                glass::MUTED,
                false,
            );
            p.text(
                "Updates",
                rect(800., 300., 220., 30.),
                16.,
                true,
                glass::TEXT,
                false,
            );
            p.text(
                concat!("Transom ", env!("CARGO_PKG_VERSION")),
                rect(800., 335., 220., 28.),
                13.,
                false,
                glass::MUTED,
                false,
            );
            for (x, y, ww) in [(262., 396., 482.), (262., 490., 222.), (494., 490., 250.)] {
                p.stroke(rect(x, y, ww, 48.), 8., glass::LINE, 1., 1.);
            }
        }
        let pages = self.view != NAV_SETTINGS
            && if self.view == NAV_CONNECTIONS {
                self.rows.len()
            } else {
                self.matches().len()
            } > self.page_size;
        p.text(
            &self.status,
            rect(246., h - 48., w - if pages { 520. } else { 280. }, 28.),
            12.,
            false,
            glass::MUTED,
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
        } else if (MAC_BASE..MAC_BASE + CARD_COUNT).contains(&id) {
            if let Some(&i) = self.visible.get(id - MAC_BASE) {
                let c = &self.rows[i];
                let selected = i == self.selected_device;
                p.fill(
                    rect(1., 1., w - 2., h - 2.),
                    10.,
                    if selected { 0x203858 } else { 0x182333 },
                    0.85,
                );
                p.stroke(
                    rect(1., 1., w - 2., h - 2.),
                    10.,
                    if selected { 0x558FFF } else { glass::LINE },
                    0.9,
                    1.,
                );
                p.icon("\u{E7F4}", rect(18., 18., 40., 40.), 25., glass::MUTED);
                p.text(
                    &c.name,
                    rect(78., 10., w - 270., 29.),
                    16.,
                    true,
                    glass::TEXT,
                    false,
                );
                p.text(
                    &format!(
                        "{}  ·  {} / {}",
                        c.host,
                        c.control_port,
                        c.video_port
                            .map(|n| n.to_string())
                            .unwrap_or_else(|| "no video".into())
                    ),
                    rect(78., 40., w - 270., 23.),
                    12.,
                    false,
                    glass::MUTED,
                    false,
                );
                let nearby = self.nearby.iter().any(|n| n.same_destination(c));
                let status = if selected && self.connected {
                    "Connected"
                } else if selected && self.active {
                    "Connecting…"
                } else if selected {
                    "Selected"
                } else if nearby {
                    "Nearby"
                } else {
                    "Saved"
                };
                p.text(
                    status,
                    rect(w - 175., 20., 150., 36.),
                    13.,
                    false,
                    if selected { 0x8BB4FF } else { glass::MUTED },
                    true,
                );
            }
        } else if [NAV_CONNECTIONS, NAV_APPS, NAV_SETTINGS].contains(&id) {
            let active = self.view == id;
            if active {
                p.fill(rect(1., 1., w - 2., h - 2.), 10., 0x20385C, 0.9);
                p.fill(rect(1., 12., 3., h - 24.), 1.5, 0x4A86FF, 1.);
            }
            let (icon, name) = match id {
                NAV_CONNECTIONS => ("\u{E977}", "Macs"),
                NAV_APPS => ("\u{E8A7}", "Windows"),
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
            let primary = (id == CONNECT || id == MANUAL) && !disabled;
            let bare = id == SORT;
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
                GRID => p.icon("\u{E80A}", rect(0., 0., w, h), 17., col),
                LIST => p.icon("\u{E8FD}", rect(0., 0., w, h), 17., col),
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
    if msg == SHOW_SORT_MENU {
        let by_name = (*ptr).sort_name;
        if let Ok(menu) = CreatePopupMenu() {
            let _ = AppendMenuW(
                menu,
                MF_STRING | if by_name { MF_CHECKED } else { MF_UNCHECKED },
                1,
                w!("Name (A–Z)"),
            );
            let _ = AppendMenuW(
                menu,
                MF_STRING | if by_name { MF_UNCHECKED } else { MF_CHECKED },
                2,
                w!("Host order"),
            );
            let mut anchor = RECT::default();
            let _ = GetWindowRect((*ptr).control(SORT), &mut anchor);
            let choice = TrackPopupMenu(
                menu,
                TPM_RETURNCMD | TPM_NONOTIFY,
                anchor.left,
                anchor.bottom,
                0,
                hwnd,
                None,
            )
            .0;
            let _ = DestroyMenu(menu);
            if choice != 0 {
                (*ptr).sort_name = choice == 1;
                (*ptr).page = 0;
                (*ptr).layout();
            }
        }
        return LRESULT(0);
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
                } else if choice == 2 {
                    state.actions.push_back(Action::HideWindow(id));
                }
            }
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
                }
            } else if (CARD_MENU_BASE..CARD_MENU_BASE + CARD_COUNT).contains(&id)
                && notice == BN_CLICKED as usize
            {
                let _ = PostMessageW(hwnd, SHOW_CARD_MENU, WPARAM(id - CARD_MENU_BASE), LPARAM(0));
            } else if (MAC_BASE..MAC_BASE + CARD_COUNT).contains(&id)
                && notice == BN_CLICKED as usize
                && !s.active
            {
                if let Some(&i) = s.visible.get(id - MAC_BASE) {
                    s.selected_device = i;
                    s.layout();
                }
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
                    NAV_CONNECTIONS | NAV_APPS | NAV_SETTINGS => {
                        s.view = id;
                        s.page = 0;
                        s.layout();
                    }
                    ADD_MAC => {
                        s.view = NAV_SETTINGS;
                        s.page = 0;
                        s.layout();
                        let _ = SetFocus(s.control(HOST));
                    }
                    FORGET if !s.active => {
                        if let Some(c) = s.selected() {
                            s.saved.retain(|n| !n.same_destination(&c));
                            if let Err(e) = connections::save(&s.preferences, &s.saved) {
                                s.status = format!("Could not save connections: {e}");
                            } else {
                                s.status =
                                    "Saved connection removed. Nearby Macs remain discoverable."
                                        .into();
                            }
                            s.rebuild_rows();
                        }
                    }
                    SORT => {
                        let _ = PostMessageW(hwnd, SHOW_SORT_MENU, WPARAM(0), LPARAM(0));
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
        (NAV_CONNECTIONS, "Macs"),
        (NAV_APPS, "Windows"),
        (NAV_SETTINGS, "Settings"),
        (SORT, "Sort: Name"),
        (GRID, "Grid view"),
        (LIST, "List view"),
        (PREVIOUS, "Previous"),
        (NEXT, "Next"),
        (MANUAL, "Connect manually"),
        (UPDATE, "Check for updates"),
        (REFRESH, "Refresh Macs"),
        (FORGET, "Forget saved Mac"),
        (ADD_MAC, "Add Mac manually"),
        (MINIMIZE, "Minimize"),
        (MAXIMIZE, "Maximize or restore"),
        (CLOSE, "Close"),
    ] {
        add(w!("BUTTON"), name, id, BS_OWNERDRAW as u32);
    }
    for slot in 0..CARD_COUNT {
        add(
            w!("BUTTON"),
            "Select Mac",
            MAC_BASE + slot,
            BS_OWNERDRAW as u32,
        );
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
    let cue = wide("Search windows…");
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
    hovered: usize,
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
            if hovered == 0 {
                let _ = SetWindowSubclass(hwnd, Some(button_proc), 1, 1);
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
            }
            DefSubclassProc(hwnd, msg, wp, lp)
        }
        WM_MOUSELEAVE => {
            let _ = SetWindowSubclass(hwnd, Some(button_proc), 1, 0);
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
