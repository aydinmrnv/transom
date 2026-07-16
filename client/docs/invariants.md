# Transom: Invariants

**Status:** binding. These are not suggestions.

This document exists because Transom is built by two agents, in two languages, in
two repos, on two machines, and they will not see each other's code. Everything
here is a rule that must hold on **both** sides or the system silently produces
blurry, misaligned output that looks almost right.

If you are an agent working on either repo: read this before writing code. If a
task seems to require breaking one of these, **stop and ask**. Do not work around
it.

---

## I-1: No resampling. Ever.

The entire point of Transom is that Parsec resamples and therefore makes text
unreadable. If Transom resamples, Transom has no reason to exist.

Every stage in the pipeline must preserve 1:1 pixel mapping:

| Stage | Rule |
|---|---|
| Virtual display | Scale factor is explicit and known. Never assume 2x |
| AX geometry | Sizes set in pixels, converted once (I-3) |
| SCK capture | `SCStreamConfiguration.width/height` == the exact pixel size |
| Encode | No scaling in the encoder config |
| Wire | Physical pixels only (I-2) |
| Decode | Native output size |
| Swapchain | `DXGI_SCALING_NONE`, `ResizeBuffers` to exact physical client rect |
| Sampler | `D3D11_FILTER_MIN_MAG_MIP_POINT`. Nothing else |
| Present | Flip model, no DXGI stretch |
| DWM | Per-Monitor V2 DPI awareness via **manifest** |

**The one permitted exception:** during a live resize drag, between
`WM_ENTERSIZEMOVE` and `WM_EXITSIZEMOVE`. See architecture.md 2.1. Snap to exact
on exit.

### The test

A **1px checkerboard**. If anything, anywhere, resamples, it turns to uniform
gray. It is binary, brutal, and visible from across the room. Both sides ship a
checkerboard test pattern. Use it.

---

## I-2: The wire carries physical pixels. Always.

Not points. Not logical pixels. Not DIPs. Not scaled units.

- All coordinates and sizes on the wire are **physical pixels**, unsigned 32-bit.
- Conversion happens exactly once on each side, at the boundary, and is
  documented at the conversion site.
- No message ever carries a scale factor as part of a coordinate. Scale factor is
  metadata, not a unit.

If you find yourself multiplying by a scale factor anywhere other than a
designated boundary function, you have a bug.

---

## I-3: Coordinate spaces are named and converted only at boundaries

Four spaces exist. Confusing them is the most likely source of subtle, hard to
debug misalignment.

### VDS: Virtual Display Space (host, canonical)

- **Unit:** pixels
- **Origin:** top-left of the virtual display
- **Y axis:** down
- The virtual display **is the main display** (architecture.md 3.2), so VDS
  origin coincides with AX global origin. This is deliberate and load-bearing.
- This is the canonical space for the host. Everything the host reasons about is
  VDS pixels.

### AX: Accessibility global space (host, boundary only)

- **Unit:** points
- **Origin:** top-left of the **main** display
- **Y axis:** down

**Trap:** AX and CoreGraphics use top-left origin with Y down. Cocoa
(`NSWindow.frame`, `NSScreen`) uses **bottom-left origin with Y up**. These are
different. If you mix an `NSWindow` frame into AX math, you get a vertically
mirrored bug that looks correct on a square window.

Because the virtual display is main, VDS and AX share an origin, so the only
conversion is the scale factor:

```
vds_pixels = ax_points * backingScaleFactor
```

Do this in **one** function. Name it. Test it.

### SCK: capture space (host, boundary only)

- **Unit:** pixels
- **Origin:** top-left of the captured display
- **Y axis:** down

When capturing the whole virtual display at its native size, **SCK space == VDS**
and no conversion is needed. Verify this rather than assuming it. `SCStreamConfiguration`
takes pixel dimensions; if they do not equal the display's pixel size, SCK is
scaling and I-1 is already violated.

### CS: Client Space (client, canonical)

- **Unit:** physical pixels
- **Origin:** top-left of the proxy window's client area
- **Y axis:** down

Every proxy window maps to a VDS sub-rect. The client never learns about points,
AX, or the virtual display's internals. It receives a rect in wire pixels and a
window ID, and that is all it needs.

### Summary

```
AX points --[* scaleFactor, one function]--> VDS pixels == SCK pixels
                                                 |
                                          [wire: u32 physical px]
                                                 |
                                                 v
                                      CS physical pixels (per window)
```

**Y is down in all four spaces.** If you ever flip Y, you are wrong.

---

## I-4: The client owns window geometry. The host obeys.

The Windows PC is the real window manager. The Mac only draws.

- The client decides where windows are, how big they are, and which is focused.
- The host's job is to make the Mac match, via AX, and report what actually
  happened.
- The host **never** repositions a window on its own initiative except when
  re-tiling to satisfy the non-overlap guarantee, and when it does, it must
  report the new rects.

**Corollary:** AX writes can be refused, clamped, or rounded (OQ-2). The host
must always read back after writing and report the **actual** geometry, not the
requested geometry. The client must handle "you asked for 2560x1440 and got
2560x1438" without breaking.

---

## I-5: Windows on the virtual display never overlap

This is what buys us: every window always renders, no occlusion, popups free.

- The tiler must guarantee non-overlap at all times.
- If a new window cannot fit, that is an error to surface, **not** an occasion to
  overlap. See the tiling budget (architecture.md 3.3).
- Transient windows (menus, popovers) are the hard case: they are positioned by
  the application, not by us, and they may land on top of another window. How to
  handle this is unresolved and depends on OQ-1.

---

## I-6: Nothing depends on the physical Mac display

The virtual display is the entire world. The Mac Studio's real monitor is
incidental and may be disconnected, asleep, or a different size. No code may
assume its presence, resolution, or scale factor.

---

## I-7: Verify on the target machine, or do not claim it works

Neither half of this system can be verified anywhere but its own machine:

- **Host:** TCC grants, display enumeration, whether NSMenu popups land in an SCK
  capture. Only answerable on the Mac Studio. A GitHub `macos-latest` runner will
  report no Screen Recording grant and a headless display config, so **CI can
  prove the Swift compiles and nothing more.**
- **Client:** whether physical client rect equals swapchain size at 150% scaling.
  Only answerable on the Windows box with a real scaled monitor.

**"CI is green" is not "it works." "I inferred it works" is not "it works."**
Show real output from the real machine or say plainly that you could not.

---

## I-8: Ask before adding dependencies

Host: `swift-argument-parser` only.
Client: `windows` (windows-rs) plus a manifest embedder (`embed-resource` or
`winres`) only.

Anything else, ask first. This is a systems project where the dependencies *are*
the difficulty; a crate that hides DXGI or AX behind a friendly abstraction will
hide exactly the thing being investigated.
