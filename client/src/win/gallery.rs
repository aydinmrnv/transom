//! Selector thumbnails are UI previews only. Interactive proxy textures never
//! pass through this downsampling path.
use crate::{model::Window, wire::Size};
use windows::Win32::{
    Foundation::{COLORREF, RECT},
    Graphics::Gdi::*,
    UI::Controls::{DRAWITEMSTRUCT, ODS_FOCUS, ODS_SELECTED},
};

pub const CARD_BASE: usize = 1000;
pub const CARD_COUNT: usize = 12;
pub const CANVAS: COLORREF = COLORREF(0x00FCF8F6);
pub const SIDEBAR: COLORREF = COLORREF(0x00F8F0EA);
pub const INK: COLORREF = COLORREF(0x00382418);
pub const SECONDARY: COLORREF = COLORREF(0x007D6758);
pub const BLUE: COLORREF = COLORREF(0x00DB5D27);

pub struct Card {
    pub window: Window,
    pub opened: bool,
    pub pixels: Vec<u8>,
    pub size: Size,
}
impl Card {
    pub fn new(window: Window, opened: bool) -> Self {
        Self {
            window,
            opened,
            pixels: vec![],
            size: Size { w: 0, h: 0 },
        }
    }
    pub fn update_preview(&mut self, pixels: &[u8], display: Size) {
        let r = self.window.source;
        if r.w == 0
            || r.h == 0
            || r.x.saturating_add(r.w) > display.w
            || r.y.saturating_add(r.h) > display.h
            || pixels.len() < display.w as usize * display.h as usize * 4
        {
            return;
        }
        let ratio = (320.0 / r.w as f64).min(180.0 / r.h as f64).min(1.0);
        let w = (r.w as f64 * ratio).max(1.0) as u32;
        let h = (r.h as f64 * ratio).max(1.0) as u32;
        self.pixels.resize((w * h * 4) as usize, 0);
        for y in 0..h {
            let sy = r.y + (y as u64 * r.h as u64 / h as u64) as u32;
            for x in 0..w {
                let sx = r.x + (x as u64 * r.w as u64 / w as u64) as u32;
                let src = ((sy as usize * display.w as usize) + sx as usize) * 4;
                let dst = ((y * w + x) * 4) as usize;
                self.pixels[dst..dst + 4].copy_from_slice(&pixels[src..src + 4]);
            }
        }
        self.size = Size { w, h };
    }
}

pub unsafe fn fill(dc: HDC, r: &RECT, color: COLORREF) {
    let brush = CreateSolidBrush(color);
    FillRect(dc, r, brush);
    let _ = DeleteObject(brush);
}
pub unsafe fn label(
    dc: HDC,
    font: HFONT,
    text: &str,
    mut r: RECT,
    color: COLORREF,
    flags: DRAW_TEXT_FORMAT,
) {
    let old = SelectObject(dc, font);
    let _ = SetBkMode(dc, TRANSPARENT);
    let _ = SetTextColor(dc, color);
    let mut text: Vec<u16> = text.encode_utf16().collect();
    DrawTextW(dc, &mut text, &mut r, flags);
    SelectObject(dc, old);
}
pub unsafe fn draw(card: &Card, item: &DRAWITEMSTRUCT, fonts: &[HFONT; 3], dpi: u32) {
    let dc = item.hDC;
    let r = item.rcItem;
    let s = |n: i32| n * dpi as i32 / 96;
    fill(dc, &r, COLORREF(0x00FFFFFF));
    let border = CreateSolidBrush(if item.itemState.0 & (ODS_FOCUS.0 | ODS_SELECTED.0) != 0 {
        BLUE
    } else {
        COLORREF(0x00E7DDD2)
    });
    FrameRect(dc, &r, border);
    let _ = DeleteObject(border);
    let preview = RECT {
        left: r.left + s(10),
        top: r.top + s(10),
        right: r.right - s(10),
        bottom: r.bottom - s(76),
    };
    fill(dc, &preview, SIDEBAR);
    if card.size.w > 0 && !card.pixels.is_empty() {
        let ratio = ((preview.right - preview.left) as f64 / card.size.w as f64)
            .min((preview.bottom - preview.top) as f64 / card.size.h as f64);
        let w = (card.size.w as f64 * ratio) as i32;
        let h = (card.size.h as f64 * ratio) as i32;
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: card.size.w as i32,
                biHeight: -(card.size.h as i32),
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        StretchDIBits(
            dc,
            preview.left + (preview.right - preview.left - w) / 2,
            preview.top + (preview.bottom - preview.top - h) / 2,
            w,
            h,
            0,
            0,
            card.size.w as i32,
            card.size.h as i32,
            Some(card.pixels.as_ptr().cast()),
            &info,
            DIB_RGB_COLORS,
            SRCCOPY,
        );
    } else {
        label(
            dc,
            fonts[0],
            "Waiting for preview",
            preview,
            SECONDARY,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE,
        );
    }
    let title = if card.window.title.trim().is_empty() {
        "Untitled window"
    } else {
        &card.window.title
    };
    label(
        dc,
        fonts[2],
        title,
        RECT {
            left: r.left + s(16),
            top: r.bottom - s(64),
            right: r.right - s(16),
            bottom: r.bottom - s(38),
        },
        INK,
        DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX,
    );
    label(
        dc,
        fonts[0],
        if card.opened {
            "Show window"
        } else {
            "Open window"
        },
        RECT {
            left: r.left + s(16),
            top: r.bottom - s(34),
            right: r.right - s(16),
            bottom: r.bottom - s(10),
        },
        BLUE,
        DT_SINGLELINE | DT_NOPREFIX,
    );
    if item.itemState.0 & ODS_FOCUS.0 != 0 {
        let f = RECT {
            left: r.left + s(4),
            top: r.top + s(4),
            right: r.right - s(4),
            bottom: r.bottom - s(4),
        };
        let _ = DrawFocusRect(dc, &f);
    }
}

pub fn accessible_title(card: &Card) -> String {
    format!(
        "{}: {}",
        if card.opened {
            "Show window"
        } else {
            "Open window"
        },
        card.window.title
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::{Rect, WindowKind};
    #[test]
    fn preview_crops_only_its_window_and_rejects_outside_rects() {
        let mut c = Card::new(
            Window {
                id: 1,
                title: "x".into(),
                kind: WindowKind::Normal,
                source: Rect {
                    x: 1,
                    y: 0,
                    w: 1,
                    h: 2,
                },
            },
            false,
        );
        c.update_preview(
            &[1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4],
            Size { w: 2, h: 2 },
        );
        assert_eq!(c.pixels, vec![2, 2, 2, 2, 4, 4, 4, 4]);
        c.window.source.x = u32::MAX;
        c.update_preview(&[], Size { w: 2, h: 2 });
        assert_eq!(c.pixels.len(), 8);
    }
}
