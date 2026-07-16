# transom-client

Windows client for **Transom**, a seamless remote windowing system: individual
macOS app windows streamed to a Windows PC as independent, native windows you can
move, resize, snap, and fullscreen. Think RDS RemoteApp with a Mac host — which
does not otherwise exist.

> **⚠️ Pre-alpha.** The client is now a real window manager, not a scaffold: it
> speaks the wire protocol, opens a native borderless proxy window per Mac window,
> holds the 1:1 D3D11 pixel pipeline, and round-trips resize/focus/input. What is
> **proven** vs **pending hardware bring-up** is spelled out under
> [Verification status](#verification-status) — read it before trusting anything.

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

The canonical design doc is [`../docs/architecture.md`](../docs/architecture.md)
and the wire contract is [`../docs/protocol.md`](../docs/protocol.md); both are
shared with the host half.

## How it is built

The crate is split by **what can be verified where**, not just by concern:

| Layer | Modules | `windows-rs`? | Verified by |
|---|---|---|---|
| Wire protocol | `wire` (framing, JSON, control, video, input) | no | unit tests, on any host |
| Window model | `model` | no | unit tests |
| Networking + session | `net`, `session` | no | unit tests + live host |
| Headless runner | `runner` | no | run against the real host |
| Window manager + renderer | `win` (D3D11, Win32, decode) | yes | compiles/links for Windows |

The pure half needs no `windows-rs`, so it compiles and unit-tests on any host and
can be pointed at the real Swift host to check the two halves agree byte-for-byte.
The Windows half is `#[cfg(windows)]` and depends only on `windows` (features
added as needed; no new crates — invariants I-8).

## Commands

```sh
transom-client run <host>       # the window manager (Windows only)
transom-client connect <host>   # headless: drive the wire, print events, send test input
transom-client doctor           # D3D11 / DPI / monitor health check (Windows only)
```

`run` opens the control channel to the Mac and turns each Mac window into a native
proxy window. `--video` also opens the video channel and decodes the stream;
without it, windows show a placeholder pattern (useful for exercising geometry on
its own). `--checkerboard` draws the 1px M0 test pattern in each window so the 1:1
guarantee is visible from across the room.

```sh
transom-client run 192.168.1.20 --control-port 7010 --video
transom-client run 192.168.1.20 --control-port 7010 --checkerboard
```

`connect` is the same protocol core with no GPU: it prints the control stream and
can send test input/resize, so it works on **any** host and is how the wire is
verified without a Windows box.

```sh
# Watch the protocol and drive a resize round-trip against a running host:
transom-client connect 127.0.0.1 --control-port 7010 --seconds 5 --resize 1:2400:1500
```

## Build

Requires stable Rust. On Windows, the MSVC toolchain and Windows 10 1607+
(Per-Monitor V2):

```sh
cargo build
cargo run -- doctor
```

### Cross-checking the Windows half from a Mac/Linux

The `win` code cannot *run* off Windows, but it can be *type-checked and linked*
so it isn't written blind. With `rustup` + the GNU target + `mingw-w64`:

```sh
rustup target add x86_64-pc-windows-gnu   # once
CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=x86_64-w64-mingw32-gcc \
  cargo build --target x86_64-pc-windows-gnu
```

This produces a real `transom-client.exe` (PE32+) and is how the Windows half was
validated during development on the Mac host machine.

## Verification status

Per invariants I-7, only the real machines can verify the real guarantees. Being
explicit about which is which:

**Proven (on the Mac host machine, cross-language against `transom-host serve`):**

- The wire protocol end-to-end: `hello`, `windowCreated`, `tileLayout`, and the
  **full geometry round-trip** — the Rust client requested a resize, the Swift
  host applied it via AX, read back the actual rect, and reported `windowMoved`
  with the actual geometry, which the client consumed correctly.
- 49 unit tests over framing, JSON, control/video message shapes, input encoding,
  and the window model.
- The whole client compiles and **links to a real Windows executable**, so the
  `windows-rs` API usage (D3D11, DXGI, Win32, Media Foundation) is correct.

**Pending bring-up on a real Windows box (cannot be verified from a Mac):**

- The 1:1 pixel guarantee at 100 / 150 / 200% scaling (the checkerboard test).
- `ResizeBuffers`-to-exact-physical-rect and `WM_DPICHANGED` across monitors.
- **HEVC decode**: the Media Foundation path is coded to the documented contract
  and links, but whether the in-box decoder ingests the host's 4:4:4 10-bit stream
  is a hardware question. Any decode failure degrades to the placeholder texture,
  so the window manager still runs.

## `doctor`

Console-only D3D11 / DPI-awareness / monitor health check; it creates no window.
Its DPI report proves the embedded manifest declared **Per-Monitor V2** before the
first window exists (a runtime `SetProcessDpiAwarenessContext` call would be too
late).

## Why the manifest, not a runtime call

Per-Monitor V2 DPI awareness is declared in
[`transom-client.exe.manifest`](transom-client.exe.manifest) and embedded at build
time (see [`build.rs`](build.rs)). The manifest is the only route correct before
any window or GDI object exists.

## License

[AGPL-3.0](../LICENSE).
