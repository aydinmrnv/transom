# Transom Client

Windows client for **Transom**, a seamless remote windowing system: individual
macOS app windows streamed to a Windows PC as independent, native windows you can
move, resize, snap, and fullscreen. Think RDS RemoteApp with a Mac host — which
does not otherwise exist.

> **Early access.** The client is a real window manager, not a scaffold: it
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

## Quick connect

1. Open Transom Host on the Mac, choose a display and app, and press **Start**.
   Enable **Settings → Connection → Choose a LAN address automatically**
   (default on new installations). Allow Local Network access if macOS asks.
2. Open Transom on Windows. Choose your Mac under **Nearby & saved Macs** and
   press **Connect to Mac**, or double-click its name. Custom ports are automatic.
3. Keep the dashboard open for connection, window count, video errors, and retry
   status. **Disconnect** closes the local proxy windows, leaving Mac apps open.
   Closing the dashboard exits the client.

Successful connections are stored in `%LocalAppData%\Transom\connections.json`.
Discovered Macs are resolved by stable identity when their IP changes. Saved
devices remain visible while offline; **Forget saved Mac** removes a saved entry.
Scans refresh about every ten seconds, or immediately with **Refresh**.

If no Mac appears, check that the host is sharing, Local Network permission is
allowed, and the host is not bound to loopback. Both computers must share a local
network that permits mDNS. **Connect manually** accepts a hostname such as
`Mac-Studio.local` or an IP, with independent control/video ports. Leave video
blank for control-only diagnostics. Connections remain unencrypted and
unauthenticated, for trusted LAN use only.

The native dashboard supports keyboard navigation and per-monitor DPI sizing.
Discovery and connection attempts run in background workers; Disconnect also
cancels a pending attempt. CLI connections open the same persistent dashboard.
Resize Mac windows by dragging their edges; hold **Alt** while dragging inside
one to move or snap it using Windows' native move loop. Ordinary clicks in the
interior continue to go to the Mac app.

## Commands

```sh
transom-client run <host>       # the window manager (Windows only)
transom-client run              # open the connection window (Windows only)
transom-client connect <host>   # headless: drive the wire, print events, send test input
transom-client doctor           # D3D11 / DPI / monitor health check (Windows only)
```

`run` opens the connection window when no host is supplied, or opens the control
channel directly when a host is supplied. It turns each Mac window into a native
proxy window. `--video` also opens the video channel and decodes the stream;
without it, windows show a placeholder pattern (useful for exercising geometry on
its own). `--checkerboard` draws the 1px M0 test pattern in each window so the 1:1
guarantee is visible from across the room.

```sh
transom-client run 192.168.1.20 --control-port 47100 --video
transom-client run 192.168.1.20 --control-port 47100 --checkerboard
```

Double-clicking `transom-client.exe` opens the same connection window as
`transom-client run`; it no longer exits into a command-line help screen.

## Install and update on Windows

Use the `TransomSetup-vX.Y.Z.exe` asset from the GitHub release. It installs
Transom per-user under `%LocalAppData%\Programs\Transom`, creates a Start Menu
shortcut, optionally creates a desktop shortcut, and registers an uninstaller.
The setup is safe to run over an existing Transom install and preserves the
same install location.

The connection window's **Check for updates** button and the Start Menu's
**Check for updates** shortcut look for the newest GitHub release, download its
installer over HTTPS, verify the published SHA-256 checksum, and hand off to the
installer. The updater is a separate process so it can replace the running
client cleanly. Releases are currently not Authenticode-signed; Windows may show
the normal SmartScreen prompt until a signing certificate is configured.

`connect` is the same protocol core with no GPU: it prints the control stream and
can send test input/resize, so it works on **any** host and is how the wire is
verified without a Windows box.

```sh
# Watch the protocol and drive a resize round-trip against a running host:
transom-client connect 127.0.0.1 --control-port 47100 --seconds 5 --resize 1:2400:1500
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
- Unit tests over framing, JSON, control/video message shapes, input encoding,
  the window model, and initial proxy fitting.
- The whole client compiles and **links to a real Windows executable**, so the
  `windows-rs` API usage (D3D11, DXGI, Win32, Media Foundation) is correct.

**Verified on the Windows PC (2026-09-20):**

- A real 3840×2160 HEVC Main 4:2:0 8-bit stream from the Mac decoded and rendered
  as the Conductor proxy window. Version 0.3.1 fixes decoder discovery, Annex B
  conversion, compressed-frame queueing, and startup event ordering. Decoder
  failures now show their actual cause in the dashboard.
- A synthetic 128×96 HEVC regression stream decoded through the installed
  Media Foundation decoder (`cargo test decodes_hevc_fixture_on_windows --
  --ignored --nocapture`). This test is intentionally separate from hosted CI.
- The earlier native resize check measured matching physical client and
  swapchain dimensions at 200% DPI; see `docs/architecture.md` for exact output.

Windows needs **HEVC Video Extensions** installed. Use **4:2:0 8-bit** in the
Mac host's Video settings. Update the Mac host too: it now produces a keyframe
on connection even if the desktop is idle. Older hosts can delay that frame
until more Mac activity. Reconnect if the dashboard reports a decoder error.

**Still unverified:**

- The 1:1 pixel guarantee at 100 / 150 / 200% scaling (the checkerboard test).
- `ResizeBuffers`-to-exact-physical-rect and `WM_DPICHANGED` across monitors.
- End-to-end checkerboard fidelity and sustained frame-rate/latency under load.
  The current decode path does not support 10-bit/4:4:4 output.

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
