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
        self.update_preview_sized(pixels, display, 480, 270);
    }
    pub fn update_preview_sized(&mut self, pixels: &[u8], display: Size, max_w: u32, max_h: u32) {
        let r = self.window.source;
        if r.w == 0
            || r.h == 0
            || r.x.saturating_add(r.w) > display.w
            || r.y.saturating_add(r.h) > display.h
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
        app_icon(p, title, 14., h - 43.);
        p.text(
            title,
            rect(63., h - 43., w - 111., 34.),
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
unsafe fn app_icon(p: &Paint<'_>, title: &str, x: f32, y: f32) {
    let app = title.split(" — ").next().unwrap_or(title).to_lowercase();
    let (color, glyph) = if app.contains("safari") {
        (0x238DE5, "\u{E774}")
    } else if app.contains("xcode") {
        (0x288FE8, "\u{E943}")
    } else if app.contains("terminal") {
        (0x152331, "\u{E756}")
    } else if app.contains("finder") {
        (0x3D9CEE, "\u{E8B7}")
    } else if app.contains("messages") {
        (0x45B75A, "\u{E8F2}")
    } else if app.contains("music") {
        (0xE93C60, "\u{E189}")
    } else if app.contains("notes") {
        (0xD8B542, "\u{E70B}")
    } else {
        (0x285F99, "\u{E737}")
    };
    p.gradient(rect(x, y, 34., 34.), 7., color, 0x16283E, 1.);
    p.stroke(rect(x, y, 34., 34.), 7., 0x91B2D0, 0.4, 0.7);
    p.icon(glyph, rect(x, y, 34., 34.), 21., 0xF4F8FC);
    if app.contains("photos") {
        p.fill(rect(x, y, 34., 34.), 7., 0xF4F6FB, 1.);
        for (i, c) in [
            0xED5C75, 0xED933D, 0xE9C848, 0x80BD64, 0x52B7B8, 0x508FE2, 0x886DE0, 0xC66EC8,
        ]
        .iter()
        .enumerate()
        {
            let a = i as f32 * std::f32::consts::PI / 4.;
            p.dot(x + 17. + a.cos() * 7., y + 17. + a.sin() * 7., 5., *c);
        }
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
        c.update_preview(
            &[1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4],
            Size { w: 2, h: 2 },
        );
        assert_eq!(c.pixels, vec![2, 2, 2, 2, 4, 4, 4, 4]);
        c.window.source.x = u32::MAX;
        c.update_preview(&[], Size { w: 2, h: 2 });
        assert!(c.pixels.is_empty());
    }
}
