# transom-client

Windows client for **Transom**, a seamless remote windowing system: individual
macOS app windows streamed to a Windows PC as independent, native windows you can
move, resize, snap, and fullscreen. Think RDS RemoteApp with a Mac host — which
does not otherwise exist.

> **⚠️ Pre-alpha. This does not work yet.** Today the only command that does
> anything real is `doctor` (a console-only health check). There is no window, no
> stream, no rendering. This repo is a scaffold for an unproven design.

## The problem

Parsec already streams a Mac desktop to Windows beautifully, but its windowed
mode scales the *entire desktop* into the window, so shrinking the window turns
text into an unreadable smear. That is a **resampling** problem, not a codec
problem. Transom fixes it by mirroring geometry — the client window resizes, the
Mac window is set to exactly that pixel size, the app relayouts natively, and we
blit 1:1.

## Architecture in three sentences

A large virtual display on the Mac is used as a compositing scratch space: every
managed app window is tiled onto it non-overlapping, so nothing is ever occluded,
and one ScreenCaptureKit stream with one hardware encoder captures the whole
thing. **This** client crops per-window sub-rectangles out of that shared texture
and draws each as its own native Windows window, while it — not the Mac — acts as
the real window manager. Window rectangles travel on a side metadata channel; the
Mac only draws.

**Read the canonical design doc** (it lives in the host repo and is the source of
truth for both):
**<https://github.com/aydinmrnv/transom-host/blob/main/docs/architecture.md>**

The macOS host lives at
[`transom-host`](https://github.com/aydinmrnv/transom-host).

## Build

Requires Windows 10 1607+ (Per-Monitor V2), the MSVC toolchain, and stable Rust.
The only runtime dependency is [`windows`](https://crates.io/crates/windows)
(windows-rs); the build embeds an application manifest via
[`embed-resource`](https://crates.io/crates/embed-resource).

```sh
cargo build
cargo run -- doctor
```

## `doctor`

`doctor` is the one real command. It is console-only — it creates no window — and
reports:

- **D3D11 device creation:** result, feature level, adapter name, dedicated VRAM.
- **DPI awareness context:** the process's actual awareness, to prove the
  embedded manifest declared **Per-Monitor V2** *before the first window exists*
  (a runtime `SetProcessDpiAwarenessContext` call would be too late).
- **Every monitor:** handle, physical bounds, DPI, scale factor, refresh rate.

```sh
cargo run -- doctor
```

## Why the manifest, not a runtime call

Per-Monitor V2 DPI awareness is declared in
[`transom-client.exe.manifest`](transom-client.exe.manifest) and embedded at build
time (see [`build.rs`](build.rs)). The manifest is the only route that is correct
before any window or GDI object exists; `doctor` prints the resulting awareness
context so you can confirm the manifest actually took effect.

## License

[AGPL-3.0](LICENSE).
