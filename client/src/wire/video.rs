//! The video channel payload format (protocol.md §6). Binary, length-prefixed
//! like the control channel, but the payload is not JSON: a leading type byte
//! distinguishes the HEVC parameter sets from an access unit.
//!
//! The mirror of the host's `VideoWire`. Pure and byte-oriented, so it is
//! unit-tested without a decoder or a socket.

/// One decoded video-channel message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VideoMessage {
    /// `0x01` — the HEVC `hvcC` configuration record (VPS/SPS/PPS). Sent before
    /// the first frame and again after a reconnect; an `hvc1` stream carries no
    /// inline parameter sets, so the decoder needs this first.
    Config { hvcc: Vec<u8> },
    /// `0x02` — one access unit: monotonic `seq`, host-clock `pts_micros`, a
    /// keyframe flag, and the raw HEVC bytes.
    Frame {
        seq: u64,
        pts_micros: u64,
        keyframe: bool,
        data: Vec<u8>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VideoDecodeError {
    Empty,
    UnknownTag(u8),
    /// A `frame` payload was shorter than its fixed header.
    TruncatedFrame(usize),
}

impl std::fmt::Display for VideoDecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            VideoDecodeError::Empty => write!(f, "empty video payload"),
            VideoDecodeError::UnknownTag(t) => write!(f, "unknown video tag 0x{t:02x}"),
            VideoDecodeError::TruncatedFrame(n) => {
                write!(f, "truncated frame payload ({n} bytes, need >= 18)")
            }
        }
    }
}

impl std::error::Error for VideoDecodeError {}

/// The fixed frame header after the 1-byte tag: seq(8) + pts(8) + flags(1).
const FRAME_HEADER_LEN: usize = 1 + 8 + 8 + 1;

impl VideoMessage {
    /// Decode one de-framed video-channel payload.
    pub fn decode(payload: &[u8]) -> Result<VideoMessage, VideoDecodeError> {
        let (&tag, rest) = payload.split_first().ok_or(VideoDecodeError::Empty)?;
        match tag {
            0x01 => Ok(VideoMessage::Config {
                hvcc: rest.to_vec(),
            }),
            0x02 => {
                if payload.len() < FRAME_HEADER_LEN {
                    return Err(VideoDecodeError::TruncatedFrame(payload.len()));
                }
                let seq = be_u64(&payload[1..9]);
                let pts_micros = be_u64(&payload[9..17]);
                let keyframe = payload[17] & 0x01 != 0;
                Ok(VideoMessage::Frame {
                    seq,
                    pts_micros,
                    keyframe,
                    data: payload[FRAME_HEADER_LEN..].to_vec(),
                })
            }
            other => Err(VideoDecodeError::UnknownTag(other)),
        }
    }
}

fn be_u64(bytes: &[u8]) -> u64 {
    let mut arr = [0u8; 8];
    arr.copy_from_slice(&bytes[..8]);
    u64::from_be_bytes(arr)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Reproduce the host's `VideoWire.encodeFrame` byte layout so the test pins
    /// the wire format, not just this module's own round-trip.
    fn host_encode_frame(seq: u64, pts: u64, keyframe: bool, data: &[u8]) -> Vec<u8> {
        let mut out = vec![0x02];
        out.extend_from_slice(&seq.to_be_bytes());
        out.extend_from_slice(&pts.to_be_bytes());
        out.push(if keyframe { 1 } else { 0 });
        out.extend_from_slice(data);
        out
    }

    #[test]
    fn decodes_config() {
        let mut payload = vec![0x01];
        payload.extend_from_slice(&[0xDE, 0xAD, 0xBE, 0xEF]);
        assert_eq!(
            VideoMessage::decode(&payload).unwrap(),
            VideoMessage::Config {
                hvcc: vec![0xDE, 0xAD, 0xBE, 0xEF]
            }
        );
    }

    #[test]
    fn decodes_keyframe() {
        let payload = host_encode_frame(1, 16_000, true, &[1, 2, 3]);
        assert_eq!(
            VideoMessage::decode(&payload).unwrap(),
            VideoMessage::Frame {
                seq: 1,
                pts_micros: 16_000,
                keyframe: true,
                data: vec![1, 2, 3],
            }
        );
    }

    #[test]
    fn decodes_non_keyframe() {
        let payload = host_encode_frame(9_000_000_000, 33_000, false, &[]);
        match VideoMessage::decode(&payload).unwrap() {
            VideoMessage::Frame {
                seq,
                pts_micros,
                keyframe,
                data,
            } => {
                assert_eq!(seq, 9_000_000_000);
                assert_eq!(pts_micros, 33_000);
                assert!(!keyframe);
                assert!(data.is_empty());
            }
            other => panic!("wrong variant: {other:?}"),
        }
    }

    #[test]
    fn rejects_short_frame() {
        // Tag + only 4 bytes: well under the 18-byte header.
        assert_eq!(
            VideoMessage::decode(&[0x02, 0, 0, 0, 0]),
            Err(VideoDecodeError::TruncatedFrame(5))
        );
    }

    #[test]
    fn rejects_unknown_tag_and_empty() {
        assert_eq!(
            VideoMessage::decode(&[0x09]),
            Err(VideoDecodeError::UnknownTag(0x09))
        );
        assert_eq!(VideoMessage::decode(&[]), Err(VideoDecodeError::Empty));
    }
}
