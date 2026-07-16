//! The session: owns the two TCP connections, decodes the protocol on background
//! threads, and hands the consumer a stream of high-level events plus a handle to
//! talk back to the host.
//!
//! This is the seam between the pure protocol core and whatever is driving it.
//! The headless runner (`run_headless`) and the Windows window manager
//! (`win::app`) are both just consumers of a `Session`: one prints events, the
//! other turns them into native windows. Neither touches framing or JSON.
//!
//! Blocking sockets on dedicated threads, results delivered over an `mpsc`
//! channel — no async runtime, no dependencies. The reader thread owns the
//! authoritative `WindowModel` and emits `ModelEvent`s; the consumer reconstructs
//! only the state it needs (a renderer keeps id → source-rect; a logger keeps
//! nothing).

use std::net::TcpStream;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};

use crate::model::{ModelEvent, WindowModel};
use crate::net::{self, FramedReceiver};
use crate::wire::{ClientMessage, ServerMessage, VideoMessage, PROTOCOL_VERSION};

/// What the consumer receives. Control-plane changes arrive as `Control`; video
/// arrives as `Video`; the `*Closed` variants report either channel dropping so a
/// UI can show "disconnected" and attempt a reconnect.
#[derive(Debug)]
pub enum SessionEvent {
    Control(ModelEvent),
    Video(VideoEvent),
    /// The control channel ended (host stopped, or link dropped).
    ControlClosed(Option<String>),
    /// The video channel ended.
    VideoClosed(Option<String>),
}

/// Video-channel deliveries. `Config` carries the `hvcC` parameter sets the
/// decoder must ingest first; `Frame` carries one HEVC access unit.
///
/// `seq`/`pts_micros` are retained for A/V correlation and drop detection even
/// though the current decode path keys only off arrival order (protocol.md §6).
#[derive(Debug)]
#[allow(dead_code)]
pub enum VideoEvent {
    Config { hvcc: Vec<u8> },
    Frame {
        seq: u64,
        pts_micros: u64,
        keyframe: bool,
        data: Vec<u8>,
    },
}

/// A handle to a live session: send requests to the host, and shut it down.
pub struct Session {
    control_write: Arc<Mutex<TcpStream>>,
    /// Kept so we can `shutdown()` the sockets to unblock the reader threads.
    control_stream: TcpStream,
    video_stream: Option<TcpStream>,
    threads: Vec<JoinHandle<()>>,
}

impl Session {
    /// Connect the control channel (and, if `video_port` is given, the video
    /// channel), spawn the reader threads, and return the handle plus the event
    /// receiver. The host sends a full resync immediately on connect (`hello`, a
    /// `windowCreated` per live window, a `tileLayout`), so events start flowing
    /// at once.
    pub fn connect(
        host: &str,
        control_port: u16,
        video_port: Option<u16>,
    ) -> std::io::Result<(Session, Receiver<SessionEvent>)> {
        let (tx, rx) = mpsc::channel();

        let control_stream = net::connect(host, control_port)?;
        let control_read = control_stream.try_clone()?;
        let control_write = Arc::new(Mutex::new(control_stream.try_clone()?));

        let mut threads = Vec::new();

        // Control reader: decode messages, fold into the model, emit ModelEvents.
        {
            let tx = tx.clone();
            threads.push(
                thread::Builder::new()
                    .name("transom-control".into())
                    .spawn(move || control_loop(control_read, tx))
                    .expect("spawn control thread"),
            );
        }

        // Video reader (optional, and best-effort). The control channel is the
        // essential one — it is the window manager. If the video port isn't
        // listening (e.g. the host was started without `--video`), we log and run
        // control-only rather than failing the whole session, which would leave the
        // client managing no windows at all.
        let video_stream = match video_port {
            Some(port) => match net::connect(host, port) {
                Ok(stream) => {
                    let read = stream.try_clone()?;
                    let tx = tx.clone();
                    threads.push(
                        thread::Builder::new()
                            .name("transom-video".into())
                            .spawn(move || video_loop(read, tx))
                            .expect("spawn video thread"),
                    );
                    Some(stream)
                }
                Err(e) => {
                    eprintln!(
                        "video channel connect to {host}:{port} failed: {e}; \
                         continuing control-only (windows will show the placeholder)"
                    );
                    None
                }
            },
            None => None,
        };

        Ok((
            Session {
                control_write,
                control_stream,
                video_stream,
                threads,
            },
            rx,
        ))
    }

    /// Send one message to the host on the control channel. Cheap to call from any
    /// thread; serialized by the write mutex.
    pub fn send(&self, msg: &ClientMessage) -> std::io::Result<()> {
        let mut w = self
            .control_write
            .lock()
            .map_err(|_| std::io::Error::new(std::io::ErrorKind::Other, "poisoned write lock"))?;
        net::send_message(&mut *w, msg)
    }

    /// Tear the session down: shut the sockets so the reader threads unblock and
    /// exit, then join them. Idempotent-ish; safe to call once at end of run.
    pub fn shutdown(mut self) {
        let _ = self.control_stream.shutdown(std::net::Shutdown::Both);
        if let Some(v) = &self.video_stream {
            let _ = v.shutdown(std::net::Shutdown::Both);
        }
        for t in self.threads.drain(..) {
            let _ = t.join();
        }
    }
}

fn control_loop(stream: TcpStream, tx: Sender<SessionEvent>) {
    let mut model = WindowModel::new();
    let mut rx = FramedReceiver::new(stream);
    loop {
        match rx.recv() {
            Ok(Some(payload)) => match ServerMessage::decode(&payload) {
                Ok(msg) => {
                    // Surface a protocol-version skew loudly rather than failing
                    // in confusing ways downstream (protocol.md §4 `hello`).
                    if let ServerMessage::Hello { protocol, .. } = &msg {
                        if *protocol != PROTOCOL_VERSION {
                            eprintln!(
                                "control: host speaks protocol {protocol}, client speaks \
                                 {PROTOCOL_VERSION}; proceeding but shapes may differ"
                            );
                        }
                    }
                    for ev in model.apply(msg) {
                        if tx.send(SessionEvent::Control(ev)).is_err() {
                            return; // consumer gone
                        }
                    }
                }
                Err(e) => {
                    // A single undecodable frame is logged and skipped, matching the
                    // host's tolerance for a bad frame — one malformed message must
                    // not kill the session.
                    eprintln!("control: skipping undecodable frame: {e}");
                }
            },
            Ok(None) => {
                let _ = tx.send(SessionEvent::ControlClosed(None));
                return;
            }
            Err(e) => {
                let _ = tx.send(SessionEvent::ControlClosed(Some(e.to_string())));
                return;
            }
        }
    }
}

fn video_loop(stream: TcpStream, tx: Sender<SessionEvent>) {
    let mut rx = FramedReceiver::new(stream);
    loop {
        match rx.recv() {
            Ok(Some(payload)) => match VideoMessage::decode(&payload) {
                Ok(VideoMessage::Config { hvcc }) => {
                    if tx.send(SessionEvent::Video(VideoEvent::Config { hvcc })).is_err() {
                        return;
                    }
                }
                Ok(VideoMessage::Frame {
                    seq,
                    pts_micros,
                    keyframe,
                    data,
                }) => {
                    if tx
                        .send(SessionEvent::Video(VideoEvent::Frame {
                            seq,
                            pts_micros,
                            keyframe,
                            data,
                        }))
                        .is_err()
                    {
                        return;
                    }
                }
                Err(e) => eprintln!("video: skipping undecodable frame: {e}"),
            },
            Ok(None) => {
                let _ = tx.send(SessionEvent::VideoClosed(None));
                return;
            }
            Err(e) => {
                let _ = tx.send(SessionEvent::VideoClosed(Some(e.to_string())));
                return;
            }
        }
    }
}
