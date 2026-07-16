# Transom: Roadmap

The organizing principle: **build the thing that answers the kill questions in a
day, not the thing that looks like a demo in a month.**

Everything about encoding, networking, and latency is known-solvable, because
Parsec already demonstrates it on this exact hardware pair. The unknowns are
narrow and specific. Attack those first, cheapest first.

---

## M0: Probes (current)

Two independent tasks. Different repos, different machines, no dependency on each
other. Run them in parallel.

### M0-host: the diagnostic probe

**Answers:** OQ-1 (menus in capture), OQ-2 (AX write fidelity), OQ-5 (metadata lag).

Swift CLI, no networking, no encoding, no client.

| Command | Purpose |
|---|---|
| `doctor` | TCC grants, displays, SCK availability. **Done.** |
| `displays` | id, bounds, scale factor |
| `windows <app>` | AX windows: title, frame, role, subrole, resizable |
| `place <app> <idx> <display> <x> <y> <w> <h>` | Set AXPosition/AXSize, **read back, report the delta** |
| `tile <app> <display>` | Tile non-overlapping, report layout and whether it fits |
| `capture <display> --out <path>` | SCK stream, dump PNG, log actual dims and pixel format |
| `probe <app> <display> --out <dir>` | SCK stream + AX rects polled at ~10Hz, dump frames with rects drawn as outlines, JSONL log per frame |
| `menuwatch <app>` | AXObserver on window created/destroyed. Print every window with frame, role, subrole |

**`menuwatch` is the highest-value command in the project.** Open Xcode's Product
menu and a code-completion popup and see what shows up. If menus do not appear in
an SCK capture with usable AX frames, Transom does not work, and everything else
is wasted effort.

**Run `menuwatch` first.**

### M0-client: the rendering probe

**Answers:** can Windows hold the 1:1 guarantee at all?

Rust + windows-rs + D3D11. No networking, no decoder, no host. Synthetic source.

- N borderless windows, each rendering a test pattern
- **1px checkerboard** (the important one), 1px grid, frame counter, sample text
- Per-window diagnostic overlay, always visible:
  - client rect in physical pixels
  - swapchain buffer dimensions
  - monitor DPI and scale factor
  - **physical client rect == swapchain size?** loud green/red. This is pass/fail
  - frame time, present latency
- Geometry event log (`WM_SIZE`, `WM_SIZING`, `WM_ENTERSIZEMOVE`,
  `WM_EXITSIZEMOVE`, `WM_DPICHANGED`) with physical pixel values to stdout

**Exit criteria:** checkerboard stays razor sharp at 100%, 150%, and 200%
scaling, and while dragging between monitors at different scale factors.

### M0 gate

Do not start M1 until:

- [ ] `menuwatch` has a clear answer on OQ-1
- [ ] `place` has a clear answer on OQ-2 (exact? clamped? rounded?)
- [ ] Checkerboard holds 1:1 at 150%
- [ ] The tiling budget is computed for the real window set

If OQ-1 comes back badly, **stop and redesign.** Do not proceed on hope.

---

## M0.5: The zero-code test

Worth doing before or alongside M0, because it is one hour and validates the
entire thesis:

1. BetterDisplay: create a virtual display at exactly the pixel size you want on
   the Windows monitor (e.g. 2560x1440), scale 1x
2. Drag Xcode onto it
3. Point Parsec at **that display** instead of the main one
4. Size the Parsec window to exactly 2560x1440 on the PC

**If Xcode is crisp and readable, the thesis is confirmed:** the fix is
resolution matching, not codecs, and Transom is worth building.

**If it is still soft,** something is resampling that has not been found, and
that needs to be understood before writing a line of Swift.

Highest information per hour available anywhere in this project.

---

## M1: Independent halves

- **Host:** real tiling on the virtual display, SCK capture at exact size, rects
  emitted as JSONL. Still no network.
- **Client:** proxy windows driven by a **fake** rect feed (a JSON file, or the
  host's JSONL from M0). Real window management, real 1:1 blitting, fake data.

The client consuming the host's JSONL output offline is the cheap integration
test that does not require a network stack.

---

## M2: The wire

Protocol implementation. See `protocol.md`.

- Control channel first (TCP, window lifecycle + geometry roundtrip)
- Geometry mirroring end to end, uncompressed or trivially compressed video
- **Merge the repos here.** This is where a shared schema stops being optional.

**Exit criteria:** resize a proxy window on Windows, watch Xcode relayout on the
Mac. Ugly, slow, correct.

---

## M3: Make it fast

- HEVC 4:4:4 hardware encode (pending OQ-4)
- Custom UDP video transport, no jitter buffer
- NVDEC decode into a D3D11 texture, zero copy
- Latency measurement and tuning

**Target: 25-35ms end to end** (architecture.md 5). Not Parsec, good enough.

---

## M4: Usable daily

- Input roundtrip that feels right
- Focus and window raise semantics
- The menu bar, whatever OQ-1 says the answer is
- Rounded corners matching macOS radius
- Reconnect and state resync
- Per-window scale factor (1x for space, 2x for Retina). **Parsec structurally
  cannot offer this choice.** It is the feature that makes Transom better rather
  than merely different.

---

## Deferred, documented so it is not reinvented

- Encoder pool + attention throttling (architecture.md 3.4)
- Clipboard, audio, multi-host
- Auth, encryption, anything internet-facing
- Native Win32 rewrite of anything prototyped otherwise
