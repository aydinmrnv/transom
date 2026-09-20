//! Persistent native dashboard. Workers do networking; wndproc queues actions.
use super::gallery::{self, Card, CARD_BASE, CARD_COUNT};
use crate::connections::{self, Connection};
use crate::{model::Window, wire::Size};
use std::{
    collections::VecDeque,
    ffi::c_void,
    path::PathBuf,
    sync::mpsc,
    time::{Duration, Instant},
};
use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::{SetWindowTheme, DRAWITEMSTRUCT, EM_SETLIMITTEXT};
use windows::Win32::UI::HiDpi::{AdjustWindowRectExForDpi, GetDpiForWindow};
use windows::Win32::UI::Input::KeyboardAndMouse::{EnableWindow, SetFocus};
use windows::Win32::UI::WindowsAndMessaging::*;

const CLASS: PCWSTR = w!("TransomDashboard");
const CONNECT: usize = 1;
const DISCONNECT: usize = 2;
const DEVICES: usize = 101;
const REFRESH: usize = 102;
const FORGET: usize = 103;
const MANUAL: usize = 104;
const UPDATE: usize = 105;
const HOST: usize = 106;
const CONTROL: usize = 107;
const VIDEO: usize = 108;
const STATUS: usize = 109;
const DISCOVERY: usize = 110;
const SEARCH: usize = 111;
const PREVIOUS: usize = 112;
const NEXT: usize = 113;
const ADVANCED: usize = 114;
const BG: COLORREF = gallery::CANVAS;
const TEXT: COLORREF = COLORREF(0x003C3027);

pub enum Action {
    Connect(Connection),
    Disconnect,
    OpenWindow(u64),
}
struct Control {
    hwnd: HWND,
    id: usize,
    rect: (i32, i32, i32, i32),
    font: usize,
    _stretch: bool,
}
struct State {
    controls: Vec<Control>,
    fonts: [HFONT; 3],
    brush: HBRUSH,
    actions: VecDeque<Action>,
    saved: Vec<Connection>,
    nearby: Vec<Connection>,
    rows: Vec<Connection>,
    preferences: PathBuf,
    scan: Option<mpsc::Receiver<std::io::Result<Vec<Connection>>>>,
    next_scan: Instant,
    active: bool,
    status: String,
    dpi: u32,
    cards: Vec<Card>,
    visible: Vec<usize>,
    page: usize,
    page_size: usize,
    query: String,
    manual: bool,
    hwnd: HWND,
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
            Ok(s) => (s, "Choose a nearby Mac, then connect.".into()),
            Err(e) => (vec![], format!("Could not load saved Macs: {e}")),
        };
        let mut state = Box::new(State {
            controls: vec![],
            fonts: [HFONT::default(); 3],
            brush: unsafe { CreateSolidBrush(BG) },
            actions: VecDeque::new(),
            saved,
            nearby: vec![],
            rows: vec![],
            preferences,
            scan: None,
            next_scan: Instant::now(),
            active: false,
            status,
            dpi: 96,
            cards: vec![],
            visible: vec![],
            page: 0,
            page_size: 4,
            query: String::new(),
            manual: false,
            hwnd: HWND::default(),
            last_preview: Instant::now() - Duration::from_secs(1),
        });
        let hwnd = unsafe {
            CreateWindowExW(
                WS_EX_APPWINDOW | WS_EX_CONTROLPARENT,
                CLASS,
                w!("Transom"),
                WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
                CW_USEDEFAULT,
                CW_USEDEFAULT,
                780,
                760,
                None,
                None,
                HINSTANCE(instance.0),
                Some((&mut *state as *mut State).cast::<c_void>()),
            )?
        };
        unsafe {
            state.hwnd = hwnd;
            state.dpi = GetDpiForWindow(hwnd).max(96);
            state.rebuild_fonts();
            let mut rect = RECT {
                left: 0,
                top: 0,
                right: scale(1040, state.dpi),
                bottom: scale(700, state.dpi),
            };
            let _ = AdjustWindowRectExForDpi(
                &mut rect,
                WS_OVERLAPPEDWINDOW,
                false,
                WS_EX_APPWINDOW | WS_EX_CONTROLPARENT,
                state.dpi,
            );
            let _ = SetWindowPos(
                hwnd,
                None,
                0,
                0,
                rect.right - rect.left,
                rect.bottom - rect.top,
                SWP_NOMOVE | SWP_NOZORDER,
            );
            state.layout(hwnd);
            state.rebuild_rows();
            let _ = ShowWindow(hwnd, SW_SHOW);
            let _ = SetFocus(state.control(DEVICES));
        }
        Ok(Self { hwnd, state })
    }
    pub fn tick(&mut self) -> Option<Action> {
        if let Some(rx) = &self.state.scan {
            if let Ok(result) = rx.try_recv() {
                self.state.scan = None;
                match result {
                    Ok(found) => {
                        self.state.nearby = found;
                        let n = self.state.nearby.len();
                        unsafe {
                            set_text(
                                self.state.control(DISCOVERY),
                                &if n == 0 {
                                    "No nearby Macs yet. Start sharing in Transom Host on your Mac."
                                        .into()
                                } else {
                                    format!(
                                        "{n} Mac{} available on your network",
                                        if n == 1 { "" } else { "s" }
                                    )
                                },
                            );
                            self.state.rebuild_rows();
                        }
                    }
                    Err(e) => unsafe {
                        set_text(
                            self.state.control(DISCOVERY),
                            &format!("Discovery unavailable: {e}"),
                        );
                    },
                }
                self.state.next_scan = Instant::now() + Duration::from_secs(8);
            }
        }
        if self.state.scan.is_none() && Instant::now() >= self.state.next_scan {
            self.state.start_scan();
        }
        self.state.actions.pop_front()
    }
    pub fn set_status(&mut self, text: &str, active: bool) {
        if self.state.status != text {
            self.state.status = text.into();
            unsafe {
                set_text(self.state.control(STATUS), text);
            }
        }
        if self.state.active != active {
            unsafe {
                let _ = InvalidateRect(self.hwnd, None, false);
            }
        }
        self.state.active = active;
        unsafe {
            let _ = EnableWindow(
                self.state.control(CONNECT),
                !active && !self.state.rows.is_empty(),
            );
            let _ = EnableWindow(self.state.control(MANUAL), !active);
            let _ = EnableWindow(self.state.control(DISCONNECT), active);
        }
    }
    pub fn remember(&mut self, c: Connection) {
        connections::remember(&mut self.state.saved, c);
        if let Err(e) = connections::save(&self.state.preferences, &self.state.saved) {
            unsafe {
                set_text(
                    self.state.control(DISCOVERY),
                    &format!("Connected, but could not save this Mac: {e}"),
                );
            }
        }
        unsafe {
            self.state.rebuild_rows();
        }
    }
    pub fn set_windows(&mut self, windows: Vec<(Window, bool)>) {
        let mut old = std::mem::take(&mut self.state.cards);
        self.state.cards = windows
            .into_iter()
            .map(|(w, opened)| {
                if let Some(index) = old.iter().position(|c| c.window.id == w.id) {
                    let mut card = old.remove(index);
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
            self.state.layout(self.hwnd);
        }
    }
    pub fn update_previews(&mut self, pixels: &[u8], display: Size) {
        if self.state.last_preview.elapsed() < Duration::from_millis(250) {
            return;
        }
        self.state.last_preview = Instant::now();
        for card in &mut self.state.cards {
            card.update_preview(pixels, display);
        }
        unsafe {
            for slot in 0..CARD_COUNT {
                let _ = InvalidateRect(self.state.control(CARD_BASE + slot), None, false);
            }
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
            for font in self.state.fonts {
                let _ = DeleteObject(font);
            }
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
    fn start_scan(&mut self) {
        let (tx, rx) = mpsc::channel();
        self.scan = Some(rx);
        std::thread::spawn(move || {
            let _ = tx.send(crate::discovery::scan());
        });
        unsafe {
            set_text(
                self.control(DISCOVERY),
                "Looking for Macs on your local network…",
            );
        }
    }
    unsafe fn selected(&self) -> Option<Connection> {
        let i = SendMessageW(self.control(DEVICES), LB_GETCURSEL, WPARAM(0), LPARAM(0)).0;
        if i < 0 {
            None
        } else {
            self.rows.get(i as usize).cloned()
        }
    }
    unsafe fn rebuild_rows(&mut self) {
        let selected = self.selected().map(|c| c.id);
        let mut rows = self.nearby.clone();
        for saved in &self.saved {
            if !rows.iter().any(|r| r.id == saved.id) {
                rows.push(saved.clone());
            }
        }
        self.rows = rows;
        let list = self.control(DEVICES);
        SendMessageW(list, WM_SETREDRAW, WPARAM(0), LPARAM(0));
        SendMessageW(list, LB_RESETCONTENT, WPARAM(0), LPARAM(0));
        for c in &self.rows {
            let online = self.nearby.iter().any(|n| n.id == c.id);
            let title = wide(&format!(
                "{}     ·     {}",
                c.name,
                if online {
                    "Nearby"
                } else {
                    "Saved — check availability"
                }
            ));
            SendMessageW(
                list,
                LB_ADDSTRING,
                WPARAM(0),
                LPARAM(title.as_ptr() as isize),
            );
        }
        let index = selected
            .and_then(|id| self.rows.iter().position(|c| c.id == id))
            .unwrap_or(0);
        SendMessageW(list, LB_SETCURSEL, WPARAM(index), LPARAM(0));
        SendMessageW(list, WM_SETREDRAW, WPARAM(1), LPARAM(0));
        let _ = InvalidateRect(list, None, true);
        let _ = EnableWindow(self.control(CONNECT), !self.active && !self.rows.is_empty());
        let _ = EnableWindow(self.control(FORGET), !self.saved.is_empty());
    }
    unsafe fn rebuild_fonts(&mut self) {
        let old = self.fonts;
        for (i, (size, weight)) in [(16, 400), (30, 600), (14, 600)].into_iter().enumerate() {
            self.fonts[i] = CreateFontW(
                -scale(size, self.dpi),
                0,
                0,
                0,
                weight,
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
        }
        for c in &self.controls {
            SendMessageW(
                c.hwnd,
                WM_SETFONT,
                WPARAM(self.fonts[c.font].0 as usize),
                LPARAM(1),
            );
        }
        for f in old {
            let _ = DeleteObject(f);
        }
    }
    unsafe fn layout(&mut self, hwnd: HWND) {
        let mut r = RECT::default();
        let _ = GetClientRect(hwnd, &mut r);
        let width = r.right * 96 / self.dpi as i32;
        let height = r.bottom * 96 / self.dpi as i32;
        for c in &self.controls {
            if c.id >= CARD_BASE {
                continue;
            }
            let (x, y, w, h) = c.rect;
            let (x, y, w, h) = match c.id {
                STATUS => (272, height - 75, width - 304, 55),
                SEARCH => (width - 272, 36, 240, 34),
                PREVIOUS => (width - 234, height - 117, 94, 30),
                NEXT => (width - 128, height - 117, 94, 30),
                UPDATE => (20, height - 52, 212, 32),
                _ => (x, y, w, h),
            };
            let advanced = matches!(c.id, HOST | CONTROL | VIDEO | MANUAL | 201 | 202 | 203);
            let _ = ShowWindow(
                c.hwnd,
                if advanced && !self.manual {
                    SW_HIDE
                } else {
                    SW_SHOW
                },
            );
            let _ = MoveWindow(
                c.hwnd,
                scale(x, self.dpi),
                scale(y, self.dpi),
                scale(w, self.dpi),
                scale(h, self.dpi),
                true,
            );
        }
        let columns = ((width - 288) / 260).clamp(1, 4) as usize;
        let rows = ((height - 260) / 224).clamp(1, 3) as usize;
        self.page_size = (columns * rows).min(CARD_COUNT);
        let matches: Vec<_> = self
            .cards
            .iter()
            .enumerate()
            .filter(|(_, c)| c.window.title.to_lowercase().contains(&self.query))
            .map(|(i, _)| i)
            .collect();
        self.page = self
            .page
            .min(matches.len().saturating_sub(1) / self.page_size);
        self.visible = matches
            .iter()
            .skip(self.page * self.page_size)
            .take(self.page_size)
            .copied()
            .collect();
        let card_width = (width - 288 - (columns as i32 - 1) * 16) / columns as i32;
        for slot in 0..CARD_COUNT {
            let child = self.control(CARD_BASE + slot);
            if let Some(&index) = self.visible.get(slot) {
                set_text(child, &gallery::accessible_title(&self.cards[index]));
                let x = 272 + (slot % columns) as i32 * (card_width + 16);
                let y = 138 + (slot / columns) as i32 * 224;
                let _ = MoveWindow(
                    child,
                    scale(x, self.dpi),
                    scale(y, self.dpi),
                    scale(card_width, self.dpi),
                    scale(208, self.dpi),
                    true,
                );
                let _ = ShowWindow(child, SW_SHOW);
                let _ = InvalidateRect(child, None, false);
            } else {
                let _ = ShowWindow(child, SW_HIDE);
            }
        }
        let _ = EnableWindow(self.control(PREVIOUS), self.page > 0);
        let _ = EnableWindow(
            self.control(NEXT),
            (self.page + 1) * self.page_size < matches.len(),
        );
        let _ = InvalidateRect(hwnd, None, false);
    }
    unsafe fn paint(&self, hwnd: HWND) {
        let mut ps = PAINTSTRUCT::default();
        let dc = BeginPaint(hwnd, &mut ps);
        let mut r = RECT::default();
        let _ = GetClientRect(hwnd, &mut r);
        gallery::fill(dc, &r, BG);
        gallery::fill(
            dc,
            &RECT {
                right: scale(252, self.dpi),
                ..r
            },
            gallery::SIDEBAR,
        );
        let line = |text: &str, x: i32, y: i32, w: i32, h: i32, font: usize, color: COLORREF| {
            gallery::label(
                dc,
                self.fonts[font],
                text,
                RECT {
                    left: scale(x, self.dpi),
                    top: scale(y, self.dpi),
                    right: scale(x + w, self.dpi),
                    bottom: scale(y + h, self.dpi),
                },
                color,
                DT_WORDBREAK | DT_NOPREFIX,
            );
        };
        line("Transom", 20, 26, 208, 46, 1, gallery::INK);
        line("Your Macs", 20, 92, 210, 26, 2, gallery::SECONDARY);
        line("Windows", 272, 30, 220, 46, 1, gallery::INK);
        line(
            "Choose a Mac window to open on this PC.",
            272,
            84,
            650,
            28,
            0,
            gallery::SECONDARY,
        );
        if self.visible.is_empty() {
            line(
                if self.cards.is_empty() {
                    if self.active {
                        "Your shared windows will appear here"
                    } else {
                        "Your Mac, one window at a time"
                    }
                } else {
                    "No matching windows"
                },
                304,
                210,
                540,
                42,
                2,
                gallery::INK,
            );
            line(
                if self.cards.is_empty() {
                    if self.active {
                        "Start sharing an app in Transom Host. Previews appear as soon as video arrives."
                    } else {
                        "Start Transom Host on your Mac, then choose it in the sidebar and connect. Open the windows you need and keep them beside your Windows apps."
                    }
                } else {
                    "Try a different window title in the search box."
                },
                304,
                260,
                520,
                105,
                0,
                gallery::SECONDARY,
            );
        }
        let count = format!(
            "{} shared  /  {} open on this PC",
            self.cards.len(),
            self.cards.iter().filter(|c| c.opened).count()
        );
        line(
            &count,
            272,
            r.bottom * 96 / self.dpi as i32 - 111,
            410,
            28,
            0,
            gallery::SECONDARY,
        );
        let _ = EndPaint(hwnd, &ps);
    }
}
unsafe extern "system" fn window_proc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if msg == WM_NCCREATE {
        let cs = &*(lp.0 as *const CREATESTRUCTW);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, cs.lpCreateParams as isize);
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
    let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut State;
    if ptr.is_null() {
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
    match msg {
        WM_CREATE => {
            create_controls(hwnd, &mut *ptr);
            LRESULT(0)
        }
        WM_COMMAND => {
            let id = wp.0 & 0xffff;
            let notification = wp.0 >> 16;
            let s = &mut *ptr;
            if id >= CARD_BASE && id < CARD_BASE + CARD_COUNT {
                if let Some(&index) = s.visible.get(id - CARD_BASE) {
                    s.actions
                        .push_back(Action::OpenWindow(s.cards[index].window.id));
                }
            } else if id == SEARCH && notification == EN_CHANGE as usize {
                s.query = read_text(s.control(SEARCH)).to_lowercase();
                s.page = 0;
                s.layout(hwnd);
            } else if id == PREVIOUS || id == NEXT {
                if id == PREVIOUS {
                    s.page = s.page.saturating_sub(1);
                } else {
                    s.page += 1;
                }
                s.layout(hwnd);
            } else if id == ADVANCED {
                s.manual = !s.manual;
                set_text(
                    s.control(ADVANCED),
                    if s.manual {
                        "Hide manual connection"
                    } else {
                        "Manual connection…"
                    },
                );
                if s.manual {
                    let mut r = RECT::default();
                    let _ = GetWindowRect(hwnd, &mut r);
                    if r.bottom - r.top < scale(730, s.dpi) {
                        let _ = SetWindowPos(
                            hwnd,
                            None,
                            0,
                            0,
                            r.right - r.left,
                            scale(730, s.dpi),
                            SWP_NOMOVE | SWP_NOZORDER,
                        );
                    }
                }
                s.layout(hwnd);
            } else if (id == CONNECT || (id == DEVICES && notification == LBN_DBLCLK as usize))
                && !s.active
            {
                if let Some(c) = s.selected() {
                    s.actions.push_back(Action::Connect(c));
                }
            } else if id == DISCONNECT {
                s.actions.push_back(Action::Disconnect);
            } else if id == REFRESH && s.scan.is_none() {
                s.start_scan();
            } else if id == FORGET {
                if let Some(c) = s.selected() {
                    s.saved.retain(|p| p.id != c.id);
                    if let Err(e) = connections::save(&s.preferences, &s.saved) {
                        show_error(hwnd, &format!("Could not save preferences: {e}"));
                    }
                    s.rebuild_rows();
                }
            } else if id == MANUAL && !s.active {
                match Connection::manual(
                    &read_text(s.control(HOST)),
                    &read_text(s.control(CONTROL)),
                    &read_text(s.control(VIDEO)),
                ) {
                    Ok(c) => s.actions.push_back(Action::Connect(c)),
                    Err(e) => show_error(hwnd, &e),
                }
            } else if id == UPDATE {
                launch_updater(hwnd);
            }
            LRESULT(0)
        }
        WM_SIZE => {
            (*ptr).layout(hwnd);
            LRESULT(0)
        }
        WM_DPICHANGED => {
            (*ptr).dpi = (wp.0 & 0xffff) as u32;
            (*ptr).rebuild_fonts();
            let r = &*(lp.0 as *const RECT);
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
            m.ptMinTrackSize.x = scale(840, (*ptr).dpi);
            m.ptMinTrackSize.y = scale(if (*ptr).manual { 730 } else { 600 }, (*ptr).dpi);
            LRESULT(0)
        }
        WM_DRAWITEM => {
            let item = &*(lp.0 as *const DRAWITEMSTRUCT);
            if let Some(slot) = (item.CtlID as usize).checked_sub(CARD_BASE) {
                if let Some(&index) = (&(*ptr).visible).get(slot) {
                    gallery::draw(&(&(*ptr).cards)[index], item, &(*ptr).fonts, (*ptr).dpi);
                }
            }
            LRESULT(1)
        }
        WM_PAINT => {
            (*ptr).paint(hwnd);
            LRESULT(0)
        }
        WM_CTLCOLORSTATIC | WM_CTLCOLOREDIT | WM_CTLCOLORLISTBOX => {
            let dc = HDC(wp.0 as *mut c_void);
            let _ = SetTextColor(dc, TEXT);
            let _ = SetBkColor(dc, BG);
            LRESULT((*ptr).brush.0 as isize)
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

unsafe fn create_controls(hwnd: HWND, s: &mut State) {
    let instance = HINSTANCE(GetModuleHandleW(None).unwrap().0);
    let status = s.status.clone();
    let mut add = |class: PCWSTR,
                   text: &str,
                   id: usize,
                   rect: (i32, i32, i32, i32),
                   font: usize,
                   style: u32,
                   stretch: bool| {
        let title = wide(text);
        let child = CreateWindowExW(
            Default::default(),
            class,
            PCWSTR(title.as_ptr()),
            WS_CHILD | WS_VISIBLE | WINDOW_STYLE(style),
            rect.0,
            rect.1,
            rect.2,
            rect.3,
            hwnd,
            HMENU(id as *mut c_void),
            instance,
            None,
        )
        .unwrap();
        let _ = SetWindowTheme(child, w!("Explorer"), PCWSTR::null());
        s.controls.push(Control {
            hwnd: child,
            id,
            rect,
            font,
            _stretch: stretch,
        });
    };
    add(
        w!("LISTBOX"),
        "Nearby and saved Macs",
        DEVICES,
        (20, 124, 212, 110),
        0,
        WS_TABSTOP.0 | WS_VSCROLL.0 | WS_BORDER.0 | LBS_NOTIFY as u32 | LBS_NOINTEGRALHEIGHT as u32,
        false,
    );
    add(
        w!("STATIC"),
        "Looking for nearby Macs…",
        DISCOVERY,
        (20, 242, 212, 52),
        0,
        0,
        false,
    );
    add(
        w!("BUTTON"),
        "Connect",
        CONNECT,
        (20, 304, 212, 36),
        2,
        WS_TABSTOP.0 | BS_DEFPUSHBUTTON as u32,
        false,
    );
    add(
        w!("BUTTON"),
        "Disconnect",
        DISCONNECT,
        (20, 348, 212, 32),
        0,
        WS_TABSTOP.0,
        false,
    );
    add(
        w!("BUTTON"),
        "Refresh",
        REFRESH,
        (20, 390, 98, 30),
        0,
        WS_TABSTOP.0,
        false,
    );
    add(
        w!("BUTTON"),
        "Forget",
        FORGET,
        (130, 390, 102, 30),
        0,
        WS_TABSTOP.0,
        false,
    );
    add(
        w!("BUTTON"),
        "Manual connection…",
        ADVANCED,
        (20, 436, 212, 30),
        0,
        WS_TABSTOP.0,
        false,
    );
    add(
        w!("STATIC"),
        "Mac hostname or IP",
        201,
        (20, 474, 212, 22),
        0,
        0,
        false,
    );
    add(
        w!("EDIT"),
        "",
        HOST,
        (20, 498, 212, 28),
        0,
        WS_TABSTOP.0 | WS_BORDER.0 | ES_AUTOHSCROLL as u32,
        false,
    );
    add(
        w!("STATIC"),
        "Control port",
        202,
        (20, 534, 100, 22),
        0,
        0,
        false,
    );
    add(
        w!("STATIC"),
        "Video port",
        203,
        (132, 534, 100, 22),
        0,
        0,
        false,
    );
    add(
        w!("EDIT"),
        "47100",
        CONTROL,
        (20, 558, 98, 28),
        0,
        WS_TABSTOP.0 | WS_BORDER.0 | ES_AUTOHSCROLL as u32,
        false,
    );
    add(
        w!("EDIT"),
        "47101",
        VIDEO,
        (132, 558, 100, 28),
        0,
        WS_TABSTOP.0 | WS_BORDER.0 | ES_AUTOHSCROLL as u32,
        false,
    );
    add(
        w!("BUTTON"),
        "Connect manually",
        MANUAL,
        (20, 596, 212, 32),
        0,
        WS_TABSTOP.0,
        false,
    );
    add(
        w!("BUTTON"),
        "Check for updates",
        UPDATE,
        (20, 648, 212, 32),
        0,
        WS_TABSTOP.0,
        false,
    );
    add(
        w!("EDIT"),
        "",
        SEARCH,
        (768, 36, 240, 34),
        0,
        WS_TABSTOP.0 | WS_BORDER.0 | ES_AUTOHSCROLL as u32,
        false,
    );
    add(
        w!("STATIC"),
        &status,
        STATUS,
        (272, 625, 736, 50),
        0,
        0,
        true,
    );
    add(
        w!("BUTTON"),
        "Previous",
        PREVIOUS,
        (800, 583, 94, 30),
        0,
        WS_TABSTOP.0,
        false,
    );
    add(
        w!("BUTTON"),
        "Next",
        NEXT,
        (906, 583, 94, 30),
        0,
        WS_TABSTOP.0,
        false,
    );
    for slot in 0..CARD_COUNT {
        add(
            w!("BUTTON"),
            "Open window",
            CARD_BASE + slot,
            (272, 138, 320, 208),
            0,
            WS_TABSTOP.0 | BS_OWNERDRAW as u32,
            false,
        );
    }
    let hint = wide("Search windows");
    SendMessageW(
        s.control(SEARCH),
        0x1501,
        WPARAM(0),
        LPARAM(hint.as_ptr() as isize),
    );
    let _ = EnableWindow(s.control(DISCONNECT), false);
    SendMessageW(s.control(HOST), EM_SETLIMITTEXT, WPARAM(253), LPARAM(0));
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
fn launch_updater(hwnd: HWND) {
    let result = std::env::current_exe().and_then(|p| {
        std::process::Command::new(p.with_file_name("transom-updater.exe"))
            .args(["--check", "--current-version", env!("CARGO_PKG_VERSION")])
            .spawn()
    });
    if let Err(e) = result {
        show_error(
            hwnd,
            &format!("Could not start the updater. Install Transom using its setup file.\n\n{e}"),
        );
    }
}
