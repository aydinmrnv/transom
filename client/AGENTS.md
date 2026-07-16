# AGENTS.md: transom-client

You are working on the **Windows client** half of Transom.

## Read first, in this order

1. `docs/architecture.md` — the design and why. **Mirror.** The canonical copy
   lives in `transom-host`. If they disagree, that one wins.
2. `docs/invariants.md` — **binding rules.** Not suggestions.
3. `docs/roadmap.md` — what milestone we are in and what is out of scope.
4. `docs/protocol.md` — the eventual contract with the host. Draft. Do not
   implement.

## What this is

Transom streams individual macOS windows to this PC as independent native
windows you can move, resize, and fullscreen. This repo is the Windows side.

**This client is the real window manager.** The Mac only draws pixels. The client
decides where windows are, how big they are, and which is focused; the host obeys
and reports back what macOS actually did (invariants I-4).

The other half lives in `transom-host` (Swift, macOS). You will never see it, and
its agent will never see this repo. `docs/` is the only shared context, which is
why it is written the way it is.

## The one thing to understand

Transom exists because Parsec **resamples**. Parsec is a game-streaming tool:
games render at fixed resolution and Parsec scales to fit the window. Correct for
games, fatal for text. Shrink a Parsec window and Xcode becomes unreadable.

Transom's fix is geometry mirroring: the proxy window resizes, the Mac window is
set to exactly that pixel size, the app relayouts natively, and we blit 1:1.

**Every resampling stage is a bug** (invariants I-1).

### The trap you will walk into

**Windows DPI scaling is where you will accidentally rebuild the exact bug we are
escaping.**

The target monitor runs at 150% scaling. A process that is not Per-Monitor-V2 DPI
aware gets silently virtualized: you ask for a 2560x1440 window, Windows hands
you a 2560x1440 *logical* surface, scales it to physical, and every pixel kept
1:1 across the network gets bilinear-filtered on the last hop. You would have
built the whole system and it would look exactly like Parsec.

**The test is a 1px checkerboard.** If anything resamples anywhere, it turns to
uniform gray. Binary, brutal, visible from across the room.

## Non-negotiables

- **Per-Monitor V2 DPI awareness via application manifest.** Not
  `SetProcessDpiAwarenessContext` at runtime. The manifest is the only route that
  is correct before the first window exists.
- **`DXGI_SCALING_NONE`.** Never let DXGI scale. Verify, do not assume.
- **`D3D11_FILTER_MIN_MAG_MIP_POINT`.** Any other filter is a bug.
- **`ResizeBuffers` to the exact physical client rect** on `WM_SIZE`.
- **Physical pixels everywhere** (invariants I-2). Never logical, never DIPs.
- **Handle `WM_DPICHANGED`** correctly and prove it by dragging between monitors
  at different scale factors.
- **Never assume the host's geometry succeeded.** The host reports actual, not
  requested. Handle "asked 2560x1440, got 2560x1438" without breaking
  (invariants I-4).

## Stack

- Rust, `windows` (windows-rs). Cargo, no MSVC project files.
- D3D11. Flip model: `DXGI_SWAP_EFFECT_FLIP_DISCARD`, 2 buffers.
- Borderless but keeping native resize, snap, and Aero: `WS_OVERLAPPEDWINDOW`
  plus `WM_NCCALCSIZE` to eat the non-client area. **Do not** use `WS_POPUP` with
  hand-rolled `WM_NCHITTEST` unless you can show why the `WM_NCCALCSIZE` approach
  fails.
- Rounded corners via `DwmSetWindowAttribute` + `DWMWA_WINDOW_CORNER_PREFERENCE`,
  to eventually match macOS radius. H.264/HEVC has no alpha, so corners arrive
  baked opaque; the region is how we fix it.
- Dependencies: `windows` plus a manifest embedder (`embed-resource` or `winres`)
  only. Ask before adding others (invariants I-8).

### Why not Electron

An earlier draft said Electron for the prototype. **That is dead.** Chromium owns
DPI handling and resampling and you cannot opt out, so it would reintroduce the
exact bug we are escaping. Also WebRTC's jitter buffer is 50-100ms and
`playoutDelayHint: 0` does not remove it. Native from the start.

### Why Rust and not C++

Cargo beats vcpkg and MSVC project files, and windows-rs is a 1:1 binding so
every Microsoft C++ doc page translates directly. **Caveat:** Media Foundation
and NVDEC samples are all C++, so decoder work (M3) will need translation. Flag
it if that becomes a fight.

## Two things already known about the design

- **Live resize cannot be 1:1.** A roundtrip is 30ms+, past a drag's frame
  budget. Resample during the drag (transient, nobody notices), throttle resize
  requests to ~10Hz, snap to exact 1:1 on `WM_EXITSIZEMOVE`. This is what RDP
  does. Build it in, do not discover it.
- **The DWM frame is accepted.** Parsec goes exclusive fullscreen and bypasses
  the compositor; we want many independent windows, so we are permanently in DWM
  composition and eat one frame (~16ms at 60Hz). Not fixable. Do not try.

## Verification: this matters more than usual

**Only this machine can verify this repo.** Whether physical client rect equals
swapchain size at 150% scaling is unanswerable anywhere else (invariants I-7).

Show real output. Not inferences, not "CI is green." A previous agent scaffolded
both repos from the wrong machine and reported inferences as verification.

Report explicitly whether `physical client rect == swapchain size` holds at
**100%, 150%, and 200%** scaling, and while dragging between monitors.

**Live-resize gotcha:** Windows blocks in a modal loop during
`WM_ENTERSIZEMOVE`. The window goes blank unless you render from inside it.
Render during the drag.

## Current milestone: M0, the rendering probe

No networking, no decoder, no host. Synthetic source only. See `docs/roadmap.md`
M0-client.

The diagnostic overlay's `physical client rect == swapchain size` indicator is
the pass/fail for the whole milestone. Make it loud.

## Out of scope right now

Networking, decoding, the protocol, input capture beyond logging geometry events,
audio, clipboard. If a task seems to need one, stop and ask.

## Style

- Commit incrementally with real messages. Not one giant commit.
- When you find something surprising about Windows behavior, **write it into
  `docs/` as a finding.** The docs are the deliverable as much as the code,
  because they are the only thing the other half of the project can see.
