# transom-host

Host-side agent for **Transom**, a seamless remote windowing system: individual
macOS app windows streamed to a Windows PC as independent, native windows you can
move, resize, snap, and fullscreen. Think RDS RemoteApp with a Mac host — which
does not otherwise exist.

> **⚠️ Pre-alpha research prototype.** The host half works end to end on the
> target Mac: it probes HEVC 4:4:4 hardware encode, tiles windows non-overlapping,
> captures + hardware-encodes the virtual display, and serves window rects (and
> optionally video) to a client over TCP. It has **no auth and no encryption**
> (see Security below), the Windows client is a separate work in progress, and
> none of this is verifiable in CI — only on the Mac Studio (I-7).

## The problem

Parsec already streams a Mac desktop to Windows beautifully, but its windowed
mode scales the *entire desktop* into the window, so shrinking the window turns
text into an unreadable smear. That is a **resampling** problem, not a codec
problem. Transom fixes it by mirroring geometry — the client window resizes, the
Mac window is set to exactly that pixel size, the app relayouts natively, and we
blit 1:1.

## Architecture in three sentences

A large virtual display on the Mac (created externally with BetterDisplay) is
used as a compositing scratch space: every managed app window is tiled onto it
non-overlapping, so nothing is ever occluded, and one ScreenCaptureKit stream
with one hardware encoder captures the whole thing. The Windows client crops
per-window sub-rectangles out of that shared texture and draws each as its own
native window, while window rectangles travel on a side metadata channel. The
Windows client is the real window manager; the Mac host only draws.

**Read the canonical design doc: [`docs/architecture.md`](docs/architecture.md).**
It is the source of truth for both repos. The Windows client lives at
[`transom-client`](https://github.com/aydinmrnv/transom-client).

## Build

Requires macOS 14+ and a Swift 6 toolchain (Xcode 16 or a matching open-source
toolchain). The only dependency is
[swift-argument-parser](https://github.com/apple/swift-argument-parser).

```sh
swift build
swift run transom-host doctor
```

## `doctor`

`doctor` is the one real command. It checks Screen Recording and Accessibility
permissions, enumerates displays, and confirms ScreenCaptureKit can see them.

```sh
swift run transom-host doctor            # report and exit non-zero if not ready
swift run transom-host doctor --prompt   # also trigger the Accessibility prompt
```

**The permission gotcha it exists to explain:** macOS attributes privacy (TCC)
permissions to the app that *launched* the process, not to the `transom-host`
binary. Run from a terminal, the Screen Recording / Accessibility grants you need
are attributed to your **terminal app** (Terminal, iTerm2, Ghostty, VS Code…),
not to `transom-host`. `doctor` prints this in full — read it before you go
hunting for a "transom-host" checkbox that will never appear.

## ⚠️ Security: none

**There is no authentication and no encryption.** Anyone on the LAN who can reach
the port gets a live video feed of the Mac and the ability to inject keystrokes
and mouse events. That is acceptable for a **wired home LAN** and **completely
unacceptable anywhere else** — do not port-forward it, do not run it on a network
you do not trust, do not put it on the internet.

As a guardrail (not a security boundary), `serve` **refuses to bind to anything
but a private address** (`10/8`, `172.16/12`, `192.168/16`, `127/8`, `169.254/16`)
and defaults to `127.0.0.1`. Pass `--host <LAN-ip>` to expose it to a real client.
Auth and encryption are explicitly out of scope until designed properly.

> **Heads-up: the default control port `7000` collides with macOS AirPlay
> Receiver** (Control Center listens on `*:7000`). If a control client connects
> but never receives anything, either turn AirPlay Receiver off (System Settings ›
> General › AirDrop & Handoff) or pass `--control-port <n>` (e.g. `8770`). The
> video channel (`7001`) is unaffected. See `docs/architecture.md` §8.

## The apps

Two SwiftUI apps wrap the library in real bundles with **stable, distinct** bundle
ids, so each gets its own TCC (Screen Recording / Accessibility) identity — a CLI
run from a terminal has those grants attributed to the *terminal*, not the binary.

| App | Bundle id | What it is |
| --- | --- | --- |
| **Transom Host** | `one.nullstack.transom.host` | One-window control panel over `serve`: permissions, pick a display + app, Start, and live status (client connected, fps/bitrate, encoder mode, tile layout with post-clamp deltas). |
| **Transom Probe** | `one.nullstack.transom.probe` | The M0 diagnostic probe (OQ-1/OQ-2/OQ-5). |

Build and package both signed bundles (hardened runtime), then run one:

```sh
scripts/make-app.sh            # builds build/Transom Host.app and build/Transom Probe.app
open "build/Transom Host.app"
```

`scripts/release.sh host` (or `probe`) cuts the matching GitHub prerelease. Neither
app is notarized.

## Command surface

| Command | Status | Purpose |
| --- | --- | --- |
| `doctor` | **real** | permission / display / SCK health check |
| `displays` | **real** | machine-readable display list |
| `windows` | **real** | enumerate app windows + AX geometry |
| `place` | **real** | set one window's size/position via AX, report the readback delta |
| `tile` | **real** | pack windows non-overlapping (with gutters) on the virtual display |
| `capture` | **real** | run the shared ScreenCaptureKit stream, verify no scaling (I-1) |
| `encodeprobe` | **real** | probe HEVC 4:4:4 hardware encode (OQ-4) |
| `encode` | **real** | capture + HEVC 4:4:4 10-bit hardware encode; report fps/bitrate |
| `serve` | **real** | tile + watch an app and serve rects (+ optional video) over TCP; drives the resize roundtrip (throttled AX writes, readback, I-4) |
| `mockresize` | **real** | mock client: drive a Live/End resize drag against `serve` and measure the ~10Hz throttle |
| `probe` | **real** | architecture de-risking experiments |
| `menuwatch` | **real** | stream the focused app's windows/menus (answers OQ-1) |

## License

[AGPL-3.0](LICENSE).
