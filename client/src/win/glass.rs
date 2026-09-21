//! Native acrylic shell. Alpha belongs to the dashboard, never to the 1:1
//! video surfaces. Direct2D supplies antialiased geometry and DirectWrite text.
use windows::core::{w, Result};
use windows::Win32::{
    Foundation::{BOOL, HWND, RECT},
    Graphics::{
        Direct2D::{Common::*, *},
        DirectWrite::*,
        Dwm::*,
        Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM,
        Imaging::*,
    },
    System::Com::{CoCreateInstance, CLSCTX_INPROC_SERVER},
    UI::{Controls::MARGINS, WindowsAndMessaging::GetClientRect},
};

pub const INK: u32 = 0x08131F;
pub const BLUE: u32 = 0x2869FF;
pub const TEXT: u32 = 0xF3F6FC;
pub const MUTED: u32 = 0xB8C6DF;
pub const LINE: u32 = 0x344357;
pub const GREEN: u32 = 0x54E577;
pub fn color(rgb: u32, a: f32) -> D2D1_COLOR_F {
    D2D1_COLOR_F {
        r: ((rgb >> 16) & 255) as f32 / 255.,
        g: ((rgb >> 8) & 255) as f32 / 255.,
        b: (rgb & 255) as f32 / 255.,
        a,
    }
}
pub fn rect(x: f32, y: f32, w: f32, h: f32) -> D2D_RECT_F {
    D2D_RECT_F {
        left: x,
        top: y,
        right: x + w,
        bottom: y + h,
    }
}

pub struct Glass {
    pub target: ID2D1HwndRenderTarget,
    write: IDWriteFactory,
    mac_studio: Option<ID2D1Bitmap>,
    pub acrylic: bool,
}
impl Glass {
    pub unsafe fn new(hwnd: HWND, dpi: u32) -> Result<Self> {
        let factory: ID2D1Factory = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, None)?;
        let write: IDWriteFactory = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED)?;
        let mut r = RECT::default();
        GetClientRect(hwnd, &mut r)?;
        let props = D2D1_RENDER_TARGET_PROPERTIES {
            pixelFormat: D2D1_PIXEL_FORMAT {
                format: DXGI_FORMAT_B8G8R8A8_UNORM,
                alphaMode: D2D1_ALPHA_MODE_PREMULTIPLIED,
            },
            dpiX: dpi as f32,
            dpiY: dpi as f32,
            ..Default::default()
        };
        let target = factory.CreateHwndRenderTarget(
            &props,
            &D2D1_HWND_RENDER_TARGET_PROPERTIES {
                hwnd,
                pixelSize: D2D_SIZE_U {
                    width: r.right.max(1) as u32,
                    height: r.bottom.max(1) as u32,
                },
                presentOptions: D2D1_PRESENT_OPTIONS_NONE,
            },
        )?;
        let dark = BOOL(1);
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_USE_IMMERSIVE_DARK_MODE,
            &dark as *const _ as _,
            4,
        );
        let rounded = DWMWCP_ROUND;
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_WINDOW_CORNER_PREFERENCE,
            &rounded as *const _ as _,
            4,
        );
        let backdrop = DWMSBT_TRANSIENTWINDOW;
        let acrylic = DwmSetWindowAttribute(
            hwnd,
            DWMWA_SYSTEMBACKDROP_TYPE,
            &backdrop as *const _ as _,
            4,
        )
        .is_ok();
        let _ = DwmExtendFrameIntoClientArea(
            hwnd,
            &MARGINS {
                cxLeftWidth: -1,
                cxRightWidth: -1,
                cyTopHeight: -1,
                cyBottomHeight: -1,
            },
        );
        let mac_studio = load_mac_studio(&target)
            .map_err(|e| {
                eprintln!("Mac Studio artwork: {e}");
                e
            })
            .ok();
        Ok(Self {
            target,
            write,
            mac_studio,
            acrylic,
        })
    }
    pub unsafe fn begin(&self, w: u32, h: u32, dpi: u32) -> Result<Paint<'_>> {
        self.target.SetDpi(dpi as f32, dpi as f32);
        let size = self.target.GetPixelSize();
        if size.width != w || size.height != h {
            self.target.Resize(&D2D_SIZE_U {
                width: w.max(1),
                height: h.max(1),
            })?;
        }
        self.target.BeginDraw();
        self.target
            .Clear(Some(&color(INK, if self.acrylic { 0.82 } else { 1.0 })));
        Ok(Paint {
            rt: &self.target,
            write: &self.write,
            mac_studio: self.mac_studio.as_ref(),
        })
    }
    pub unsafe fn end(&self) -> Result<()> {
        self.target.EndDraw(None, None)
    }
}
pub struct Paint<'a> {
    pub rt: &'a ID2D1RenderTarget,
    write: &'a IDWriteFactory,
    mac_studio: Option<&'a ID2D1Bitmap>,
}

// Decode the embedded model render once per render target. WIC preserves alpha;
// never re-read from disk or access the network while painting the dashboard.
unsafe fn load_mac_studio(target: &ID2D1RenderTarget) -> Result<ID2D1Bitmap> {
    let wic: IWICImagingFactory =
        CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER)?;
    let stream = wic.CreateStream()?;
    stream.InitializeFromMemory(include_bytes!("../../assets/mac-studio.png"))?;
    let decoder =
        wic.CreateDecoderFromStream(&stream, std::ptr::null(), WICDecodeMetadataCacheOnLoad)?;
    let frame = decoder.GetFrame(0)?;
    let converter = wic.CreateFormatConverter()?;
    converter.Initialize(
        &frame,
        &GUID_WICPixelFormat32bppPBGRA,
        WICBitmapDitherTypeNone,
        None,
        0.,
        WICBitmapPaletteTypeCustom,
    )?;
    target.CreateBitmapFromWicBitmap(&converter, None)
}
impl Paint<'_> {
    pub unsafe fn fill(&self, r: D2D_RECT_F, radius: f32, rgb: u32, alpha: f32) {
        if let Ok(b) = self.rt.CreateSolidColorBrush(&color(rgb, alpha), None) {
            self.rt.FillRoundedRectangle(
                &D2D1_ROUNDED_RECT {
                    rect: r,
                    radiusX: radius,
                    radiusY: radius,
                },
                &b,
            );
        }
    }
    pub unsafe fn stroke(&self, r: D2D_RECT_F, radius: f32, rgb: u32, alpha: f32, width: f32) {
        if let Ok(b) = self.rt.CreateSolidColorBrush(&color(rgb, alpha), None) {
            self.rt.DrawRoundedRectangle(
                &D2D1_ROUNDED_RECT {
                    rect: r,
                    radiusX: radius,
                    radiusY: radius,
                },
                &b,
                width,
                None,
            );
        }
    }
    pub unsafe fn gradient(&self, r: D2D_RECT_F, radius: f32, top: u32, bottom: u32, alpha: f32) {
        let stops = [
            D2D1_GRADIENT_STOP {
                position: 0.,
                color: color(top, alpha),
            },
            D2D1_GRADIENT_STOP {
                position: 1.,
                color: color(bottom, alpha),
            },
        ];
        if let Ok(stops) =
            self.rt
                .CreateGradientStopCollection(&stops, D2D1_GAMMA_2_2, D2D1_EXTEND_MODE_CLAMP)
        {
            if let Ok(b) = self.rt.CreateLinearGradientBrush(
                &D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES {
                    startPoint: D2D_POINT_2F {
                        x: r.left,
                        y: r.top,
                    },
                    endPoint: D2D_POINT_2F {
                        x: r.right,
                        y: r.bottom,
                    },
                },
                None,
                &stops,
            ) {
                self.rt.FillRoundedRectangle(
                    &D2D1_ROUNDED_RECT {
                        rect: r,
                        radiusX: radius,
                        radiusY: radius,
                    },
                    &b,
                );
            }
        }
    }
    #[allow(clippy::too_many_arguments)]
    pub unsafe fn glow(
        &self,
        r: D2D_RECT_F,
        x: f32,
        y: f32,
        rx: f32,
        ry: f32,
        rgb: u32,
        alpha: f32,
    ) {
        let stops = [
            D2D1_GRADIENT_STOP {
                position: 0.,
                color: color(rgb, alpha),
            },
            D2D1_GRADIENT_STOP {
                position: 1.,
                color: color(rgb, 0.),
            },
        ];
        if let Ok(stops) =
            self.rt
                .CreateGradientStopCollection(&stops, D2D1_GAMMA_2_2, D2D1_EXTEND_MODE_CLAMP)
        {
            if let Ok(b) = self.rt.CreateRadialGradientBrush(
                &D2D1_RADIAL_GRADIENT_BRUSH_PROPERTIES {
                    center: D2D_POINT_2F { x, y },
                    gradientOriginOffset: D2D_POINT_2F { x: 0., y: 0. },
                    radiusX: rx,
                    radiusY: ry,
                },
                None,
                &stops,
            ) {
                self.rt.FillRoundedRectangle(
                    &D2D1_ROUNDED_RECT {
                        rect: r,
                        radiusX: 12.,
                        radiusY: 12.,
                    },
                    &b,
                );
            }
        }
    }
    pub unsafe fn text(
        &self,
        s: &str,
        r: D2D_RECT_F,
        size: f32,
        bold: bool,
        rgb: u32,
        center: bool,
    ) {
        let Ok(format) = self.write.CreateTextFormat(
            w!("Segoe UI"),
            None,
            if bold {
                DWRITE_FONT_WEIGHT_SEMI_BOLD
            } else {
                DWRITE_FONT_WEIGHT_NORMAL
            },
            DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL,
            size,
            w!("en-us"),
        ) else {
            return;
        };
        let _ = format.SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        let _ = format.SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        if center {
            let _ = format.SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
        }
        if let Ok(sign) = self.write.CreateEllipsisTrimmingSign(&format) {
            let _ = format.SetTrimming(
                &DWRITE_TRIMMING {
                    granularity: DWRITE_TRIMMING_GRANULARITY_CHARACTER,
                    delimiter: 0,
                    delimiterCount: 0,
                },
                &sign,
            );
        }
        if let Ok(brush) = self.rt.CreateSolidColorBrush(&color(rgb, 1.), None) {
            self.rt.DrawText(
                &s.encode_utf16().collect::<Vec<_>>(),
                &format,
                &r,
                &brush,
                D2D1_DRAW_TEXT_OPTIONS_CLIP,
                DWRITE_MEASURING_MODE_NATURAL,
            );
        }
    }
    pub unsafe fn icon(&self, glyph: &str, r: D2D_RECT_F, size: f32, rgb: u32) {
        if let (Ok(format), Ok(b)) = (
            self.write.CreateTextFormat(
                w!("Segoe MDL2 Assets"),
                None,
                DWRITE_FONT_WEIGHT_NORMAL,
                DWRITE_FONT_STYLE_NORMAL,
                DWRITE_FONT_STRETCH_NORMAL,
                size,
                w!("en-us"),
            ),
            self.rt.CreateSolidColorBrush(&color(rgb, 1.), None),
        ) {
            let _ = format.SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
            let _ = format.SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
            self.rt.DrawText(
                &glyph.encode_utf16().collect::<Vec<_>>(),
                &format,
                &r,
                &b,
                D2D1_DRAW_TEXT_OPTIONS_CLIP,
                DWRITE_MEASURING_MODE_NATURAL,
            );
        }
    }
    pub unsafe fn line(&self, x: f32, y: f32, x2: f32, y2: f32, rgb: u32, width: f32) {
        if let Ok(b) = self.rt.CreateSolidColorBrush(&color(rgb, 1.), None) {
            self.rt.DrawLine(
                D2D_POINT_2F { x, y },
                D2D_POINT_2F { x: x2, y: y2 },
                &b,
                width,
                None,
            );
        }
    }
    pub unsafe fn dot(&self, x: f32, y: f32, radius: f32, rgb: u32) {
        if let Ok(b) = self.rt.CreateSolidColorBrush(&color(rgb, 1.), None) {
            self.rt.FillEllipse(
                &D2D1_ELLIPSE {
                    point: D2D_POINT_2F { x, y },
                    radiusX: radius,
                    radiusY: radius,
                },
                &b,
            );
        }
    }
    pub unsafe fn bitmap(&self, data: &[u8], w: u32, h: u32, dest: D2D_RECT_F) {
        if w == 0 || h == 0 || data.len() < (w as usize * h as usize * 4) {
            return;
        }
        if let Ok(bitmap) = self.rt.CreateBitmap(
            D2D_SIZE_U {
                width: w,
                height: h,
            },
            Some(data.as_ptr().cast()),
            w * 4,
            &D2D1_BITMAP_PROPERTIES {
                pixelFormat: D2D1_PIXEL_FORMAT {
                    format: DXGI_FORMAT_B8G8R8A8_UNORM,
                    alphaMode: D2D1_ALPHA_MODE_IGNORE,
                },
                dpiX: 96.,
                dpiY: 96.,
            },
        ) {
            // Thumbnails only. The interactive video path retains point sampling.
            self.rt.DrawBitmap(
                &bitmap,
                Some(&dest),
                1.,
                D2D1_BITMAP_INTERPOLATION_MODE_LINEAR,
                None,
            );
        }
    }
    pub unsafe fn logo(&self, x: f32, y: f32) {
        self.gradient(rect(x, y, 25., 25.), 4., 0x4A9AFF, 0x1851D2, 1.);
        self.stroke(rect(x, y, 25., 25.), 4., 0x71B7FF, 1., 1.5);
        self.fill(rect(x + 16., y + 6., 23., 23.), 3., 0x152D4C, 0.5);
        self.stroke(rect(x + 16., y + 6., 23., 23.), 3., 0x77CCFF, 1., 2.);
    }
    pub unsafe fn mac(&self, area: D2D_RECT_F) {
        if let Some(bitmap) = self.mac_studio {
            let size = bitmap.GetSize();
            let k =
                ((area.right - area.left) / size.width).min((area.bottom - area.top) / size.height);
            let dest = rect(
                area.left + (area.right - area.left - size.width * k) / 2.,
                area.top + (area.bottom - area.top - size.height * k) / 2.,
                size.width * k,
                size.height * k,
            );
            self.rt.DrawBitmap(
                bitmap,
                Some(&dest),
                1.,
                D2D1_BITMAP_INTERPOLATION_MODE_LINEAR,
                None,
            );
        } else {
            self.icon("\u{E7F4}", area, 48., MUTED);
        }
    }
}
