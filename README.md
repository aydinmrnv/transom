# transom-host

Host-side agent for **Transom**, a seamless remote windowing system: individual
macOS app windows streamed to a Windows PC as independent, native windows you can
move, resize, snap, and fullscreen. Think RDS RemoteApp with a Mac host — which
does not otherwise exist.

> **⚠️ Pre-alpha. This does not work yet.** Today the only command that does
> anything real is `doctor`. Everything else is a stub. This repo is a scaffold
> for an unproven design; treat it as a research prototype, not software.

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

## Command surface (mostly stubs)

| Command | Status | Purpose |
| --- | --- | --- |
| `doctor` | **real** | permission / display / SCK health check |
| `displays` | stub | machine-readable display list |
| `windows` | stub | enumerate app windows + AX geometry |
| `place` | stub | set one window's size/position via AX |
| `tile` | stub | pack windows non-overlapping on the virtual display |
| `capture` | stub | run the shared ScreenCaptureKit stream |
| `probe` | stub | architecture de-risking experiments |
| `menuwatch` | stub | stream the focused app's global menu bar |

## License

[AGPL-3.0](LICENSE).
