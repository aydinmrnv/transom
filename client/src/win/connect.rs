//! First-run connection window for the native Windows client.
//!
//! `transom-client run` remains scriptable, but launching an app from Explorer
//! should not require a terminal or a remembered command line. This small
//! Win32 form collects the same settings as the CLI and hands them to the real
//! window manager.

use std::ffi::c_void;
use std::process::Command;

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    BeginPaint, CreateFontW, CreateSolidBrush, DeleteObject, EndPaint, FillRect, SetBkColor,
    SetBkMode, SetTextColor, BACKGROUND_MODE, DEFAULT_CHARSET, DEFAULT_PITCH, FF_DONTCARE,
    FONT_CLIP_PRECISION, FONT_OUTPUT_PRECISION, FONT_QUALITY, FONT_WEIGHT, HBRUSH, HDC, HFONT,
    PAINTSTRUCT, TRANSPARENT,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::{SetWindowTheme, BST_CHECKED};
use windows::Win32::UI::Input::KeyboardAndMouse::SetFocus;
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetClientRect, GetMessageW,
    GetWindowLongPtrW, GetWindowTextLengthW, GetWindowTextW, LoadCursorW, MessageBoxW,
    PostQuitMessage, RegisterClassW, SendMessageW, SetWindowLongPtrW, SetWindowTextW, ShowWindow,
    TranslateMessage, BM_GETCHECK, BM_SETCHECK, BS_AUTOCHECKBOX, BS_DEFPUSHBUTTON, CREATESTRUCTW,
    CW_USEDEFAULT, ES_AUTOHSCROLL, GWLP_USERDATA, HMENU, MB_ICONERROR, MB_OK, MSG, SW_SHOW,
    WM_CLOSE, WM_COMMAND, WM_CREATE, WM_CTLCOLOREDIT, WM_CTLCOLORSTATIC, WM_DESTROY, WM_ERASEBKGND,
    WM_NCCREATE, WM_PAINT, WM_SETFONT, WNDCLASSW, WS_CAPTION, WS_CHILD, WS_EX_APPWINDOW,
    WS_EX_CLIENTEDGE, WS_EX_CONTROLPARENT, WS_OVERLAPPED, WS_SYSMENU, WS_TABSTOP, WS_VISIBLE,
};

use super::{DEFAULT_CONTROL_PORT, DEFAULT_VIDEO_PORT};

const CLASS_NAME: PCWSTR = w!("TransomConnectionWindow");
const ID_HOST: usize = 1001;
const ID_CONTROL_PORT: usize = 1002;
const ID_VIDEO: usize = 1003;
const ID_CONNECT: usize = 1004;
const ID_CANCEL: usize = 1005;
const ID_UPDATE: usize = 1006;

const WINDOW_WIDTH: i32 = 620;
const WINDOW_HEIGHT: i32 = 470;
const BG_COLOR: COLORREF = COLORREF(0x00F8F9FB);
const INPUT_COLOR: COLORREF = COLORREF(0x00FFFFFF);
const TEXT_COLOR: COLORREF = COLORREF(0x001F2937);
const ACCENT_COLOR: COLORREF = COLORREF(0x00D66B2C);

pub struct Connection {
    pub host: String,
    pub control_port: u16,
    pub video_port: Option<u16>,
}

struct Controls {
    host: HWND,
    control_port: HWND,
    video: HWND,
}

struct DialogState {
    controls: Option<Controls>,
    result: Option<Connection>,
    body_font: HFONT,
    title_font: HFONT,
    label_font: HFONT,
    background_brush: HBRUSH,
    input_brush: HBRUSH,
    accent_brush: HBRUSH,
}

/// Show the first-run connection form. `None` means the user cancelled.
pub fn show() -> Option<Connection> {
    let instance = unsafe { GetModuleHandleW(None).ok()? };
    let class = WNDCLASSW {
        hCursor: unsafe {
            LoadCursorW(None, windows::Win32::UI::WindowsAndMessaging::IDC_ARROW).ok()?
        },
        hInstance: HINSTANCE(instance.0),
        lpfnWndProc: Some(window_proc),
        lpszClassName: CLASS_NAME,
        ..Default::default()
    };
    unsafe {
        let _ = RegisterClassW(&class);
    }

    let state_ptr = Box::into_raw(Box::new(DialogState {
        controls: None,
        result: None,
        body_font: create_font(-16, FONT_WEIGHT(400)),
        title_font: create_font(-26, FONT_WEIGHT(700)),
        label_font: create_font(-15, FONT_WEIGHT(600)),
        background_brush: unsafe { CreateSolidBrush(BG_COLOR) },
        input_brush: unsafe { CreateSolidBrush(INPUT_COLOR) },
        accent_brush: unsafe { CreateSolidBrush(ACCENT_COLOR) },
    }));

    let hwnd = unsafe {
        CreateWindowExW(
            WS_EX_APPWINDOW | WS_EX_CONTROLPARENT,
            CLASS_NAME,
            w!("Connect to your Mac"),
            WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            WINDOW_WIDTH,
            WINDOW_HEIGHT,
            None,
            None,
            HINSTANCE(instance.0),
            Some(state_ptr.cast::<c_void>()),
        )
    };

    let Ok(hwnd) = hwnd else {
        unsafe { drop(Box::from_raw(state_ptr)) };
        return None;
    };

    unsafe {
        let _ = ShowWindow(hwnd, SW_SHOW);
        let mut message = MSG::default();
        while GetMessageW(&mut message, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        let state = Box::from_raw(state_ptr);
        let result = state.result;
        let _ = DeleteObject(state.body_font);
        let _ = DeleteObject(state.title_font);
        let _ = DeleteObject(state.label_font);
        let _ = DeleteObject(state.background_brush);
        let _ = DeleteObject(state.input_brush);
        let _ = DeleteObject(state.accent_brush);
        result
    }
}

fn create_font(height: i32, weight: FONT_WEIGHT) -> HFONT {
    unsafe {
        CreateFontW(
            height,
            0,
            0,
            0,
            weight.0 as i32,
            0,
            0,
            0,
            DEFAULT_CHARSET.0 as u32,
            FONT_OUTPUT_PRECISION::default().0 as u32,
            FONT_CLIP_PRECISION::default().0 as u32,
            FONT_QUALITY::default().0 as u32,
            (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
            w!("Segoe UI"),
        )
    }
}

unsafe extern "system" fn window_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match message {
        WM_NCCREATE => {
            let create = &*(lparam.0 as *const CREATESTRUCTW);
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, create.lpCreateParams as isize);
            LRESULT(1)
        }
        WM_CREATE => {
            create_controls(hwnd);
            LRESULT(0)
        }
        WM_PAINT => {
            paint_window(hwnd);
            LRESULT(0)
        }
        WM_ERASEBKGND => {
            erase_background(hwnd, HDC(wparam.0 as *mut c_void));
            LRESULT(1)
        }
        WM_CTLCOLORSTATIC => {
            style_static(HDC(wparam.0 as *mut c_void));
            state(hwnd)
                .map(|dialog| LRESULT(dialog.background_brush.0 as isize))
                .unwrap_or_default()
        }
        WM_CTLCOLOREDIT => {
            style_edit(HDC(wparam.0 as *mut c_void));
            state(hwnd)
                .map(|dialog| LRESULT(dialog.input_brush.0 as isize))
                .unwrap_or_default()
        }
        WM_COMMAND => {
            let id = wparam.0 & 0xFFFF;
            if id == ID_CONNECT {
                submit(hwnd);
            } else if id == ID_CANCEL {
                let _ = DestroyWindow(hwnd);
            } else if id == ID_UPDATE {
                launch_updater(hwnd);
            }
            LRESULT(0)
        }
        WM_CLOSE => {
            let _ = DestroyWindow(hwnd);
            LRESULT(0)
        }
        WM_DESTROY => {
            PostQuitMessage(0);
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

unsafe fn state<'a>(hwnd: HWND) -> Option<&'a mut DialogState> {
    let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut DialogState;
    ptr.as_mut()
}

unsafe fn create_controls(hwnd: HWND) {
    let Some(dialog) = state(hwnd) else { return };
    let body_font = dialog.body_font;
    let title_font = dialog.title_font;
    let label_font = dialog.label_font;

    let label_style = WS_CHILD | WS_VISIBLE;
    let edit_style = WS_CHILD
        | WS_VISIBLE
        | WS_TABSTOP
        | windows::Win32::UI::WindowsAndMessaging::WINDOW_STYLE(ES_AUTOHSCROLL as u32);

    let title = child(
        w!("STATIC"),
        w!("Connect to your Mac"),
        label_style,
        36,
        30,
        548,
        36,
        hwnd,
        0,
    );
    apply_font(title, title_font, false);

    let subtitle = child(
        w!("STATIC"),
        w!("Connect to a running Transom Host on your private network.\nShared Mac apps will appear as native Windows windows."),
        label_style,
        36,
        76,
        548,
        42,
        hwnd,
        0,
    );
    apply_font(subtitle, body_font, false);

    let section = child(
        w!("STATIC"),
        w!("CONNECTION SETTINGS"),
        label_style,
        36,
        142,
        548,
        24,
        hwnd,
        0,
    );
    apply_font(section, label_font, false);

    let host_label = child(
        w!("STATIC"),
        w!("Mac address"),
        label_style,
        36,
        174,
        548,
        22,
        hwnd,
        0,
    );
    apply_font(host_label, label_font, false);

    let host = child_ex(
        w!("EDIT"),
        w!(""),
        edit_style,
        WS_EX_CLIENTEDGE,
        36,
        198,
        548,
        36,
        hwnd,
        ID_HOST,
    );
    apply_font(host, body_font, true);

    let port_label = child(
        w!("STATIC"),
        w!("Control port"),
        label_style,
        36,
        248,
        180,
        22,
        hwnd,
        0,
    );
    apply_font(port_label, label_font, false);

    let control_port = child_ex(
        w!("EDIT"),
        w!(""),
        edit_style,
        WS_EX_CLIENTEDGE,
        36,
        272,
        180,
        36,
        hwnd,
        ID_CONTROL_PORT,
    );
    apply_font(control_port, body_font, true);
    let port_text: Vec<u16> = DEFAULT_CONTROL_PORT
        .to_string()
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    let _ = SetWindowTextW(control_port, PCWSTR(port_text.as_ptr()));
    let video = child(
        w!("BUTTON"),
        w!("Stream video"),
        WS_CHILD
            | WS_VISIBLE
            | WS_TABSTOP
            | windows::Win32::UI::WindowsAndMessaging::WINDOW_STYLE(BS_AUTOCHECKBOX as u32),
        250,
        277,
        210,
        28,
        hwnd,
        ID_VIDEO,
    );
    apply_font(video, body_font, true);
    SendMessageW(
        video,
        BM_SETCHECK,
        WPARAM(BST_CHECKED.0 as usize),
        LPARAM(0),
    );
    let hint = child(
        w!("STATIC"),
        w!("The Mac host must be running before you connect. The default ports are 47100 and 47101."),
        label_style,
        36,
        328,
        548,
        32,
        hwnd,
        0,
    );
    apply_font(hint, body_font, false);

    let update = child(
        w!("BUTTON"),
        w!("Check for updates"),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP,
        36,
        386,
        170,
        36,
        hwnd,
        ID_UPDATE,
    );
    apply_font(update, body_font, true);

    let cancel = child(
        w!("BUTTON"),
        w!("Cancel"),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP,
        420,
        386,
        80,
        36,
        hwnd,
        ID_CANCEL,
    );
    apply_font(cancel, body_font, true);

    let connect = child(
        w!("BUTTON"),
        w!("Connect"),
        WS_CHILD
            | WS_VISIBLE
            | WS_TABSTOP
            | windows::Win32::UI::WindowsAndMessaging::WINDOW_STYLE(BS_DEFPUSHBUTTON as u32),
        510,
        386,
        90,
        36,
        hwnd,
        ID_CONNECT,
    );
    apply_font(connect, body_font, true);

    if let Some(current) = state(hwnd) {
        current.controls = Some(Controls {
            host,
            control_port,
            video,
        });
    }
    let _ = SetFocus(host);

    unsafe fn apply_font(hwnd: HWND, font: HFONT, themed: bool) {
        SendMessageW(hwnd, WM_SETFONT, WPARAM(font.0 as usize), LPARAM(1));
        if themed {
            let _ = SetWindowTheme(hwnd, w!("Explorer"), PCWSTR::null());
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn child(
        class: PCWSTR,
        title: PCWSTR,
        style: windows::Win32::UI::WindowsAndMessaging::WINDOW_STYLE,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        parent: HWND,
        id: usize,
    ) -> HWND {
        child_ex(
            class,
            title,
            style,
            Default::default(),
            x,
            y,
            width,
            height,
            parent,
            id,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn child_ex(
        class: PCWSTR,
        title: PCWSTR,
        style: windows::Win32::UI::WindowsAndMessaging::WINDOW_STYLE,
        ex_style: windows::Win32::UI::WindowsAndMessaging::WINDOW_EX_STYLE,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        parent: HWND,
        id: usize,
    ) -> HWND {
        unsafe {
            CreateWindowExW(
                ex_style,
                class,
                title,
                style,
                x,
                y,
                width,
                height,
                parent,
                HMENU(id as *mut c_void),
                HINSTANCE(GetModuleHandleW(None).expect("module handle").0),
                None,
            )
            .expect("create connection control")
        }
    }
}

unsafe fn paint_window(hwnd: HWND) {
    let Some(dialog) = state(hwnd) else { return };
    let mut paint = PAINTSTRUCT::default();
    let hdc = BeginPaint(hwnd, &mut paint);
    let mut client = RECT::default();
    let _ = GetClientRect(hwnd, &mut client);
    let accent = RECT {
        left: 0,
        top: 0,
        right: client.right,
        bottom: 6,
    };
    let _ = FillRect(hdc, &accent, dialog.accent_brush);
    let _ = EndPaint(hwnd, &paint);
}

unsafe fn erase_background(hwnd: HWND, hdc: HDC) {
    let Some(dialog) = state(hwnd) else { return };
    let mut client = RECT::default();
    let _ = GetClientRect(hwnd, &mut client);
    let _ = FillRect(hdc, &client, dialog.background_brush);
}

unsafe fn style_static(hdc: HDC) {
    let _ = SetTextColor(hdc, TEXT_COLOR);
    let _ = SetBkMode(hdc, TRANSPARENT);
}

unsafe fn style_edit(hdc: HDC) {
    let _ = SetTextColor(hdc, TEXT_COLOR);
    let _ = SetBkColor(hdc, INPUT_COLOR);
    let _ = SetBkMode(hdc, BACKGROUND_MODE(2));
}

unsafe fn submit(hwnd: HWND) {
    let Some(dialog) = state(hwnd) else { return };
    let Some(controls) = dialog.controls.as_ref() else {
        return;
    };
    let host = read_text(controls.host);
    let port_text = read_text(controls.control_port);
    let Ok(control_port) = port_text.parse::<u16>() else {
        show_error(hwnd, "Control port must be a number between 1 and 65535.");
        return;
    };
    if control_port == 0 {
        show_error(hwnd, "Control port must be a number between 1 and 65535.");
        return;
    }
    if host.trim().is_empty() {
        show_error(hwnd, "Enter the Mac's private network address.");
        return;
    }
    let video_port = if SendMessageW(controls.video, BM_GETCHECK, WPARAM(0), LPARAM(0)).0
        == BST_CHECKED.0 as isize
    {
        Some(DEFAULT_VIDEO_PORT)
    } else {
        None
    };
    if video_port == Some(control_port) {
        show_error(hwnd, "Control and video ports must be different.");
        return;
    }
    dialog.result = Some(Connection {
        host: host.trim().to_string(),
        control_port,
        video_port,
    });
    let _ = DestroyWindow(hwnd);
}

/// Start the companion updater next to the installed client. Keeping update
/// discovery outside the main process means the client can be closed and
/// replaced cleanly by the installer without self-update races.
unsafe fn launch_updater(hwnd: HWND) {
    let Ok(client_path) = std::env::current_exe() else {
        show_error(hwnd, "Transom could not locate its installation folder.");
        return;
    };
    let updater = client_path.with_file_name("transom-updater.exe");
    if !updater.is_file() {
        show_error(
            hwnd,
            "The updater is not installed. Reinstall Transom using the latest setup file.",
        );
        return;
    }
    if Command::new(updater)
        .args(["--check", "--current-version", env!("CARGO_PKG_VERSION")])
        .spawn()
        .is_err()
    {
        show_error(hwnd, "Transom could not start its updater.");
    }
}

unsafe fn read_text(hwnd: HWND) -> String {
    let length = GetWindowTextLengthW(hwnd);
    let mut buffer = vec![0u16; length as usize + 1];
    let written = GetWindowTextW(hwnd, &mut buffer);
    String::from_utf16_lossy(&buffer[..written as usize])
}

unsafe fn show_error(hwnd: HWND, message: &str) {
    let wide: Vec<u16> = message.encode_utf16().chain(std::iter::once(0)).collect();
    let _ = MessageBoxW(
        hwnd,
        PCWSTR(wide.as_ptr()),
        w!("Transom"),
        MB_OK | MB_ICONERROR,
    );
}
