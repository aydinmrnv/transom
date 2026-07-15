# Transom: Architecture

**Status:** pre-alpha. Nothing works yet. This document describes the intended
design and the reasoning behind it.

**Canonical copy:** `transom-host/docs/architecture.md`. The copy in
`transom-client` is a mirror. If they disagree, the host copy wins.

---

## 1. The problem

Transom streams individual macOS application windows to a Windows PC, where each
one appears as an independent, native, movable, resizable window.

This does not exist today. Seamless per-window remoting is a solved problem in
exactly one direction: Windows host to anything else. Microsoft RDS RemoteApp,
`xfreerdp /app:`, and rdesktop's SeamlessRDP all do it well. Parallels Coherence
does the same trick locally. Nothing does it with a **macOS host**.

### 1.1 Why the direction matters

Windows applications carry their own chrome. Menus, toolbars, and title bar all
live inside the application's own `HWND`. You can lift that single rectangle out,
put it on another desktop, and it is a complete, usable application.

macOS applications do not work this way:

- **The menu bar is global.** Xcode's File / Edit / Product menus are not in the
  Xcode window. They live in the system menu bar, which belongs to whichever
  application is frontmost. Capture only the Xcode window and you get a
  menu-less Xcode.
- **Transient UI is separate windows.** Every `NSMenu` popup, sheet, popover,
  tooltip, and code-completion list is its own window in the WindowServer, not
  pixels inside the parent. Capture only the main window and completion popups
  simply do not appear.
- **No network transparency.** The macOS WindowServer was never network
  transparent the way X11 is, and macOS has no RDS equivalent, which means no
  per-session isolated window stack. One Mac has one focus, one cursor, one
  menu bar.

These three facts are why this project is hard and why nobody has shipped it.

### 1.2 What actually motivates this

The author already streams the Mac Studio to the Windows PC with Parsec, and the
quality and latency are good. **Latency is not the problem. Codecs are not the
problem.**

The problem is that Parsec is a game-streaming tool. Games render at a fixed
resolution, and Parsec's job is to scale that to fit your window. That is correct
for games and fatal for text. In Parsec's windowed mode, shrinking the window
does not relayout the Mac desktop, it **downscales** it. Text becomes unreadable.

RDP never has this problem because it is a desktop tool: resize the client and
the remote desktop genuinely changes resolution, content relayouts, and pixels
stay 1:1.

> **Transom's thesis: this is a resampling problem, not a codec problem.**

---

## 2. The core mechanism: geometry mirroring

```
Windows proxy window resizes
  -> host sets the Mac window to EXACTLY that pixel size via AXUIElement
  -> the Mac application relayouts natively
  -> host captures at that size
  -> client blits 1:1, never resampling
```

Per-window streaming is what makes this possible per window. But the feature is
geometry mirroring. Everything else is plumbing.

**Every resampling stage in the pipeline is a bug.** See `invariants.md`.

### 2.1 The live-resize compromise

Geometry mirroring cannot be 1:1 *during* a drag. Each frame of a resize drag
would need a full roundtrip:

```
WM_SIZING -> network -> AX setSize -> app relayout -> capture -> encode
          -> network -> decode -> present
```

That is 30ms or more, far past the frame budget of a smooth drag.

**Accepted design:**

- During the drag, resample. The blur is transient and nobody will notice.
- Fire AX `setSize` throttled to roughly 10Hz so the app relayouts as you go.
- On `WM_EXITSIZEMOVE`, snap to exact 1:1.

This is what RDP's dynamic resolution does. Build it in from the start rather
than discovering it later.

### 2.2 The re-tile question: what happens when a resize breaks non-overlap

Windows on the virtual display must never overlap (**I-5**). A resize can grow a
window into its neighbour. Gutters (~200px, 3.3) absorb small growth; large growth
does not fit in a gutter. So when a requested resize would collide with a
neighbour, what does the host do? Three options, none free:

1. **Re-tile everything.** Correct, but the other windows slide across the screen
   for no reason the user can see — they did not touch those windows. Jarring, and
   it cascades (moving B to make room for A may push B into C).
2. **Clamp the growth at the collision** and report the clamped size back, exactly
   as the host already reports an app-level size clamp (OQ-2).
3. **Grow the virtual display.** Disruptive, and it **invalidates the capture
   stream size**, which is a fixed hard constraint (the display is captured at one
   size by one encoder; changing it means tearing down and rebuilding the whole
   pipeline mid-drag).

**Decision: Option 2 — clamp and report.** Reasoning:

- It **reuses machinery that already exists**. The host already writes geometry,
  reads it back, and reports the *actual* rect (I-4); an app that enforces a
  minimum size already produces "asked 1280×800, got 1280×653". A non-overlap
  clamp is the same shape of result on the wire — a `windowMoved` smaller than the
  `RequestResize` asked for — so **the client needs no new behaviour**: it already
  must tolerate clamped resizes (I-4), and this is one more source of a clamp.
- Option 1 violates the principle that **the client owns geometry** (I-4). The host
  moving windows the user did not touch is the host asserting window-manager
  authority it is not supposed to have. The one sanctioned exception in I-4 (the
  host re-tiling to satisfy non-overlap) is a heavier hammer than this problem
  needs, and it trades a legible outcome ("the window stopped growing") for an
  illegible one ("three other windows jumped").
- Option 3 breaks a stated invariant of this phase ("the capture stream size does
  not change") and OQ-6 (we do not even know the largest display BetterDisplay
  will make). Off the table for now.

**How the clamp works.** A window resizes from its **top-left anchor** (matching
AX `setSize`, which leaves `AXPosition` alone, and the tiler's shelf origin), so it
only ever grows right and down — only neighbours to the right or below can block
it. Growth stops one gutter short of the nearest blocking neighbour, preserving the
popup-overhang budget, and at the display edge. This is a **pure function**
(`ResizeClamp.clamp`, unit-tested with no Mac); the impure `ResizeService` calls it
just before the AX write.

**What it costs.** At N≥2, you cannot grow a window past a neighbour; the resize
stops there and the client sees a smaller `windowMoved` than it asked for. To
actually get more room the **client** (which owns geometry) must move or close a
window — the host will not do it unbidden. There is also a residual edge case: the
non-overlap clamp runs *before* the AX write, but macOS may then clamp the size
*up* to an app minimum larger than the overlap-safe size (app-min > gutter gap). In
that case the read-back rect can still overlap a neighbour. The host reports the
actual rect regardless (I-4) and the client copes; a fully general fix is deferred
because it does not arise at the real target.

**At N=1 this whole question evaporates.** The actual primary use case is a single
Conductor window; with no neighbours the clamp is just a display-edge clamp. This
is deliberately not over-engineered: correct at N=1, sane at N=2–3.

---

## 3. The virtual display as a sprite sheet

The naive design is one ScreenCaptureKit stream per Mac window. It is the obvious
mapping and it is a trap:

- N windows means N encoder sessions.
- SCK stream startup is ~100ms+, so ephemeral popups can never work.
- You are managing a fleet of stream lifecycles.

**Instead, invert it.**

Create a large virtual display on the Mac, make it the main display, and use the
Accessibility API to tile every application window on it **non-overlapping**.
Nobody looks at this display. It is not a desktop. It is a sprite sheet.

Then:

- Capture **one** stream of that whole display with **one** encoder.
- Every window is guaranteed unoccluded, so every window always renders.
- Popups, sheets, and `NSMenu`s come along for free because they are already in
  the frame.
- Window rects travel on a lightweight side metadata channel.
- The client decodes one texture; each proxy window samples its own sub-rect.

**The Windows PC becomes the real window manager. The Mac only draws.**

### 3.1 Why the bandwidth objection dissolves

A large frame that is 95% static encodes to almost nothing, because H.264/HEVC
skip blocks are free. You pay for the pixels that change, which is the same as
any other approach.

### 3.2 Why the virtual display is main

Two independent reasons converge:

1. **The menu bar follows the main display.** We need the menu bar in the capture
   (see 1.1), so it must live on the virtual display.
2. **AX global coordinates originate at the main display's top-left.** Making the
   virtual display main means AX global space and virtual-display space share an
   origin, which eliminates an entire class of offset bug.

### 3.3 Sizing, and the tiling budget

An earlier draft of this design specified a 6144x6144 virtual display. That was
wrong. 37 megapixels at 60fps is ~2.3 gigapixels/sec of encode, which the M1 Max
media engine cannot do.

Size the virtual display for **actual usage**. Two or three windows at native
Windows-monitor sizes is the real target:

| Window   | Size      |
|----------|-----------|
| Xcode    | 2560x1440 |
| Conductor| 1280x1440 |

That fits comfortably in 4K-to-5K, roughly the same pixel budget Parsec already
handles on this hardware.

> **The tiling budget is a hard constraint.** Every window you want open, at full
> native size, must fit simultaneously on one virtual display without
> overlapping. This number decides how far Transom scales. Compute it for your
> real window set before committing to a display size.

**Gutters are part of the budget.** The tiler leaves ~200px of dead space between
tiles (and does not pack them flush). The reason is transient UI: a
code-completion popup or a dropdown opened near a window's edge can overhang past
that window's rect. On a flush-tiled display that overhang would land on a
*neighbour's* tile and corrupt the neighbour's crop, because the client blits each
window's sub-rect 1:1 and has no idea a stray popup bled into it. A gutter catches
the overhang in dead space where it hurts nothing. This is a constant cost — `n`
windows in a row cost `(n-1) × gutter` of width plus a gutter per extra shelf — and
it must be added to the budget above before choosing a virtual-display size. The
gutter is a pure input to the tiler (`Tiler.layout(windows:display:gutter:)`), so
its cost is explicit and testable, not hidden.

### 3.4 Deferred: the encoder pool

If the window count ever outgrows a single tiled display, the fallback is a pool
of ~8-10 pre-warmed VideoToolbox sessions (pre-warmed to avoid the ~100ms cold
start that would break popups), with attention-based throttling: focused window
at full rate, background windows at 5-10fps or frozen until they change.

**This is not in scope.** It solves a problem we do not have. Documented only so
it is not reinvented from scratch later.

### 3.5 The virtual display is created externally

`CGVirtualDisplay` is private API. Transom does **not** create the virtual
display. Use BetterDisplay (or equivalent) and pass the resulting display ID to
the host. The host targets whatever display ID it is given.

---

## 4. System diagram

```
   Mac Studio (host)                          Windows PC (client)
   only draws pixels                          real window manager
  +--------------------------+               +--------------------------+
  |  Virtual display (main)  |               |  Video decoder           |
  |  windows tiled,          |               |  one shared texture      |
  |  never overlapping       |               |                          |
  +--------------------------+               +--------------------------+
  |  Accessibility API       |   video +     |  Proxy windows           |
  |  reads + writes geometry |   rect meta   |  each samples a sub-rect |
  +--------------------------+  ==========>  +--------------------------+
  |  SCK + VideoToolbox      |  <==========  |  Input capture           |
  |  one stream, one encoder |  input + geom |  tagged by window id     |
  +--------------------------+               +--------------------------+
```

---

## 5. Latency budget

Parsec's approach is a tight GPU-to-GPU path: capture texture never leaves the
GPU, hardware encode, custom UDP with essentially no buffering, direct D3D
swapchain present, often in exclusive fullscreen bypassing DWM entirely. On LAN
that is roughly 10-16ms added.

Transom can match most of it. SCK hands back IOSurface-backed buffers that feed
VideoToolbox with zero copy. Wired LAN between host and client is sub-millisecond.
NVDEC on the client is effectively instant.

Two things Transom **cannot** match, and both should be accepted up front:

1. **WebRTC's jitter buffer** is 50-100ms by default. `playoutDelayHint` of 0
   still leaves Chromium buffering. If the latency bar matters, WebRTC is out and
   a custom UDP transport is required. **This is why the client is native Win32 +
   D3D11 and not Electron.**
2. **DWM.** Parsec can go exclusive fullscreen with a single surface and bypass
   the compositor. Transom wants many independent windows, which means permanent
   DWM composition, which is a guaranteed extra frame. At 60Hz that is +16ms that
   cannot be engineered away. **The feature forecloses the trick.**

**Realistic target: 25-35ms end to end.** Behind Parsec, and fine for Xcode. This
is not a twitch-aiming workload.

---

## 6. Quality

Games are forgiving. 4:2:0 chroma subsampling discards 75% of color resolution
and nobody notices on a rendered 3D scene. Xcode is *text*, with subpixel
antialiasing and syntax coloring, where 4:2:0 produces visible fringing.

Two requirements:

- **HEVC 4:4:4.** Roughly triples chroma bitrate. **Must verify the M1 Max media
  engine encodes 4:4:4 in hardware rather than falling back to software.** See
  open question OQ-4.
- **1:1 pixel mapping, everywhere.** See `invariants.md`.

Note: the author's existing Parsec setup already achieves text-quality streaming
on this exact hardware pair. Checking which color mode it runs in is a cheap way
to learn whether the quality ceiling is available at all.

---

## 7. Non-goals

- Not a general-purpose remote desktop. Parsec and VNC already do that.
- Not cross-platform. macOS host, Windows client, wired LAN.
- Not a security product. Assume a trusted LAN for now. Do not ship over the
  internet without solving auth and encryption, which are not designed yet.
- Not creating virtual displays (3.5).
- Not the encoder pool (3.4).
- Not audio. Later, if ever.

---

## 8. Open questions

These are unresolved. They are ordered by how likely they are to kill the
project. Do not paper over them.

### OQ-1: Do transient windows appear in an SCK capture? (CRITICAL)

Does an open `NSMenu` (Xcode's Product menu), a sheet, or a code-completion
popup appear in a ScreenCaptureKit display capture? Does AX report them as
windows with usable frames?

**If menus do not appear in the capture, there is no product.** Answer this
before writing anything else. Host milestone M0, `menuwatch`.

> **M0 FINDING (2026-07-14, Mac Studio, macOS 26): OQ-1 PASSES.**
>
> Measured with the M0 probe against Finder's menu bar menus (Xcode was not
> running; the mechanism is the same — a WindowServer-level `NSMenu`).
>
> 1. **Menus DO land in the SCK capture.** A full-display SCK capture taken
>    while a menu bar menu was open shows the entire `NSMenu` popup in the
>    frame, pixel-for-pixel, with no special handling.
> 2. **AX reports them with usable frames** — but **only via
>    `kAXMenuOpenedNotification`**, whose element has role **`AXMenu`** and a
>    correct global-point frame (e.g. File menu `(99,31) 337x629 pt` →
>    `674x1258 px` at 2x). The subrole is empty (`AXMenu` alone distinguishes it
>    from `AXWindow`/`AXStandardWindow`).
> 3. **Menus are NOT in the app's `kAXWindowsAttribute` list and do NOT fire
>    `kAXWindowCreatedNotification`.** So the rect-metadata path must subscribe
>    to `kAXMenuOpened`/`kAXMenuClosed` explicitly; polling the window list will
>    silently miss every menu. On `kAXMenuClosed` the element's frame reads back
>    as `(0,1080) 0x0` (already torn down) — capture the frame on *open*.
>
> Implication for I-5 / the tiler: a menu is a separate transient element the
> app positions itself; it can land on top of a tiled window. Handling is still
> open (see I-5), but the capture-and-report half is proven to work.

### OQ-2: Are AX geometry writes honored exactly?

When we set `AXPosition` and `AXSize`, does macOS honor them, or does it clamp to
display bounds, round to even pixels, or enforce an application minimum size?
Xcode may refuse sizes below some floor.

Any clamping constrains the entire tiling design. The `place` command must read
back and **report the delta**. The delta is the entire point of that command.

> **M0 FINDING (2026-07-14): position exact, size CLAMPED.**
>
> `place` against a Finder window on the 2x main display:
> - **`AXPosition` was honored exactly** in every trial (delta `(0,0)`).
> - **`AXSize` is clamped, not rounded.** Requesting `1280x800` yielded
>   `1280x653`; requesting `300x200` yielded `470x280` — i.e. the app enforces a
>   **minimum window size** (~`470x280` for Finder) and, in some positions, a
>   maximum height. Clamping is per-app and must be discovered at runtime.
>
> Consequence for the design: the host cannot assume a requested tile size is
> the actual size. It must place, read back, and treat the **actual** rect as
> truth (I-4), and the tiler must re-pack from actual sizes or it will overlap.
> The tiling budget (3.3) must be computed from post-clamp sizes.

> **PHASE 1 FINDING (issue #3, 2026-07-14): position is also clamped — the top
> row cannot start at y=0.** Tiling two TextEdit windows to the top of the main
> virtual display via `tile TextEdit 7 --gutter 200`: both were requested at
> `y=0` and read back at **`y=60px` (30pt)** — the menu-bar band. AX will not let
> a window's title bar rise under the menu bar, and because the virtual display
> **is** main (3.2) the menu bar lives on it, so the usable top edge for tiling is
> `menuBarHeight` down, not 0. Sizes were honoured exactly here (`Δ size 0`) and
> non-overlap held. Consequence: the tiler's usable region excludes the menu-bar
> band at the top; either inset the first shelf by it or accept the readback
> delta and report the **actual** rect to the client (I-4), which is what `tile`
> does today. This is one more reason the client must key off actual geometry,
> never requested.

> **PHASE 4 FINDING (issue #6, 2026-07-15, Mac Studio M1 Max, macOS 26): the
> resize roundtrip, throttle, and both clamps measured end to end** via `serve`
> plus the `mockresize` mock client (no Windows client exists yet; #5's approach).
>
> 1. **Throttle holds ~10Hz.** A `mockresize` drag firing ~50 `RequestResize`/s
>    (60Hz nominal, network + AX slows the loop) produced **~10 AX writes/s** —
>    measured server-side: `92 request(s) in, 18 AX write(s) out` over 1.8s;
>    `122 in, 24 out` over 2.4s. The leading-edge + trailing-flush throttle
>    (`ResizeThrottle`, unit-tested) is what the client sees as ~10 `windowMoved`/s.
> 2. **App-minimum clamp still bites and is reported as actual (I-4).** TextEdit's
>    width floor is **115pt (230px)**; a drag toward `150x100px` read back as
>    `230x100px` and the client got the clamped rect, not the request.
> 3. **The non-overlap clamp (the 2.2 decision) works live.** A left window at VDS
>    `x=0` grown toward `3200px` wide, with a neighbour at VDS `x=2800`, clamped to
>    exactly `2600px` = `2800 − 200` (neighbour left edge minus one gutter). It grew
>    to the boundary and stopped; non-overlap (I-5) held; the client got `2600`, not
>    `3200`. Same wire shape as an app clamp, so no new client behaviour (2.2).
> 4. **`End` is authoritative.** The final `windowMoved` is always the `End`
>    read-back — exact when unclamped (`320x240 → 320x240`), the clamped actual
>    otherwise. It is never throttled away.
>
> Deployment note surfaced while testing: **port 7000 collides with macOS's AirPlay
> Receiver** (`ControlCenter` listens on `*:7000`), so a client connecting to the
> Mac on 7000 can reach AirPlay instead of `serve`. Recorded in protocol.md §1.

### OQ-3: Is there a stable window identity across AX and SCK?

SCK's `SCWindow` exposes a `CGWindowID`. AX exposes `AXUIElement`. Correlating
them is not obviously possible through public API. The known route is
`_AXUIElementGetWindow`, which is **private**.

Alternatives to investigate: matching AX frames against
`CGWindowListCopyWindowInfo` output heuristically (fragile, ambiguous with
identically-sized windows), or deriving identity some other way.

This matters because every rect on the wire needs a stable ID the client can key
its proxy windows on.

### OQ-4: Does the M1 Max hardware-encode HEVC 4:4:4?

Testable in an afternoon with `VTCopySupportedPropertyDictionaryForEncoder` plus
a test encode. If 4:4:4 is software-only on this host, the quality ceiling drops
and section 6 needs rewriting.

> **PHASE 0 FINDING (issue #3, 2026-07-14, Mac Studio M1 Max, macOS 26): YES,
> via the 10-bit path.** Measured by `transom-host encodeprobe`, which runs a
> real test encode per chroma mode requiring hardware, and reads back
> VideoToolbox's own `UsingHardwareAcceleratedVideoEncoder` flag.
>
> 1. **HEVC 4:4:4 encodes in HARDWARE — but only 10-bit.** A `v410`
>    (`kCVPixelFormatType_444YpCbCr10`, 4:4:4 10-bit) IOSurface-backed frame
>    encoded on the hardware encoder (`usingHardware:true`, real bitstream out).
> 2. **8-bit 4:4:4 is rejected.** A `v308`
>    (`kCVPixelFormatType_444YpCbCr8`) frame fails with
>    `kVTPixelTransferNotSupportedErr (-12905)` on both the require-HW and the
>    allow-SW config. The Apple HEVC encoder has no 8-bit 4:4:4 input path; its
>    only 4:4:4 profile is **Main 4:4:4 10**. This is fine — 10-bit is *better*
>    than 8-bit for text (no banding on gradients/antialiasing).
> 3. **There is no public `kVTProfileLevel_HEVC_Main444*` constant.** The SDK
>    exposes only `HEVC_Main`, `HEVC_Main10`, `HEVC_Main42210`, and the
>    monochrome variants. VideoToolbox **auto-derives** the 4:4:4 profile from
>    the `v410` source pixel format when `ProfileLevel` is left unset, so the
>    encoder must feed a 4:4:4-typed buffer and **not** set `ProfileLevel`
>    (setting `Main42210` would silently force 4:2:2).
> 4. Two HEVC encoders are advertised: `…ave.hevc` (hardware) and `…hevc.vcp`
>    (software). Also confirmed hardware on this host for completeness:
>    **4:2:0 8-bit** (Main) and **4:2:2 10-bit** (Main 4:2:2 10).
>
> **Consequence for section 6 and the pipeline (Phase 2):** target HEVC
> **4:4:4 10-bit**. SCK delivers `BGRA` (or 10-bit RGB), so the capture→encoder
> path needs a `BGRA → v410` conversion first. That is a **color-space
> conversion, not a spatial resample** — 4:4:4 keeps chroma at full resolution,
> so it does not violate I-1 — but it must stay on the media engine / zero-copy
> to hold the latency budget. Getting that transfer right is the open Phase 2
> work, not an OQ-4 blocker.

### OQ-5: What is the metadata lag?

Rect metadata arriving a frame late relative to the pixels is a visible shear
during window motion. How many frames? Does it need explicit
timestamp correlation, or is best-effort good enough? Host M0 `probe` answers
this.

> **M0 PARTIAL FINDING (2026-07-14): static alignment is pixel-exact.**
>
> With a window at rest, the AX rect (converted AX-points → display-pixels by
> the single I-3 conversion) sits exactly on the window's pixels in the SCK
> frame — verified from `probe`'s overlaid PNGs. The `px` values in the JSONL
> are a clean `pt * 2` of the `pt` values, confirming the conversion.
>
> The **lag under motion** is not yet quantified: `probe` writes a full 8 MP PNG
> per tick, so PNG encode (~300 ms) dominates and the effective poll rate is
> ~3 Hz, not the requested 10 Hz — too coarse to count frames of shear during a
> drag. To measure lag properly, decouple AX polling from PNG encode (timestamp
> rects in a tight loop; encode frames off the hot path, or drop to raw dumps).

### OQ-6: What is the largest virtual display BetterDisplay will create?

And does macOS behave sanely with a main display much larger than any physical
one? Unknown.

### Operational finding: the default control port 7000 collides with AirPlay Receiver

> **M2 FINDING (2026-07-15, Mac Studio, macOS 26): TCP 7000 is taken by
> AirPlay Receiver.** While verifying `serve`/`HostSession` end to end, the
> control channel (default port **7000**) silently failed to accept a client: a
> mock client's `connect()` *succeeded* but no framed bytes ever arrived, and the
> host's control listener never reported a connection. Cause: macOS **AirPlay
> Receiver** (Control Center, process `ControlCenter`) listens on `*:7000` by
> default, so the host's listener could not own the port and the client's socket
> landed on AirPlay instead. `lsof -nP -iTCP:7000 -sTCP:LISTEN` shows
> `ControlCe … TCP *:7000 (LISTEN)`. The **video** channel (7001) was unaffected.
>
> This is not a Transom bug — it reproduces identically on the M1 (#5) code — but
> it will bite anyone using the defaults. Mitigations: disable AirPlay Receiver
> (System Settings › General › AirDrop & Handoff), or bind the control channel to
> a free port (`serve --control-port 8770`, or the port field in the host app).
> The host app surfaces this near its port fields. A future change may move the
> default off 7000; left as-is for now to not silently change #5's CLI contract.

---

## 9. Decision log

| Decision | Rationale |
|---|---|
| Virtual display as sprite sheet, one stream | One encoder, no occlusion, popups free, no cold start (3) |
| Virtual display is the main display | Menu bar capture + AX origin alignment (3.2) |
| Virtual display created externally | `CGVirtualDisplay` is private API (3.5) |
| Native Win32 + D3D11 client, not Electron | Chromium owns DPI and resampling; cannot opt out (5) |
| Rust + windows-rs, not C++ | Cargo beats vcpkg/MSVC projects; windows-rs is a 1:1 binding so MS C++ docs translate directly. Caveat: Media Foundation / NVDEC samples are all C++, so decoder work will need translation |
| Swift for the host | Native SCK, AX, VideoToolbox, CoreGraphics |
| Two repos, not a monorepo | Different languages, toolchains, CI, and machines. Merge at M2 when the wire protocol needs a shared schema |
| AGPL-3.0 | Genuinely client-server software, so the network clause has teeth. Keeps dual-licensing open |
| Physical pixels everywhere on the wire | See `invariants.md` |
| Live resize resamples, snaps on exit | A roundtrip is 30ms+, past a drag's frame budget (2.1) |
| Resize collision clamps, does not re-tile | Reuses I-4 readback machinery; client already tolerates clamps; re-tiling moves windows the user did not touch, growing the display invalidates the capture stream (2.2) |
| `Live` throttled ~10Hz, `End` authoritative | AX cannot keep up with `WM_SIZING`; the last live is coalesced and flushed, never dropped; `End` is the 1:1 snap (2.1, ResizeThrottle) |
| Accept the DWM frame | Many-windows requirement forecloses exclusive fullscreen (5) |
| Encoder pool deferred | Solves a problem we do not have at 2-3 windows (3.4) |
