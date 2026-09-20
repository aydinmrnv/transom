//! First-run connection window for the native Windows client.
//!
//! `transom-client run` remains scriptable, but launching an app from Explorer
//! should not require a terminal or a remembered command line. This small
//! Win32 form collects the same settings as the CLI and hands them to the real
//! window manager.

use std::ffi::c_void;

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Gdi::UpdateWindow;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::BST_CHECKED;
use windows::Win32::UI::Input::KeyboardAndMouse::SetFocus;
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetMessageW,
    GetWindowLongPtrW, GetWindowTextLengthW, GetWindowTextW, LoadCursorW, MessageBoxW,
    PostQuitMessage, RegisterClassW, SendMessageW, SetWindowLongPtrW, SetWindowTextW, ShowWindow,
    TranslateMessage, BM_GETCHECK, BM_SETCHECK, BS_AUTOCHECKBOX, BS_DEFPUSHBUTTON, CREATESTRUCTW,
    CW_USEDEFAULT, ES_AUTOHSCROLL, GWLP_USERDATA, HMENU, MB_ICONERROR, MB_OK, MSG, SW_SHOW,
    WM_CLOSE, WM_COMMAND, WM_CREATE, WM_DESTROY, WM_NCCREATE, WNDCLASSW, WS_CAPTION, WS_CHILD,
    WS_EX_APPWINDOW, WS_EX_CLIENTEDGE, WS_OVERLAPPED, WS_SYSMENU, WS_TABSTOP, WS_VISIBLE,
};

use super::{DEFAULT_CONTROL_PORT, DEFAULT_VIDEO_PORT};

const CLASS_NAME: PCWSTR = w!("TransomConnectionWindow");
const ID_HOST: usize = 1001;
const ID_CONTROL_PORT: usize = 1002;
const ID_VIDEO: usize = 1003;
const ID_CONNECT: usize = 1004;
const ID_CANCEL: usize = 1005;

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
    }));

    let hwnd = unsafe {
        CreateWindowExW(
            WS_EX_APPWINDOW,
            CLASS_NAME,
            w!("Connect to your Mac"),
            WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            520,
            330,
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
        let _ = UpdateWindow(hwnd);
        let mut message = MSG::default();
        while GetMessageW(&mut message, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        Box::from_raw(state_ptr).result
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
        WM_COMMAND => {
            let id = wparam.0 & 0xFFFF;
            if id == ID_CONNECT {
                submit(hwnd);
            } else if id == ID_CANCEL {
                let _ = DestroyWindow(hwnd);
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
    let label_style = WS_CHILD | WS_VISIBLE;
    let edit_style = WS_CHILD
        | WS_VISIBLE
        | WS_TABSTOP
        | windows::Win32::UI::WindowsAndMessaging::WINDOW_STYLE(ES_AUTOHSCROLL as u32);

    let _ = child(
        w!("STATIC"),
        w!("Connect to a Mac host"),
        label_style,
        24,
        20,
        440,
        28,
        hwnd,
        0,
    );
    let _ = child(
        w!("STATIC"),
        w!("Enter the Mac's private network address. Transom will open each shared app as a native Windows window."),
        label_style,
        24,
        52,
        450,
        38,
        hwnd,
        0,
    );
    let _ = child(
        w!("STATIC"),
        w!("Mac address"),
        label_style,
        24,
        108,
        100,
        24,
        hwnd,
        0,
    );
    let host = child_ex(
        w!("EDIT"),
        w!(""),
        edit_style,
        WS_EX_CLIENTEDGE,
        132,
        104,
        340,
        26,
        hwnd,
        ID_HOST,
    );
    let _ = child(
        w!("STATIC"),
        w!("Control port"),
        label_style,
        24,
        146,
        100,
        24,
        hwnd,
        0,
    );
    let control_port = child_ex(
        w!("EDIT"),
        w!(""),
        edit_style,
        WS_EX_CLIENTEDGE,
        132,
        142,
        100,
        26,
        hwnd,
        ID_CONTROL_PORT,
    );
    let port_text: Vec<u16> = DEFAULT_CONTROL_PORT
        .to_string()
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    let _ = SetWindowTextW(control_port, PCWSTR(port_text.as_ptr()));
    let video = child(
        w!("BUTTON"),
        w!("Stream video (recommended)"),
        WS_CHILD
            | WS_VISIBLE
            | WS_TABSTOP
            | windows::Win32::UI::WindowsAndMessaging::WINDOW_STYLE(BS_AUTOCHECKBOX as u32),
        24,
        182,
        260,
        26,
        hwnd,
        ID_VIDEO,
    );
    SendMessageW(
        video,
        BM_SETCHECK,
        WPARAM(BST_CHECKED.0 as usize),
        LPARAM(0),
    );
    let _ = child(
        w!("STATIC"),
        w!("The Mac host must be running before you connect. Use the host window's Copy command if you need the exact address."),
        label_style,
        24,
        214,
        450,
        34,
        hwnd,
        0,
    );
    let _ = child(
        w!("BUTTON"),
        w!("Connect"),
        WS_CHILD
            | WS_VISIBLE
            | WS_TABSTOP
            | windows::Win32::UI::WindowsAndMessaging::WINDOW_STYLE(BS_DEFPUSHBUTTON as u32),
        292,
        264,
        86,
        30,
        hwnd,
        ID_CONNECT,
    );
    let _ = child(
        w!("BUTTON"),
        w!("Cancel"),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP,
        386,
        264,
        86,
        30,
        hwnd,
        ID_CANCEL,
    );

    if let Some(current) = state(hwnd) {
        current.controls = Some(Controls {
            host,
            control_port,
            video,
        });
    }
    let _ = SetFocus(host);

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
