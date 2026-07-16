# AGENTS.md: transom-host

You are working on the **macOS host** half of Transom.

## Read first, in this order

1. `docs/architecture.md` — the design and why. Canonical copy lives here.
2. `docs/invariants.md` — **binding rules.** Not suggestions.
3. `docs/roadmap.md` — what milestone we are in and what is out of scope.
4. `docs/protocol.md` — the eventual contract with the client. Draft. Do not
   implement.

## What this is

Transom streams individual macOS windows to a Windows PC as independent native
windows. This repo is the Mac side. It captures pixels and obeys geometry
commands. **It is not the window manager. The client is.**

The other half lives in the `client/` half (Rust, Windows). You will never see it,
and its agent will never see this repo. `docs/` is the only shared context, which
is why it is written the way it is.

## Non-negotiables

- **No resampling** (invariants I-1). This project exists because Parsec
  resamples. If Transom resamples, it has no reason to exist.
- **Coordinate spaces** (invariants I-3). AX is points, top-left origin, Y down.
  Cocoa is bottom-left origin, Y up. Mixing them produces a vertically mirrored
  bug that looks correct on a square window. Convert in **one** named function.
- **AX writes must be read back** (invariants I-4). Report actual geometry, never
  requested geometry. macOS may clamp, round, or refuse.
- **Windows never overlap on the virtual display** (invariants I-5).
- **Never create the virtual display.** `CGVirtualDisplay` is private API. It is
  created externally with BetterDisplay; you receive a display ID.
- **Nothing depends on the physical Mac display** (invariants I-6).

## Stack

- Swift 6, strict concurrency, SwiftPM executable target. No Xcode project, no
  XcodeGen.
- macOS 14+.
- ScreenCaptureKit for capture. **Not** the deprecated `CGDisplayStream`.
- ApplicationServices / `AXUIElement` for window control.
- VideoToolbox for encode (M3, not yet).
- `swift-argument-parser` is the **only** dependency. Ask before adding any
  other (invariants I-8).
- Logging via `os.Logger`.

## Verification: this matters more than usual

**CI cannot verify this repo.** A GitHub `macos-latest` runner has no Screen
Recording grant and a headless display config. CI proves the Swift compiles and
**nothing else** (invariants I-7).

Everything real must be run on the Mac Studio and the **actual output pasted**.
Not inferred. Not "should work." Not "CI is green."

If you cannot run something, say so plainly. A previous agent scaffolded both
repos from the wrong machine and reported inferences as verification, which cost
a round trip.

**TCC trap:** a CLI run from a terminal has Screen Recording and Accessibility
attributed to the **terminal app**, not to your binary. `doctor` must say this
explicitly. Also: SSH sessions have no GUI session, so permission checks give
false negatives. Run from Terminal directly.

## Current milestone: M0, the diagnostic probe

Answer three questions. Build nothing else. No networking, no encoding, no
client.

1. **OQ-1:** Do `NSMenu` popups, sheets, and completion popups appear in an SCK
   capture? Does AX report them with usable frames?
2. **OQ-2:** Are AX geometry writes honored exactly, or clamped/rounded?
3. **OQ-5:** Do AX rects align pixel-exactly with SCK pixels, and by how many
   frames does the metadata lag?

See `docs/roadmap.md` M0-host for the command list.

**Start with `menuwatch`.** It answers OQ-1, which is the question most likely to
kill the project. If menus do not land in the capture, everything else here is
wasted effort and we need to know on day one, not month three.

**`place` must report the readback delta.** The delta is the entire point of the
command. "It worked" is not the output; "requested 2560x1440, got 2560x1438" is.

## Out of scope right now

Networking, encoding, the wire protocol, virtual display creation, the encoder
pool, audio, clipboard, auth. If a task seems to need one of these, stop and ask.

## Style

- Commit incrementally with real messages. Not one giant commit.
- Structured logs over print statements.
- When you hit something surprising about macOS behavior, **write it into
  `docs/architecture.md` section 8 as an open question or a finding.** The docs
  are the deliverable as much as the code, because they are the only thing the
  other half of the project can see.
