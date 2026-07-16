//! The Transom wire protocol, client side — the concrete realisation of
//! `docs/protocol.md` and the mirror of the host's `WireProtocol.swift`.
//!
//! Everything under `wire` is **pure Rust with no `windows-rs`**. That is
//! deliberate: the wire is the one part of the client that must agree
//! byte-for-byte with the other half of the project, so it is kept free of any
//! platform dependency and unit-tested on its own. On a Mac it even compiles and
//! runs, which is how the protocol gets verified against the live Swift host
//! without a Windows box (invariants I-7).

pub mod control;
pub mod frame;
pub mod input;
pub mod json;
pub mod video;

// These are the crate's wire API surface. Several are exercised only by the
// cross-platform unit tests or by the non-Windows runner, so on a Windows-only
// build they read as unused even though they are not.
#[allow(unused_imports)]
pub use control::{
    ClientMessage, DecodeError, Rect, ResizePhase, ServerMessage, Size, TileWindow, WindowKind,
};
#[allow(unused_imports)]
pub use frame::{frame, FrameError, FrameReader};
#[allow(unused_imports)]
pub use input::{InputEvent, MouseButton};
#[allow(unused_imports)]
pub use video::{VideoDecodeError, VideoMessage};

/// The protocol version this client speaks, checked against the host's `hello`.
pub const PROTOCOL_VERSION: u32 = 1;

/// Default TCP ports (protocol.md §1). These are defaults, not wire constants;
/// the host can be told to use others, and the control default collides with
/// macOS AirPlay Receiver, so it is frequently overridden.
pub const DEFAULT_CONTROL_PORT: u16 = 7000;
pub const DEFAULT_VIDEO_PORT: u16 = 7001;
