//! Length-prefix framing (protocol.md §1): every message on both channels is a
//! 4-byte big-endian unsigned length followed by that many payload bytes.
//!
//! This is the exact mirror of the host's `FrameBuffer` (`WireProtocol.swift`).
//! It is pure and stream-agnostic — the same reassembly serves the control
//! channel (JSON payloads) and the video channel (binary payloads), and it is
//! unit-tested without a socket.

/// The default cap on a single frame's claimed length: reject anything larger so
/// a corrupt or hostile prefix can't make us buffer unbounded memory. 64 MiB
/// matches the host.
pub const DEFAULT_MAX_FRAME_LEN: usize = 64 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FrameError {
    /// A length prefix exceeded the configured maximum.
    TooLarge { claimed: usize, max: usize },
}

impl std::fmt::Display for FrameError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FrameError::TooLarge { claimed, max } => {
                write!(f, "frame length {claimed} exceeds maximum {max}")
            }
        }
    }
}

impl std::error::Error for FrameError {}

/// Reassembles whole frames from a byte stream that arrives in arbitrary chunks.
pub struct FrameReader {
    buf: Vec<u8>,
    /// Read cursor into `buf`. We advance this instead of draining from the front
    /// on every frame, and compact only when it grows large, so a busy video
    /// stream doesn't pay an O(n) `drain` per frame.
    start: usize,
    max_frame_len: usize,
}

impl Default for FrameReader {
    fn default() -> Self {
        Self::new(DEFAULT_MAX_FRAME_LEN)
    }
}

impl FrameReader {
    pub fn new(max_frame_len: usize) -> Self {
        FrameReader {
            buf: Vec::new(),
            start: 0,
            max_frame_len,
        }
    }

    /// Feed freshly-read bytes.
    pub fn push(&mut self, data: &[u8]) {
        self.buf.extend_from_slice(data);
    }

    /// Pop the next complete frame's payload, or `None` if not enough bytes have
    /// arrived yet. Call in a loop after each `push` until it returns `None`.
    pub fn next_frame(&mut self) -> Result<Option<Vec<u8>>, FrameError> {
        let available = self.buf.len() - self.start;
        if available < 4 {
            self.compact_if_needed();
            return Ok(None);
        }
        let header = &self.buf[self.start..self.start + 4];
        let len = u32::from_be_bytes([header[0], header[1], header[2], header[3]]) as usize;
        if len > self.max_frame_len {
            return Err(FrameError::TooLarge {
                claimed: len,
                max: self.max_frame_len,
            });
        }
        if available < 4 + len {
            self.compact_if_needed();
            return Ok(None);
        }
        let payload = self.buf[self.start + 4..self.start + 4 + len].to_vec();
        self.start += 4 + len;
        self.compact_if_needed();
        Ok(Some(payload))
    }

    /// Reclaim consumed prefix bytes once they dominate the buffer, keeping memory
    /// bounded without a per-frame move.
    fn compact_if_needed(&mut self) {
        if self.start == 0 {
            return;
        }
        // Compact when the consumed region is both large and a majority of the
        // buffer, so steady-state cost stays amortized O(1) per byte.
        if self.start >= 64 * 1024 && self.start * 2 >= self.buf.len() {
            self.buf.drain(..self.start);
            self.start = 0;
        }
    }
}

/// Prefix a payload with its 4-byte big-endian length, producing one framed
/// message ready to write to a socket.
pub fn frame(payload: &[u8]) -> Vec<u8> {
    let len = payload.len() as u32;
    let mut out = Vec::with_capacity(payload.len() + 4);
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(payload);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_and_reassembles_one_message() {
        let framed = frame(b"hello");
        assert_eq!(&framed[..4], &[0, 0, 0, 5]);
        let mut r = FrameReader::default();
        r.push(&framed);
        assert_eq!(r.next_frame().unwrap(), Some(b"hello".to_vec()));
        assert_eq!(r.next_frame().unwrap(), None);
    }

    #[test]
    fn reassembles_across_arbitrary_chunk_boundaries() {
        let mut stream = Vec::new();
        stream.extend_from_slice(&frame(b"one"));
        stream.extend_from_slice(&frame(b"two"));
        stream.extend_from_slice(&frame(b"three"));

        let mut r = FrameReader::default();
        let mut out = Vec::new();
        // Feed one byte at a time — the worst case for a length-prefix reader.
        for b in &stream {
            r.push(&[*b]);
            while let Some(f) = r.next_frame().unwrap() {
                out.push(String::from_utf8(f).unwrap());
            }
        }
        assert_eq!(out, vec!["one", "two", "three"]);
    }

    #[test]
    fn handles_multiple_frames_in_one_chunk() {
        let mut stream = Vec::new();
        stream.extend_from_slice(&frame(b"a"));
        stream.extend_from_slice(&frame(b"bb"));
        let mut r = FrameReader::default();
        r.push(&stream);
        assert_eq!(r.next_frame().unwrap(), Some(b"a".to_vec()));
        assert_eq!(r.next_frame().unwrap(), Some(b"bb".to_vec()));
        assert_eq!(r.next_frame().unwrap(), None);
    }

    #[test]
    fn empty_payload_is_a_valid_frame() {
        let mut r = FrameReader::default();
        r.push(&frame(b""));
        assert_eq!(r.next_frame().unwrap(), Some(Vec::new()));
    }

    #[test]
    fn rejects_oversized_length() {
        let mut r = FrameReader::new(8);
        r.push(&[0x00, 0x00, 0x00, 0x10]); // claims 16 bytes, max is 8
        assert_eq!(
            r.next_frame(),
            Err(FrameError::TooLarge {
                claimed: 16,
                max: 8
            })
        );
    }

    #[test]
    fn compacts_without_losing_frames() {
        // Push far more than the 64 KiB compaction threshold to exercise the drain.
        let mut r = FrameReader::default();
        let big = frame(&vec![7u8; 100 * 1024]);
        r.push(&big);
        assert_eq!(r.next_frame().unwrap().unwrap().len(), 100 * 1024);
        // Buffer should have been compacted back to empty.
        r.push(&frame(b"after"));
        assert_eq!(r.next_frame().unwrap(), Some(b"after".to_vec()));
    }
}
