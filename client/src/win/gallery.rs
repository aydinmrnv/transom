//! Selector thumbnails are UI previews only. Interactive proxy textures never
//! pass through this downsampling path.
use super::glass::{self, rect, Paint};
use crate::{model::Window, wire::Size};

pub const CARD_BASE: usize = 1000;
pub const CARD_COUNT: usize = 12;

pub struct Card {
    pub window: Window,
    pub opened: bool,
    pub pixels: Vec<u8>,
    pub size: Size,
    pub last_request: Option<std::time::Instant>,
}
impl Card {
    pub fn new(window: Window, opened: bool) -> Self {
        Self {
            window,
            opened,
            pixels: vec![],
            size: Size { w: 0, h: 0 },
            last_request: None,
        }
    }
    pub fn update_preview_atlas(&mut self, pixels: &[u8], display: Size, native_display: Size) {
        if self.window.source.w > 0 {
            self.fill_preview(pixels, display, native_display, 480, 270);
        }
    }
    pub fn jpeg_preview(&mut self, encoded: &str) {
        use windows::Win32::{Graphics::Imaging::*, System::Com::*};
        let Some(bytes) = crate::wire::base64::decode(encoded) else {
            return;
        };
        let result = (|| -> windows::core::Result<(Vec<u8>, Size)> {
            unsafe {
                let wic: IWICImagingFactory =
                    CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER)?;
                let stream = wic.CreateStream()?;
                stream.InitializeFromMemory(&bytes)?;
                let decoder = wic.CreateDecoderFromStream(
                    &stream,
                    std::ptr::null(),
                    WICDecodeMetadataCacheOnLoad,
                )?;
                let frame = decoder.GetFrame(0)?;
                let (mut w, mut h) = (0, 0);
                frame.GetSize(&mut w, &mut h)?;
                if w == 0 || h == 0 || w > 480 || h > 320 {
                    return Err(windows::core::Error::from_win32());
                }
                let converter = wic.CreateFormatConverter()?;
                converter.Initialize(
                    &frame,
                    &GUID_WICPixelFormat32bppPBGRA,
                    WICBitmapDitherTypeNone,
                    None,
                    0.,
                    WICBitmapPaletteTypeCustom,
                )?;
                let mut pixels = vec![0; (w * h * 4) as usize];
                converter.CopyPixels(std::ptr::null(), w * 4, &mut pixels)?;
                Ok((pixels, Size { w, h }))
            }
        })();
        if let Ok((pixels, size)) = result {
            self.pixels = pixels;
            self.size = size;
        }
    }
    fn fill_preview(
        &mut self,
        pixels: &[u8],
        display: Size,
        native_display: Size,
        max_w: u32,
        max_h: u32,
    ) {
        let r = self.window.source;
        if r.w == 0
            || r.h == 0
            || display.w == 0
            || display.h == 0
            || r.x.saturating_add(r.w) > native_display.w
            || r.y.saturating_add(r.h) > native_display.h
            || pixels.len() < display.w as usize * display.h as usize * 4
        {
            self.pixels.clear();
            self.size = Size { w: 0, h: 0 };
            return;
        }
        let ratio = (max_w as f64 / r.w as f64)
            .min(max_h as f64 / r.h as f64)
            .min(1.0);
        let w = (r.w as f64 * ratio).max(1.0) as u32;
        let h = (r.h as f64 * ratio).max(1.0) as u32;
        self.pixels.resize((w * h * 4) as usize, 0);
        for y in 0..h {
            let native_y = r.y as u64 + y as u64 * r.h as u64 / h as u64;
            let sy = (native_y * display.h as u64 / native_display.h as u64) as u32;
            for x in 0..w {
                let native_x = r.x as u64 + x as u64 * r.w as u64 / w as u64;
                let sx = (native_x * display.w as u64 / native_display.w as u64) as u32;
                let src = ((sy as usize * display.w as usize) + sx as usize) * 4;
                let dst = ((y * w + x) * 4) as usize;
                self.pixels[dst..dst + 4].copy_from_slice(&pixels[src..src + 4]);
            }
        }
        self.size = Size { w, h };
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

pub unsafe fn draw_glass(card: &Card, p: &Paint<'_>, w: f32, h: f32, focused: bool, list: bool) {
    p.gradient(
        rect(1., 1., w - 2., h - 2.),
        11.,
        if focused { 0x253B60 } else { 0x222D3C },
        0x141E2A,
        0.97,
    );
    p.stroke(
        rect(1., 1., w - 2., h - 2.),
        11.,
        if focused { 0x4685FF } else { 0x344355 },
        0.85,
        if focused { 2. } else { 0.8 },
    );
    let area = if list {
        rect(12., 9., 92., h - 18.)
    } else {
        rect(13., 12., w - 26., h - 62.)
    };
    p.fill(area, 5., 0x080F19, 1.);
    if card.size.w > 0 && !card.pixels.is_empty() {
        let sw = card.size.w as f32;
        let sh = card.size.h as f32;
        let k = ((area.right - area.left) / sw).min((area.bottom - area.top) / sh);
        p.bitmap(
            &card.pixels,
            card.size.w,
            card.size.h,
            rect(
                area.left + (area.right - area.left - sw * k) / 2.,
                area.top + (area.bottom - area.top - sh * k) / 2.,
                sw * k,
                sh * k,
            ),
        );
    } else {
        p.icon("\u{E7F4}", area, if list { 24. } else { 36. }, 0x59718E);
    }
    let title = if card.window.title.trim().is_empty() {
        "Untitled window"
    } else {
        &card.window.title
    };
    if list {
        p.text(
            title,
            rect(122., 10., w - 175., 27.),
            14.,
            true,
            glass::TEXT,
            false,
        );
        p.text(
            if card.opened {
                "Open on this PC"
            } else {
                "Available to open"
            },
            rect(122., 37., w - 175., 22.),
            12.,
            false,
            glass::MUTED,
            false,
        );
    } else {
        p.icon("\u{E8A7}", rect(14., h - 41., 30., 30.), 20., glass::MUTED);
        p.text(
            title,
            rect(55., h - 43., w - 103., 34.),
            14.,
            true,
            glass::TEXT,
            false,
        );
    }
    if card.opened {
        p.dot(w - 16., 18., 4., glass::GREEN);
    }
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
        c.update_preview_atlas(
            &[1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4],
            Size { w: 2, h: 2 },
            Size { w: 2, h: 2 },
        );
        assert_eq!(c.pixels, vec![2, 2, 2, 2, 4, 4, 4, 4]);
        c.window.source.x = u32::MAX;
        c.update_preview_atlas(&[], Size { w: 2, h: 2 }, Size { w: 2, h: 2 });
        assert!(c.pixels.is_empty());
    }
}
