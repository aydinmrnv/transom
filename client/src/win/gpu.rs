//! The shared D3D11 device and the 1:1 blit pipeline.
//!
//! This is where the product's whole promise is kept or lost. Every choice here
//! exists to guarantee that a source pixel maps to exactly one screen pixel
//! (invariants I-1):
//!
//!  * **`DXGI_SCALING_NONE`** on every swapchain — DXGI must never scale.
//!  * **`D3D11_FILTER_MIN_MAG_MIP_POINT`** sampler — no bilinear anywhere.
//!  * The swapchain is resized to the **exact physical client rect** on `WM_SIZE`
//!    (done in `proxy`), and the quad is drawn at native size, so there is no
//!    intermediate resample.
//!
//! One device is shared by all proxy windows; each window owns only its swapchain
//! and render-target view. The decoded frame (the whole VDS) is one shared
//! texture (`SourceTexture`); each window samples its sub-rect out of it.

use std::mem::size_of;

use windows::core::{s, Interface};
use windows::Win32::Foundation::{HMODULE, HWND};
use windows::Win32::Graphics::Direct3D::Fxc::{D3DCompile, D3DCOMPILE_ENABLE_STRICTNESS};
use windows::Win32::Graphics::Direct3D::{
    ID3DBlob, D3D_DRIVER_TYPE_HARDWARE, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_11_1,
    D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST,
};
use windows::Win32::Graphics::Direct3D11::{
    D3D11CreateDevice, ID3D11Buffer, ID3D11Device, ID3D11DeviceContext, ID3D11PixelShader,
    ID3D11RenderTargetView, ID3D11SamplerState, ID3D11ShaderResourceView, ID3D11Texture2D,
    ID3D11VertexShader, D3D11_BIND_CONSTANT_BUFFER, D3D11_BIND_SHADER_RESOURCE, D3D11_BUFFER_DESC,
    D3D11_CPU_ACCESS_WRITE, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_FILTER_MIN_MAG_MIP_POINT,
    D3D11_MAPPED_SUBRESOURCE, D3D11_MAP_WRITE_DISCARD, D3D11_SAMPLER_DESC, D3D11_SDK_VERSION,
    D3D11_SUBRESOURCE_DATA, D3D11_TEXTURE2D_DESC, D3D11_TEXTURE_ADDRESS_CLAMP, D3D11_USAGE_DEFAULT,
    D3D11_USAGE_DYNAMIC, D3D11_VIEWPORT,
};
use windows::Win32::Graphics::Dxgi::Common::{
    DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC,
};
use windows::Win32::Graphics::Dxgi::{
    IDXGIDevice, IDXGIFactory2, IDXGISwapChain1, DXGI_SCALING_NONE, DXGI_SWAP_CHAIN_DESC1,
    DXGI_SWAP_EFFECT_FLIP_DISCARD, DXGI_USAGE_RENDER_TARGET_OUTPUT,
};

/// Per-draw shader parameters. `#[repr(C)]` and 16-byte aligned to match the HLSL
/// `cbuffer` layout exactly (`float4` + `float2` + two `uint` = 32 bytes).
#[repr(C)]
#[derive(Clone, Copy)]
struct Params {
    uv_rect: [f32; 4], // xy = uv origin, zw = uv size, into the source texture
    view_size: [f32; 2], // physical pixel size of this window (for checkerboard)
    mode: u32,
    _pad: u32,
}

/// What a proxy window should draw this frame.
#[derive(Clone, Copy)]
pub enum RenderMode {
    /// Sample the shared source texture at `uv_rect` (the real product path).
    Source { uv_rect: [f32; 4] },
    /// 1px checkerboard generated from physical pixel position — the M0 probe for
    /// the 1:1 guarantee (roadmap M0-client). Independent of any host.
    Checkerboard,
    /// A flat diagnostic fill, shown before the first frame arrives.
    Waiting,
}

const SHADER_HLSL: &str = r#"
cbuffer Params : register(b0) {
    float4 uvRect;
    float2 viewSize;
    uint mode;
    uint pad;
};
Texture2D srcTex : register(t0);
SamplerState pointSampler : register(s0);

struct VSOut { float4 pos : SV_Position; float2 uv : TEXCOORD0; };

VSOut vs_main(uint vid : SV_VertexID) {
    // Fullscreen triangle: uv spans [0,1] over the window, (0,0) at top-left.
    float2 uv = float2((vid << 1) & 2, vid & 2);
    VSOut o;
    o.uv = uv;
    o.pos = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    return o;
}

float4 ps_main(VSOut i) : SV_Target {
    if (mode == 1u) {
        uint cx = (uint)i.pos.x;
        uint cy = (uint)i.pos.y;
        float c = ((cx + cy) & 1u) ? 1.0 : 0.0;
        return float4(c, c, c, 1.0);
    }
    if (mode == 2u) {
        return float4(0.08, 0.10, 0.14, 1.0);
    }
    float2 uv = uvRect.xy + i.uv * uvRect.zw;
    return srcTex.Sample(pointSampler, uv);
}
"#;

/// The shared device and pipeline objects.
pub struct Gpu {
    pub device: ID3D11Device,
    pub context: ID3D11DeviceContext,
    factory: IDXGIFactory2,
    vs: ID3D11VertexShader,
    ps: ID3D11PixelShader,
    sampler: ID3D11SamplerState,
    cbuffer: ID3D11Buffer,
}

impl Gpu {
    pub fn new() -> windows::core::Result<Gpu> {
        let mut device: Option<ID3D11Device> = None;
        let mut context: Option<ID3D11DeviceContext> = None;
        let levels = [D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0];

        unsafe {
            D3D11CreateDevice(
                None,
                D3D_DRIVER_TYPE_HARDWARE,
                HMODULE::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                Some(&levels),
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut context),
            )?;
        }
        let device = device.expect("D3D11CreateDevice returned no device");
        let context = context.expect("D3D11CreateDevice returned no context");

        // The DXGI factory that created the device is the one that must create its
        // swapchains.
        let dxgi_device: IDXGIDevice = device.cast()?;
        let adapter = unsafe { dxgi_device.GetAdapter()? };
        let factory: IDXGIFactory2 = unsafe { adapter.GetParent()? };

        let vs_blob = compile(SHADER_HLSL, s!("vs_main"), s!("vs_5_0"))?;
        let ps_blob = compile(SHADER_HLSL, s!("ps_main"), s!("ps_5_0"))?;

        let mut vs: Option<ID3D11VertexShader> = None;
        let mut ps: Option<ID3D11PixelShader> = None;
        unsafe {
            device.CreateVertexShader(blob_bytes(&vs_blob), None, Some(&mut vs))?;
            device.CreatePixelShader(blob_bytes(&ps_blob), None, Some(&mut ps))?;
        }

        // Point sampler — anything else resamples (I-1).
        let sampler_desc = D3D11_SAMPLER_DESC {
            Filter: D3D11_FILTER_MIN_MAG_MIP_POINT,
            AddressU: D3D11_TEXTURE_ADDRESS_CLAMP,
            AddressV: D3D11_TEXTURE_ADDRESS_CLAMP,
            AddressW: D3D11_TEXTURE_ADDRESS_CLAMP,
            MaxLOD: f32::MAX,
            ..Default::default()
        };
        let mut sampler: Option<ID3D11SamplerState> = None;
        unsafe { device.CreateSamplerState(&sampler_desc, Some(&mut sampler))? };

        let cbuffer_desc = D3D11_BUFFER_DESC {
            ByteWidth: size_of::<Params>() as u32,
            Usage: D3D11_USAGE_DYNAMIC,
            BindFlags: D3D11_BIND_CONSTANT_BUFFER.0 as u32,
            CPUAccessFlags: D3D11_CPU_ACCESS_WRITE.0 as u32,
            ..Default::default()
        };
        let mut cbuffer: Option<ID3D11Buffer> = None;
        unsafe { device.CreateBuffer(&cbuffer_desc, None, Some(&mut cbuffer))? };

        Ok(Gpu {
            device,
            context,
            factory,
            vs: vs.unwrap(),
            ps: ps.unwrap(),
            sampler: sampler.unwrap(),
            cbuffer: cbuffer.unwrap(),
        })
    }

    /// Create a flip-model swapchain for a proxy window's HWND, sized to the
    /// window's physical client rect. `DXGI_SCALING_NONE` is the load-bearing flag.
    pub fn create_swapchain(
        &self,
        hwnd: HWND,
        width: u32,
        height: u32,
    ) -> windows::core::Result<IDXGISwapChain1> {
        let desc = DXGI_SWAP_CHAIN_DESC1 {
            Width: width.max(1),
            Height: height.max(1),
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC {
                Count: 1,
                Quality: 0,
            },
            BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
            BufferCount: 2,
            // FLIP_DISCARD + SCALING_NONE: the compositor blits our buffer 1:1.
            SwapEffect: DXGI_SWAP_EFFECT_FLIP_DISCARD,
            Scaling: DXGI_SCALING_NONE,
            ..Default::default()
        };
        unsafe {
            self.factory
                .CreateSwapChainForHwnd(&self.device, hwnd, &desc, None, None)
        }
    }

    /// Bind the pipeline and draw one fullscreen triangle into `rtv` at
    /// `width × height`, in the requested mode.
    pub fn draw(
        &self,
        rtv: &ID3D11RenderTargetView,
        width: u32,
        height: u32,
        mode: RenderMode,
        source: Option<&ID3D11ShaderResourceView>,
    ) {
        let params = match mode {
            RenderMode::Source { uv_rect } => Params {
                uv_rect,
                view_size: [width as f32, height as f32],
                mode: 0,
                _pad: 0,
            },
            RenderMode::Checkerboard => Params {
                uv_rect: [0.0, 0.0, 1.0, 1.0],
                view_size: [width as f32, height as f32],
                mode: 1,
                _pad: 0,
            },
            RenderMode::Waiting => Params {
                uv_rect: [0.0, 0.0, 1.0, 1.0],
                view_size: [width as f32, height as f32],
                mode: 2,
                _pad: 0,
            },
        };

        unsafe {
            // Upload params.
            let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
            if self
                .context
                .Map(&self.cbuffer, 0, D3D11_MAP_WRITE_DISCARD, 0, Some(&mut mapped))
                .is_ok()
            {
                std::ptr::copy_nonoverlapping(
                    &params as *const Params as *const u8,
                    mapped.pData as *mut u8,
                    size_of::<Params>(),
                );
                self.context.Unmap(&self.cbuffer, 0);
            }

            let viewport = D3D11_VIEWPORT {
                TopLeftX: 0.0,
                TopLeftY: 0.0,
                Width: width as f32,
                Height: height as f32,
                MinDepth: 0.0,
                MaxDepth: 1.0,
            };
            self.context.RSSetViewports(Some(&[viewport]));
            self.context
                .OMSetRenderTargets(Some(&[Some(rtv.clone())]), None);
            self.context
                .IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
            self.context.VSSetShader(&self.vs, None);
            self.context.PSSetShader(&self.ps, None);
            self.context
                .PSSetConstantBuffers(0, Some(&[Some(self.cbuffer.clone())]));
            self.context
                .PSSetSamplers(0, Some(&[Some(self.sampler.clone())]));
            if let Some(srv) = source {
                self.context
                    .PSSetShaderResources(0, Some(&[Some(srv.clone())]));
            }
            self.context.Draw(3, 0);
        }
    }
}

/// A shared BGRA texture holding the whole decoded VDS frame; each proxy window
/// samples its sub-rect from it. Recreated when the VDS size changes.
pub struct SourceTexture {
    pub width: u32,
    pub height: u32,
    texture: ID3D11Texture2D,
    pub srv: ID3D11ShaderResourceView,
}

impl SourceTexture {
    /// Create a `width × height` BGRA source texture, initialized to a checkerboard
    /// so that before any video frame arrives the windows still show a sharp
    /// pattern rather than garbage.
    pub fn new(gpu: &Gpu, width: u32, height: u32) -> windows::core::Result<SourceTexture> {
        let desc = D3D11_TEXTURE2D_DESC {
            Width: width.max(1),
            Height: height.max(1),
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC {
                Count: 1,
                Quality: 0,
            },
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: D3D11_BIND_SHADER_RESOURCE.0 as u32,
            ..Default::default()
        };

        // Seed pixels: a coarse checkerboard so an un-fed texture is obviously a
        // placeholder, not a decode artifact.
        let mut pixels = vec![0u8; (width as usize) * (height as usize) * 4];
        for y in 0..height as usize {
            for x in 0..width as usize {
                let on = ((x / 32) + (y / 32)) % 2 == 0;
                let v = if on { 40 } else { 24 };
                let i = (y * width as usize + x) * 4;
                pixels[i] = v; // B
                pixels[i + 1] = v; // G
                pixels[i + 2] = v; // R
                pixels[i + 3] = 255;
            }
        }
        let init = D3D11_SUBRESOURCE_DATA {
            pSysMem: pixels.as_ptr() as *const _,
            SysMemPitch: width * 4,
            SysMemSlicePitch: 0,
        };

        let mut texture: Option<ID3D11Texture2D> = None;
        unsafe { gpu.device.CreateTexture2D(&desc, Some(&init), Some(&mut texture))? };
        let texture = texture.unwrap();

        let mut srv: Option<ID3D11ShaderResourceView> = None;
        unsafe {
            gpu.device
                .CreateShaderResourceView(&texture, None, Some(&mut srv))?
        };

        Ok(SourceTexture {
            width,
            height,
            texture,
            srv: srv.expect("CreateShaderResourceView returned no view"),
        })
    }

    /// Replace the whole texture's pixels with a freshly decoded BGRA frame.
    /// `bgra` must be `width * height * 4` bytes. Used by the decoder path.
    pub fn update_bgra(&self, gpu: &Gpu, bgra: &[u8]) {
        let expected = (self.width as usize) * (self.height as usize) * 4;
        if bgra.len() != expected {
            return; // wrong-sized frame: skip rather than corrupt memory
        }
        unsafe {
            gpu.context.UpdateSubresource(
                &self.texture,
                0,
                None,
                bgra.as_ptr() as *const _,
                self.width * 4,
                0,
            );
        }
    }

    /// The UV sub-rect (origin + size in [0,1]) for a window's source rect.
    pub fn uv_rect(&self, x: u32, y: u32, w: u32, h: u32) -> [f32; 4] {
        [
            x as f32 / self.width as f32,
            y as f32 / self.height as f32,
            w as f32 / self.width as f32,
            h as f32 / self.height as f32,
        ]
    }
}

/// Compile one HLSL entry point, returning the bytecode blob or a descriptive
/// error built from the compiler's message blob.
fn compile(
    src: &str,
    entry: windows::core::PCSTR,
    target: windows::core::PCSTR,
) -> windows::core::Result<ID3DBlob> {
    let mut code: Option<ID3DBlob> = None;
    let mut errors: Option<ID3DBlob> = None;
    let result = unsafe {
        D3DCompile(
            src.as_ptr() as *const _,
            src.len(),
            None,
            None,
            None,
            entry,
            target,
            D3DCOMPILE_ENABLE_STRICTNESS,
            0,
            &mut code,
            Some(&mut errors),
        )
    };
    match result {
        Ok(()) => Ok(code.expect("D3DCompile succeeded but produced no blob")),
        Err(e) => Err(e),
    }
}

/// View a bytecode blob as a byte slice.
fn blob_bytes(blob: &ID3DBlob) -> &[u8] {
    unsafe {
        let ptr = blob.GetBufferPointer() as *const u8;
        let len = blob.GetBufferSize();
        std::slice::from_raw_parts(ptr, len)
    }
}
