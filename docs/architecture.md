# Transom architecture

**This document is canonical.** The `transom-host` (macOS) and `transom-client`
(Windows) repos both defer to it. If code and this document disagree, the
disagreement is a bug in one of them — fix it, don't fork the design.

Status: pre-alpha. This describes the intended system. Almost none of it is
built yet.

---

## The problem

I want individual macOS app windows — a single Xcode window, a single Conductor
window — to appear on my Windows PC as independent, native windows that I can
move, resize, snap, and fullscreen with the Windows window manager. Not a
mirrored desktop. Not a VNC rectangle. Windows that behave like local windows
but are rendered by a Mac.

This is RDS RemoteApp with the roles reversed: a **Mac host** serving seamless
windows to a **Windows client**. That product does not exist.

The closest thing that works today is Parsec. Parsec streams my Mac Studio to my
Windows PC at genuinely excellent quality — low latency, sharp, hardware
encoded. But its *windowed* mode scales the **entire remote desktop** into the
window. Shrink the Parsec window to Xcode-sized and you are downscaling a
5K desktop into a small rectangle: the text becomes an unreadable smear. Parsec
is doing exactly what it was built to do (present a whole desktop), and that is
exactly the wrong thing for a single window.

The core insight: **this is a resampling problem, not a codec problem.** The
codec is fine. The image is ruined before and after the codec by scaling steps
that should not exist. Every resampling stage in the pipeline is a bug.

## Why this doesn't already exist (and the easy direction does)

The *reverse* direction — a Windows host serving seamless apps to any client —
is a solved, commodding problem:

- Windows has **RDS RemoteApp**: the OS itself knows how to render one
  application's windows into a remote session and ship them as separate windows.
- `xfreerdp /app:` consumes exactly that.
- The Windows compositor (DWM) is effectively network-transparent for this use
  case, and Win32 apps carry their menus **inside** their own windows.

macOS gives you none of that:

1. **No RDS equivalent.** There is no supported OS facility for "render this one
   app's windows into a headless session and stream them out as windows." Screen
   sharing is whole-desktop.
2. **WindowServer is not network transparent.** You cannot ask the compositor
   for a per-window surface stream over the wire. You get pixels off a display,
   not a structured window feed.
3. **Global menu bar.** Mac apps put their menus in the **global menu bar at the
   top of the screen**, not inside each window. Lift one window out of its
   desktop context and you have lifted it away from its menus — you get a
   menu-less app. (See `menuwatch`: the host has to observe the focused app's
   menu tree and the client has to re-present it.)

So the Windows-host direction is easy because the platform was built for it, and
the Mac-host direction is hard because every affordance you'd want is missing.
Transom builds the missing pieces on top of the primitives macOS *does* give us:
ScreenCaptureKit for pixels, the Accessibility (AX) API for geometry and menus.

## The design: virtual display as a sprite sheet

The naive approach is one capture stream and one encoder **per window**. That is
wrong on multiple axes: N encoders don't fit, each new window has a cold-start
cost, and occluded/off-screen windows stop rendering so you capture nothing.

Transom does the opposite. There is **one** large **virtual display** on the Mac
that nobody ever looks at. It is a compositing scratch space — a sprite sheet.

- The virtual display is created **externally with BetterDisplay**. Transom does
  **not** create it programmatically. (`CGVirtualDisplay` is private API and is
  explicitly out of scope.)
- All managed app windows are **tiled onto it non-overlapping** via the AX API
  (`tile`, `place`). Because nothing overlaps and nothing is off-screen, **every
  window always renders and is never occluded.**
- **One** ScreenCaptureKit stream captures that whole display. **One** hardware
  encoder. (`capture`.)
- The client receives the single shared texture and **crops per-window
  sub-rectangles** out of it. Each cropped rect is drawn into its own native
  Windows window.

What this buys us:

- **One encoder, not N.** Fixed, predictable GPU cost regardless of window count.
- **No occlusion.** Non-overlapping tiling guarantees live pixels for every
  window, every frame.
- **Popups are free.** NSMenus, sheets, tooltips, and popovers are already
  inside the captured frame, so they cost nothing extra to transport — *if* they
  land on the virtual display where we can see them (see Open questions).
- **No cold start.** A newly focused window is already being captured; there is
  no per-window stream to spin up.

Window rectangles — which sub-rect of the shared texture is which logical
window, and where — travel on a **side metadata channel**, separate from the
video. The client is the source of truth for where windows go on the Windows
desktop; the host is the source of truth for where they currently sit on the
virtual display.

**Division of responsibility:** the **Windows client is the real window
manager.** It owns window placement, focus, stacking, fullscreen, snapping. The
**Mac host only draws** — it tiles for capture convenience, not for a human.
Nobody looks at the virtual display.

## Geometry mirroring and the no-resampling rule

This is the whole point, so it gets its own rule:

> **When the client window is W×H pixels, the Mac window is set to exactly W×H
> pixels, and the pixels are blitted 1:1.**

The flow:

1. The client window is resized (by the user, or by Windows snapping).
2. The client sends the new pixel size over the metadata channel.
3. The host sets the Mac window to **exactly** that size via the AX API
   (`AXUIElementSetAttributeValue` on `kAXSizeAttribute`), and re-tiles.
4. The Mac app **relayouts natively** at the new size — text reflows, controls
   move, everything is rendered at native resolution for that size.
5. The new frame is captured and blitted to the client **1:1**, no scaling.

There is never a downscale of a big desktop, never an upscale of a small
capture. The remote app genuinely renders at the size you're viewing. That is
why the text stays sharp where Parsec's smears: **there is no resampling stage to
smear it.**

Scale factors (Retina 2× vs Windows per-monitor DPI) are accounted for as
*integer backing ratios*, not as arbitrary image scaling. The client is built
Per-Monitor-V2 DPI aware (via application manifest) precisely so it can map
physical pixels 1:1 without the OS silently rescaling underneath it.

## The live-resize compromise

The no-resampling rule cannot hold *during* an interactive drag-resize.

A round trip — client sends new size → host writes AX size → app relayouts →
frame captured → frame encoded → frame arrives — is **30 ms or more**. A window
drag produces new sizes far faster than that; you'd blow the frame budget on
every mouse-move and the drag would feel like glue.

So during a live resize we do what RDP does, and accept it honestly:

- **Accept transient blur** while the drag is in flight. The client scales the
  most recent 1:1 frame to fill the changing window — this is the *only* place
  resampling is allowed, and only because it is temporary.
- **Throttle AX `setSize`** to roughly **10 Hz** so we don't flood the host with
  writes the app can't keep up with.
- **Snap to crisp on `WM_EXITSIZEMOVE`.** When the drag ends, send the final
  size once, let the app relayout, and blit the resulting frame 1:1.

Steady state is always crisp. Only the moving edge is soft, only while it moves.

## Open questions (stated honestly)

These are unresolved and are why the `probe` command exists. None are known to
work; each is a de-risking experiment (a separate task).

1. **Do NSMenu popups appear in ScreenCaptureKit capture of the virtual
   display?** The "popups are free" claim depends on this. NSMenus are rendered
   in their own windows and may be placed by the system on the *active* display
   or near the cursor rather than on the virtual display we're capturing. If they
   don't land in our frame, they aren't free and need separate handling.
   (`probe menu-capture`.)

2. **Are AX geometry writes honored exactly, or clamped?** Geometry mirroring
   assumes `kAXSizeAttribute`/`kAXPositionAttribute` writes land at the exact
   pixel size we request. Apps and the window server may clamp to minimum sizes,
   snap to increments, refuse certain sizes, or round. If a window won't become
   exactly W×H, the 1:1 blit has to cope with the discrepancy. (`probe
   ax-geometry`.)

3. **What is the tiling budget?** Every managed window must fit *simultaneously*
   and *non-overlapping* on one virtual display. How many windows, at what sizes,
   before we run out of virtual display area? What's the largest virtual display
   BetterDisplay will give us, and does capture/encode cost scale with its total
   pixel area? This bounds how many windows a session can hold. (`probe
   tile-budget`.)

## Hardware context

The target rig this is being designed against:

- **Host:** M1 Max Mac Studio.
- **Client:** Core Ultra 9 285K / RTX 5090 / Windows 11.
- **Network:** wired LAN.

Design decisions assume this envelope (a fast local network, a capable encoder
on each end). They are not tuned for WAN or for low-end hardware yet.

## Component map

| Concern | Host (`transom-host`, Swift) | Client (`transom-client`, Rust) |
| --- | --- | --- |
| Pixels | one SCK stream of the virtual display (`capture`) | crop sub-rects, blit 1:1 (D3D11) |
| Geometry in | apply AX size/pos (`place`, `tile`) | send desired pixel size |
| Geometry out | report window rects | own real window placement / WM |
| Menus | observe global menu bar (`menuwatch`) | re-present menus in/near window |
| Health | `doctor` | `doctor` |
| De-risking | `probe` | — |
