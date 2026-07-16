# Transom: Wire Protocol (DRAFT)

**Status:** draft. **Not implemented. Do not implement it yet.**

This document exists early on purpose. The host and client are built by separate
agents who cannot see each other's code, and they will meet at M2. Writing the
contract down now is what stops them from inventing incompatible models of
coordinate spaces, units, and window identity.

Treat this as the shared mental model, not a spec to code against. It will change
once M0 answers OQ-1 and OQ-3.

---

## 1. Channels

Two channels, different requirements:

| Channel | Transport | Requirement |
|---|---|---|
| **Video** | Custom UDP | Lowest possible latency. No jitter buffer. Frames may be dropped, never delayed |
| **Control** | TCP or reliable UDP | Ordered, reliable. Window lifecycle, geometry, input |

**Video is not WebRTC.** See architecture.md section 5: WebRTC's jitter buffer is
50-100ms and `playoutDelayHint: 0` does not remove it. This is settled.

Control is low bandwidth (a few KB/s) and correctness matters more than latency,
so plain TCP is fine for v1.

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

**Unresolved.** See architecture.md OQ-3.

Every rect on the wire needs a stable ID the client keys its proxy windows on.
SCK exposes `CGWindowID`; AX exposes `AXUIElement`; correlating them may require
private API (`_AXUIElementGetWindow`).

**Provisional:** `WindowId` is an opaque `u64` minted by the host. The host owns
the mapping to whatever it uses internally. The client treats it as a token and
never interprets it.

This lets both sides proceed while OQ-3 is open, and confines the eventual answer
to the host.

---

## 4. Control messages

Illustrative shape, not final. Serialization undecided (probably CBOR or
length-prefixed JSON for v1; readable beats fast at a few KB/s).

### Host -> Client

```
WindowCreated  { id: u64, rect: Rect, title: String, kind: WindowKind }
WindowDestroyed{ id: u64 }
WindowMoved    { id: u64, rect: Rect }          // ACTUAL geometry, see I-4
WindowTitle    { id: u64, title: String }
WindowFocused  { id: u64 }
TileLayout     { windows: [(u64, Rect)], display_size: Size }
Error          { code: u32, message: String }
```

`WindowKind` distinguishes a normal window from transient UI (menu, sheet,
popover), because the client must not give a menu a resizable frame or an
Alt+Tab entry. The exact taxonomy depends on what AX subroles actually report
(OQ-1).

### Client -> Host

```
RequestResize  { id: u64, size: Size, phase: ResizePhase }
RequestFocus   { id: u64 }
RequestClose   { id: u64 }
Input          { id: u64, event: InputEvent, ts: u64 }
```

`ResizePhase` is `Begin | Live | End`, mapping to `WM_ENTERSIZEMOVE` /
`WM_SIZING` / `WM_EXITSIZEMOVE`. The host throttles `Live` to ~10Hz and treats
`End` as the authoritative 1:1 snap (architecture.md 2.1).

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

---

## 6. Video frames

```
FrameHeader {
  seq: u64,
  pts: u64,           // host monotonic clock, microseconds
  vds_size: Size,     // full virtual display, for sanity checking
  keyframe: bool,
}
```

Rect metadata lives on the control channel, not in the frame header. The client
correlates by timestamp.

**Open:** how much correlation is actually needed. Metadata arriving a frame late
is a visible shear during window motion (OQ-5). Host M0 `probe` measures this. If
the lag is under a frame, best-effort may be fine and the timestamp correlation
can be dropped.

---

## 7. Codec

- **HEVC 4:4:4**, pending OQ-4 (does the M1 Max encode 4:4:4 in hardware?).
- 4:2:0 is a fallback that **fails the product's purpose** on text. If 4:4:4 is
  not available in hardware, that is a finding to escalate, not to work around.
- No scaling in the encoder config (I-1).

---

## 8. Not designed yet

- **Auth and encryption.** Assume a trusted wired LAN. Do not ship this over the
  internet.
- **Clipboard.** Wanted eventually, not now.
- **Audio.** Later, if ever.
- **Multiple hosts or clients.** One to one.
- **Reconnect and state resync.** Needed before it is usable daily.
- **Cursor.** Whose cursor renders where, and does the Mac cursor need to be
  captured separately or synthesized on the client? Genuinely unresolved.
