# Transom: Wire Protocol

**Status:** v1, **implemented on the host** (issue #3). The control channel and
the video channel described here are what `transom-host serve` actually speaks.
This is now a spec to code against, not a sketch. If you change a shape, change
the host (`Sources/TransomKit/WireProtocol.swift`) and this file in the same
commit, or the two halves diverge.

The host and client are built by separate agents who cannot see each other's
code. This document is the only shared context, which is why the byte-level
shapes below are exact.

**Transport for v1 is TCP** (see §1). The custom-UDP video transport is the M3
target and is deliberately behind an interface so it does not touch anything
above the transport line.

---

## 1. Channels

Two **separate TCP connections**, not one. A 200KB video frame must never
head-of-line-block a geometry message, so control and video get their own
sockets.

| Channel | v1 transport | Default port | Requirement |
|---|---|---|---|
| **Control** | TCP | 7000 | Ordered, reliable. Window lifecycle, geometry, input |
| **Video** | TCP | 7001 | Lowest latency achievable on TCP. Frames may be dropped, never delayed |

> **Deployment trap (measured, issue #6):** macOS's **AirPlay Receiver listens on
> port 7000** (`ControlCenter`, on all interfaces). A client connecting to the Mac
> on 7000 can reach AirPlay instead of the host, which accepts the TCP handshake
> and then speaks no Transom protocol (looks like "connected but no `hello`").
> Either disable AirPlay Receiver (System Settings → General → AirDrop & Handoff)
> or run the host on another port (`serve --control-port 7010`). The port numbers
> here are defaults, not wire constants.

### Why TCP for v1 (not UDP)

`docs/protocol.md` used to say custom UDP for video. **That is the M3 target, not
v1.** On a wired LAN, loss is effectively zero, and loss is the only thing TCP's
head-of-line blocking punishes. TCP for v1 removes packet reassembly, reordering,
and FEC from the critical path and gets a working system months earlier. The
swap to UDP is contained behind a `PacketTransport` interface on the host
(`Sources/TransomKit/Transport.swift`); it moves whole messages, so the framing
in §4/§6 is all a UDP transport would need to reproduce (one datagram = one
message).

- **`TCP_NODELAY` on both connections.** Nagle silently adds tens of ms.
- **Video is not WebRTC.** WebRTC's jitter buffer is 50-100ms and
  `playoutDelayHint: 0` does not remove it (architecture.md §5). Settled.
- The host **binds only to a private address** (10/8, 172.16/12, 192.168/16,
  127/8, 169.254/16) and refuses anything else. There is no auth and no
  encryption; see the README security note. The client connects by IP — no
  discovery, no Bonjour.

### Framing

Both channels are length-prefixed message streams: **a 4-byte big-endian
unsigned length, then that many payload bytes.** On the control channel the
payload is UTF-8 JSON (§4). On the video channel the payload is binary (§6).

---

## 2. Units and coordinates

Restating `invariants.md` I-2 and I-3 because this is where they get violated:

- **All coordinates and sizes are physical pixels, `u32`.**
- **Never points. Never logical pixels. Never DIPs.**
- Window rects are in **VDS** (Virtual Display Space): origin top-left of the
  virtual display, Y down.
- The client never learns about points, AX, or the virtual display's scale
  factor. It gets a rect and a window ID.

---

## 3. Window identity

`WindowId` is an opaque **`u64` minted by the host** (starting at 1). The client
treats it as a token, keys its proxy windows on it, and **never interprets it**.
An id is stable for the lifetime of the window and is not reused within a session.

The host maps each id to an `AXUIElement` in a `WindowRegistry`
(`Sources/TransomKit/WindowRegistry.swift`). However OQ-3 is eventually resolved
(private `_AXUIElementGetWindow`, frame heuristics, …), that correlation stays
confined to the host behind this id. The client is unaffected by the answer.

---

## 4. Control messages

**Serialization: length-prefixed UTF-8 JSON.** Readable beats fast at a few KB/s.
Every message is a flat JSON object with a `"type"` discriminator and the fields
below — *not* a nested/enum encoding, so any language decodes it trivially. Field
names are exact. `u64` ids are JSON numbers (the client is Rust; no 2^53 issue).

On connect (and on every reconnect) the host sends, in order: **`hello`**, one
**`windowCreated`** per live window, then a **`tileLayout`** — a full resync — and
then streams live events. The host keeps running if the client drops; a
reconnecting client gets the full resync again.

### Host -> Client

```
hello          { protocol: u32, vdsSize: Size }         // first message; version + display size
windowCreated  { id: u64, rect: Rect, title: String, kind: WindowKind }
windowDestroyed{ id: u64 }
windowMoved    { id: u64, rect: Rect }                  // ACTUAL geometry, see I-4
windowTitle    { id: u64, title: String }
windowFocused  { id: u64 }
tileLayout     { windows: [{ id: u64, rect: Rect }], displaySize: Size }
error          { code: u32, message: String }
```

Concrete bytes on the wire (one framed control message):

```
00 00 00 5b  {"type":"windowMoved","id":1,"rect":{"x":2300,"y":500,"w":1312,"h":844}}
^ 4-byte BE length = 0x5b   ^ JSON payload
```

`WindowKind` distinguishes a normal window from transient UI (menu, sheet,
popover), because the client must not give a menu a resizable frame or an
Alt+Tab entry. The exact taxonomy depends on what AX subroles actually report
(OQ-1).

### Client -> Host

The `"type"` discriminator is **camelCase on the wire**, matching the host's
`WireProtocol.swift` (`"requestResize"`, `"requestFocus"`, `"requestClose"`,
`"input"`) — the same casing as the host→client messages above. The names below
are the semantic message names; the wire value is the camelCase form. (The host
is authoritative here; this line was corrected to match it — AGENTS.md.)

```
requestResize  { id: u64, size: Size, phase: ResizePhase }
requestFocus   { id: u64 }
requestClose   { id: u64 }
input          { id: u64, event: InputEvent, ts: u64 }
```

`ResizePhase` is `Begin | Live | End`, mapping to `WM_ENTERSIZEMOVE` /
`WM_SIZING` / `WM_EXITSIZEMOVE`. The host throttles `Live` to ~10Hz and treats
`End` as the authoritative 1:1 snap (architecture.md 2.1).

### Input events (`Input`) — issue #7

`Input` carries one `InputEvent` as a nested object under `event`. On the wire
the outer message uses the usual `"type":"input"` discriminator; the nested event
uses its own `"kind"` discriminator. `ts` is the client's monotonic timestamp in
**milliseconds**, opaque to the host in v1 (logged, not otherwise used).

```
mouseDown { kind:"mouseDown", x:u32, y:u32, button:"left"|"right"|"middle" }
mouseUp   { kind:"mouseUp",   x:u32, y:u32, button:"left"|"right"|"middle" }
mouseMove { kind:"mouseMove", x:u32, y:u32 }
scroll    { kind:"scroll",    x:u32, y:u32, dx:i32, dy:i32 }   // signed line deltas
keyDown   { kind:"keyDown",   vk:u32 }                         // Windows VK code
keyUp     { kind:"keyUp",     vk:u32 }
```

Concrete bytes on the wire (one framed control message):

```
00 00 00 5e  {"type":"input","id":7,"event":{"kind":"mouseDown","x":400,"y":300,"button":"left"},"ts":12897}
```

- **`x`/`y` are window-local physical pixels** (CS, invariants I-2/I-3): origin at
  the proxy window's top-left, **Y down**. The client sends CS and nothing else —
  translating CS → VDS → AX points is entirely the host's job (it knows the
  window's VDS rect and the display scale). The client never learns about VDS, AX,
  points, or the scale factor.
- **`vk` is a Windows virtual-key code, not a macOS keycode.** The client sends
  what its physical keyboard reports; the host maps VK → macOS keycode. **Unmapped
  VKs are reported (logged) and dropped, never silently swallowed.** The table
  covers letters, digits, whitespace/editing, arrows, navigation, F1–F12, the OEM
  punctuation, and the numeric keypad, for the **US/ANSI** layout; the character a
  key produces depends on the Mac's active layout.

**Modifier state is tracked on the host, not sent per-event.** The client sends
raw `keyDown`/`keyUp` for modifier keys too (e.g. `VK_CONTROL`); the host keeps a
small modifier state machine and stamps the resulting flags onto every event it
posts (key **and** mouse), so a held ⌘ stays held across multiple keydowns. The
client does **not** attach per-event modifier flags.

**Key repeat: the client sends repeats** (one `keyDown` per OS key-repeat tick).
The host does **not** synthesize repeats. Pick one, not both — this is the one.

**Cmd vs Ctrl (resolved):** the host maps Windows modifiers to macOS with a
**swap** by default — **Ctrl → ⌘ Command, Win → ⌃ Control, Alt → ⌥ Option, Shift →
⇧** — so `Ctrl+C` on the PC is `⌘C` (copy) on the Mac, matching muscle memory.
`serve --namesake-modifiers` switches to the literal 1:1 mapping (Ctrl → ⌃, Win →
⌘). This is a **host-side policy**: the wire always carries raw Windows VK codes,
so the client is unaffected by the choice and needs no changes if it flips.

**Focus/raise.** `RequestFocus` raises the target Mac window (AX raise + activate
its app). A `mouseDown` on a window that is not frontmost also raises it first, so
the click lands in the right place. Raising changes the Mac's one frontmost app
and key window; a client-"focused" window may still render unfocused until the
raise happens (accepted, see issue #7 / invariants I-4).

### Types

```
Rect { x: u32, y: u32, w: u32, h: u32 }   // VDS physical pixels
Size { w: u32, h: u32 }                    // physical pixels
```

---

## 5. The geometry roundtrip

The one flow worth getting right, because it is the whole product:

```
1. User drags proxy window edge on Windows
2. Client: WM_SIZING -> RequestResize { phase: Live }   [throttled ~10Hz]
3. Host:   AX setSize
4. Host:   AX readback                                   [I-4: read back!]
5. Host:   WindowMoved { ACTUAL rect }
6. Client: updates its sub-rect mapping, keeps resampling during drag
7. User releases
8. Client: WM_EXITSIZEMOVE -> RequestResize { phase: End }
9. Host:   AX setSize, readback, WindowMoved
10. Client: ResizeBuffers to exact size, snap to 1:1, stop resampling
```

**Step 4 and 5 are non-negotiable.** The host reports what macOS actually did,
never what was asked for. AX writes can be clamped or rounded (OQ-2), and the
client must handle "asked 2560x1440, got 2560x1438" without breaking.

There are **two** reasons a `windowMoved` can come back smaller than the
`RequestResize` asked for, and the client treats them identically (it just uses
the actual rect):

1. **App minimum size.** The Mac app refuses to go below its own floor (OQ-2).
2. **Non-overlap clamp.** Growth would collide with a neighbour on the virtual
   display, so the host stops it a gutter short (I-5; architecture.md 2.2). At one
   window this never happens.

The host throttles `Live` to ~10Hz (a roundtrip is 30ms+, past a drag's frame
budget); intermediate `Live` requests are coalesced, and the newest is still
applied so a paused drag catches up. `End` is never throttled — it is the
authoritative 1:1 snap and always produces a final `windowMoved`.

---

## 6. Video frames

The video channel is **binary**, length-prefixed like the control channel (§1),
but the payload is not JSON. The first payload byte is a type tag:

```
0x01  config   : hvcC ...                          // HEVC parameter sets (VPS/SPS/PPS)
0x02  frame    : seq:u64  ptsMicros:u64  flags:u8  hevc...   // one access unit
                 flags bit0 = keyframe.  integers big-endian.
```

- **`config` is sent first**, before the first frame, and again after a
  reconnect. An `hvc1` stream carries no inline parameter sets, so the decoder
  needs the `hvcC` configuration record before it can decode anything.
- **`frame`** carries `seq` (monotonic), `ptsMicros` (host clock, microseconds),
  a keyframe flag, and the raw HEVC access-unit bytes. The codec is **HEVC**; the
  **chroma is selectable on the host** (`serve --chroma`, §7):
  - **`420` — HEVC Main 4:2:0 8-bit (the default).** This is what the Windows
    client's in-box Media Foundation H.265 decoder (`CLSID_CMSH265DecoderMFT`) can
    actually decode — Main/Main10 4:2:0 → NV12 — so real pixels appear with no
    extra decoder. Chroma subsampling softens *colored* text edges a little (luma,
    and so black-on-white text, stays full-resolution).
  - **`444` — HEVC 4:4:4 10-bit.** The crisp-text quality target (architecture.md
    OQ-4). The client's in-box Media Foundation decoder tops out at Main10 4:2:0
    and does not display this stream today (it stays on the placeholder — the
    known blocker this default routes around), so it is **opt-in, not the
    default**, until a 4:4:4-capable client decode path exists and is verified on a
    real Windows box (I-7). Note: a reference decoder reads the host's current
    `444` output as `Main 10 / yuv420p10le`, so whether it is truly 4:4:4 or 10-bit
    4:2:0 is itself unverified — a separate finding from making streaming *work*.

  The client does not need to be told which chroma is in use: both 4:2:0 modes
  decode to NV12 on the same path, and if a 4:4:4 stream is sent to an in-box-only
  client it simply decodes zero frames (the client warns after ~120 undecoded
  access units rather than failing silently).

Rect metadata lives on the **control** channel, not in the frame header; the
client correlates by timestamp.

**Open:** how much correlation is actually needed. Metadata arriving a frame late
is a visible shear during window motion (OQ-5). If the lag is under a frame,
best-effort may be fine and timestamp correlation can be dropped.

---

## 7. Codec

- **HEVC.** The host hardware-encodes it (OQ-4 confirmed the M1 Max encodes 4:4:4
  in hardware). No scaling in the encoder config (I-1).
- **Chroma is selectable (`serve --chroma 420|444`), and the default is `420`.**
  This is a pragmatic split between "decodes today" and "the quality target":
  - **4:2:0 8-bit (default)** exists because the client's *in-box* HEVC decoder
    cannot decode anything finer. Without it the client shows only its placeholder
    checkerboard — no picture at all. A slightly-soft-on-colored-text picture that
    the stock decoder can display beats a crisp one it cannot. Luma is not
    subsampled, so black-on-white text stays sharp; the cost is at *colored* text
    edges (syntax highlighting).
  - **4:4:4 10-bit** remains the north star for crisp colored text. It is one flag
    away and fully implemented on the host; it is not the default only because the
    *client* side of it (a 4:4:4-capable decoder — vendor MFT or software) does not
    exist yet. When it does, flip the default back.
- Historically this section said "4:2:0 is a fallback that fails the product's
  purpose." That is still the aspiration for chroma quality — but a codec the far
  end can't decode fails the product *more* completely (a blank window), so the
  default optimises for a visible picture first.

---

## 8. Cursor (resolved) and what is still deferred

**Cursor: captured, not synthesized.** The host sets
`SCStreamConfiguration.showsCursor = true`, so the real Mac cursor is already in
the captured frame, pixel-correct, for free. Input posts `CGEvent`s (Phase 5),
the real cursor moves, SCK captures it. **The client hides its own OS cursor when
it is over a proxy window** so there are not two cursors. Simplest correct answer
for v1.

Still deferred:

- **Auth and encryption.** Assume a trusted wired LAN. Do not ship this over the
  internet. The host refuses to bind to a non-private address as a guardrail, not
  a security boundary.
- **Clipboard.** Wanted eventually, not now.
- **Audio.** Later, if ever.
- **Multiple hosts or clients.** One to one; the host serves one client at a time.

Reconnect and state resync are **implemented** (§4): the host keeps running when
the client drops, and a reconnecting client gets a full resync.
