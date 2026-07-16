//! TCP plumbing for the two channels (protocol.md §1). Blocking `std::net`,
//! driven by threads in `session` — no async runtime, no new dependencies.
//!
//! Pure and platform-independent: it compiles and runs on any host, which is what
//! lets the client's protocol layer be pointed at the real Swift host on
//! `127.0.0.1` and verified cross-language without a Windows box (invariants I-7).

use std::io::{self, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

use crate::wire::frame::{frame, FrameReader};
use crate::wire::ClientMessage;

/// Open a control/video TCP connection to the host, with `TCP_NODELAY` set —
/// Nagle silently adds tens of milliseconds and the host disables it on its side
/// too (protocol.md §1).
pub fn connect(host: &str, port: u16) -> io::Result<TcpStream> {
    // Resolve explicitly so a bad host/port gives a clear error, and so we can
    // apply a connect timeout rather than blocking the default ~75s.
    let addr = (host, port).to_socket_addrs()?.next().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            format!("no address for {host}:{port}"),
        )
    })?;
    let stream = TcpStream::connect_timeout(&addr, Duration::from_secs(10))?;
    stream.set_nodelay(true)?;
    Ok(stream)
}

/// Reads length-prefixed frames off any `Read` (a `TcpStream`, or a `Cursor` in
/// tests). Owns a `FrameReader` and a scratch buffer so callers just loop on
/// `recv()`.
pub struct FramedReceiver<R: Read> {
    inner: R,
    frames: FrameReader,
    scratch: Vec<u8>,
}

impl<R: Read> FramedReceiver<R> {
    pub fn new(inner: R) -> Self {
        FramedReceiver {
            inner,
            frames: FrameReader::default(),
            scratch: vec![0u8; 64 * 1024],
        }
    }

    /// Block until the next whole frame's payload is available, or return `None`
    /// at a clean end of stream (peer closed on a frame boundary).
    pub fn recv(&mut self) -> io::Result<Option<Vec<u8>>> {
        loop {
            // Drain anything already buffered before touching the socket.
            match self.frames.next_frame() {
                Ok(Some(payload)) => return Ok(Some(payload)),
                Ok(None) => {}
                Err(e) => return Err(io::Error::new(io::ErrorKind::InvalidData, e.to_string())),
            }
            let n = self.inner.read(&mut self.scratch)?;
            if n == 0 {
                // EOF. A partial frame here means the peer died mid-message; treat
                // that as an unexpected end so the caller can distinguish it.
                return Ok(None);
            }
            self.frames.push(&self.scratch[..n]);
        }
    }
}

/// Frame and write one client→host message. Flushes so it hits the wire
/// immediately (the socket is `TCP_NODELAY`, but the userspace `BufWriter`, if
/// any, still needs flushing — here we write straight to the stream).
pub fn send_message<W: Write>(w: &mut W, msg: &ClientMessage) -> io::Result<()> {
    let payload = msg.encode();
    w.write_all(&frame(&payload))?;
    w.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::{ResizePhase, ServerMessage, Size};
    use std::io::Cursor;

    #[test]
    fn receiver_reassembles_framed_messages() {
        // Two framed control messages back to back in one buffer.
        let mut stream = Vec::new();
        stream.extend_from_slice(&frame(
            br#"{"type":"hello","protocol":1,"vdsSize":{"w":100,"h":100}}"#,
        ));
        stream.extend_from_slice(&frame(br#"{"type":"windowFocused","id":3}"#));

        let mut rx = FramedReceiver::new(Cursor::new(stream));
        let first = ServerMessage::decode(&rx.recv().unwrap().unwrap()).unwrap();
        assert_eq!(
            first,
            ServerMessage::Hello {
                protocol: 1,
                vds: Size { w: 100, h: 100 }
            }
        );
        let second = ServerMessage::decode(&rx.recv().unwrap().unwrap()).unwrap();
        assert_eq!(second, ServerMessage::WindowFocused { id: 3 });
        assert!(rx.recv().unwrap().is_none()); // clean EOF
    }

    #[test]
    fn send_message_frames_with_length_prefix() {
        let mut out = Vec::new();
        send_message(
            &mut out,
            &ClientMessage::RequestResize {
                id: 1,
                size: Size { w: 640, h: 480 },
                phase: ResizePhase::End,
            },
        )
        .unwrap();
        // 4-byte BE length prefix, then the JSON body.
        let len = u32::from_be_bytes([out[0], out[1], out[2], out[3]]) as usize;
        assert_eq!(len, out.len() - 4);
        let body = std::str::from_utf8(&out[4..]).unwrap();
        assert!(body.starts_with(r#"{"type":"requestResize""#));
    }
}
