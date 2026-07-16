//! The headless wire runner: `transom-client connect <host>`.
//!
//! It connects to a running host, prints the protocol as it arrives, and can send
//! test input / resize requests back. No window, no decoder — just the wire.
//!
//! Its real job is verification. Because the whole protocol core is pure Rust,
//! this runs on any host, so pointing it at the Swift host on `127.0.0.1` proves
//! the two halves agree on the wire — the one thing the merged repo exists to
//! protect — without needing the Windows box (invariants I-7). On Windows it also
//! doubles as a connection diagnostic.

use std::collections::HashMap;
use std::process::ExitCode;
use std::sync::mpsc::RecvTimeoutError;
use std::time::{Duration, Instant};

use crate::model::ModelEvent;
use crate::session::{Session, SessionEvent, VideoEvent};
use crate::vk;
use crate::wire::{
    ClientMessage, InputEvent, MouseButton, Rect, ResizePhase, Size, DEFAULT_CONTROL_PORT,
    DEFAULT_VIDEO_PORT,
};

/// Parsed `connect` options.
struct Options {
    host: String,
    control_port: u16,
    video_port: Option<u16>,
    seconds: Option<f64>,
    type_text: Option<String>,
    click: Option<(u64, u32, u32)>,
    resize: Option<(u64, u32, u32)>,
}

pub fn run(args: &[String]) -> ExitCode {
    let opts = match parse(args) {
        Ok(o) => o,
        Err(msg) => {
            eprintln!("connect: {msg}\n");
            print_usage();
            return ExitCode::FAILURE;
        }
    };

    println!(
        "connecting to {}:{} (control){}",
        opts.host,
        opts.control_port,
        opts.video_port
            .map(|p| format!(", {}:{} (video)", opts.host, p))
            .unwrap_or_default()
    );

    let (session, rx) = match Session::connect(&opts.host, opts.control_port, opts.video_port) {
        Ok(pair) => pair,
        Err(e) => {
            eprintln!("connect failed: {e}");
            eprintln!(
                "hint: is `transom-host serve` running on {}? the default control port {} \
                 also collides with macOS AirPlay Receiver — try --control-port 7010.",
                opts.host, DEFAULT_CONTROL_PORT
            );
            return ExitCode::FAILURE;
        }
    };

    let started = Instant::now();
    let now_ms = || started.elapsed().as_millis() as u64;

    // Local mirror of the window set, so we can pick a default target for
    // --type/--click/--resize and print titles.
    let mut windows: HashMap<u64, (String, Rect)> = HashMap::new();
    let mut order: Vec<u64> = Vec::new();
    let mut vds: Option<Size> = None;

    // Actions that fire once, after the first window is known.
    let mut pending_actions =
        opts.type_text.is_some() || opts.click.is_some() || opts.resize.is_some();

    let mut frames = 0u64;
    let mut video_bytes = 0u64;
    let mut last_video_report = Instant::now();

    let deadline = opts.seconds.map(|s| started + Duration::from_secs_f64(s));

    loop {
        if let Some(d) = deadline {
            if Instant::now() >= d {
                println!("[{:>6}ms] duration elapsed, closing", now_ms());
                break;
            }
        }

        let event = match rx.recv_timeout(Duration::from_millis(200)) {
            Ok(ev) => ev,
            Err(RecvTimeoutError::Timeout) => {
                maybe_run_actions(
                    &opts,
                    &session,
                    &order,
                    &windows,
                    &mut pending_actions,
                    now_ms(),
                );
                continue;
            }
            Err(RecvTimeoutError::Disconnected) => {
                println!("[{:>6}ms] session ended", now_ms());
                break;
            }
        };

        match event {
            SessionEvent::Control(ev) => {
                apply_for_display(&ev, &mut windows, &mut order, &mut vds);
                print_control(&ev, now_ms());
            }
            SessionEvent::Video(VideoEvent::Config { hvcc }) => {
                println!(
                    "[{:>6}ms] video: hvcC config, {} bytes (decoder can now start)",
                    now_ms(),
                    hvcc.len()
                );
            }
            SessionEvent::Video(VideoEvent::Frame {
                seq,
                keyframe,
                data,
                ..
            }) => {
                frames += 1;
                video_bytes += data.len() as u64;
                // Rate-limit the video log to once a second so it doesn't drown the
                // control-plane trace.
                if last_video_report.elapsed() >= Duration::from_secs(1) {
                    let mbps = (video_bytes as f64 * 8.0)
                        / 1_000_000.0
                        / last_video_report.elapsed().as_secs_f64();
                    println!(
                        "[{:>6}ms] video: {frames} frames, {mbps:.1} Mbps (last seq {seq}, {})",
                        now_ms(),
                        if keyframe { "keyframe" } else { "delta" }
                    );
                    video_bytes = 0;
                    last_video_report = Instant::now();
                }
            }
            SessionEvent::ControlClosed(reason) => {
                println!(
                    "[{:>6}ms] control channel closed{}",
                    now_ms(),
                    reason.map(|r| format!(": {r}")).unwrap_or_default()
                );
                break;
            }
            SessionEvent::VideoClosed(reason) => {
                println!(
                    "[{:>6}ms] video channel closed{}",
                    now_ms(),
                    reason.map(|r| format!(": {r}")).unwrap_or_default()
                );
            }
        }

        maybe_run_actions(
            &opts,
            &session,
            &order,
            &windows,
            &mut pending_actions,
            now_ms(),
        );
    }

    session.shutdown();
    ExitCode::SUCCESS
}

/// Update the display mirror from a model event.
fn apply_for_display(
    ev: &ModelEvent,
    windows: &mut HashMap<u64, (String, Rect)>,
    order: &mut Vec<u64>,
    vds: &mut Option<Size>,
) {
    match ev {
        ModelEvent::Connected { vds: size } => *vds = Some(*size),
        ModelEvent::WindowAdded(w) => {
            if !order.contains(&w.id) {
                order.push(w.id);
            }
            windows.insert(w.id, (w.title.clone(), w.source));
        }
        ModelEvent::WindowRectChanged { id, source, .. } => {
            if let Some(entry) = windows.get_mut(id) {
                entry.1 = *source;
            }
        }
        ModelEvent::WindowTitleChanged { id, title } => {
            if let Some(entry) = windows.get_mut(id) {
                entry.0 = title.clone();
            }
        }
        ModelEvent::WindowRemoved { id } => {
            windows.remove(id);
            order.retain(|x| x != id);
        }
        ModelEvent::Resynced { removed } => {
            for id in removed {
                windows.remove(id);
                order.retain(|x| x != id);
            }
        }
        _ => {}
    }
}

fn print_control(ev: &ModelEvent, t: u64) {
    match ev {
        ModelEvent::Connected { vds } => {
            println!("[{t:>6}ms] connected — VDS {}x{}", vds.w, vds.h)
        }
        ModelEvent::WindowAdded(w) => println!(
            "[{t:>6}ms] + window {} \"{}\" {:?} source ({},{}) {}x{}",
            w.id, w.title, w.kind, w.source.x, w.source.y, w.source.w, w.source.h
        ),
        ModelEvent::WindowRectChanged {
            id,
            source,
            size_changed,
        } => println!(
            "[{t:>6}ms] ~ window {id} -> ({},{}) {}x{}{}",
            source.x,
            source.y,
            source.w,
            source.h,
            if *size_changed { " [resized]" } else { "" }
        ),
        ModelEvent::WindowTitleChanged { id, title } => {
            println!("[{t:>6}ms] ~ window {id} title \"{title}\"")
        }
        ModelEvent::WindowFocused { id } => println!("[{t:>6}ms] * window {id} focused"),
        ModelEvent::WindowRemoved { id } => println!("[{t:>6}ms] - window {id} destroyed"),
        ModelEvent::Resynced { removed } => {
            println!("[{t:>6}ms] resync pruned {removed:?}")
        }
        ModelEvent::HostError { code, message } => {
            println!("[{t:>6}ms] ! host error {code}: {message}")
        }
    }
}

/// Fire the one-shot test actions once a target window exists.
fn maybe_run_actions(
    opts: &Options,
    session: &Session,
    order: &[u64],
    windows: &HashMap<u64, (String, Rect)>,
    pending: &mut bool,
    ts: u64,
) {
    if !*pending {
        return;
    }
    let Some(&target) = order.first() else {
        return; // no window yet
    };
    *pending = false;

    // Raise the target first so input lands in the right place (protocol.md §4).
    if opts.type_text.is_some() || opts.click.is_some() {
        let _ = session.send(&ClientMessage::RequestFocus { id: target });
        println!("[{ts:>6}ms] -> requestFocus {target}");
    }

    if let Some((id, x, y)) = opts.click {
        send_click(session, id, x, y, ts);
    }

    if let Some(text) = &opts.type_text {
        send_text(session, target, text, ts);
    }

    if let Some((id, w, h)) = opts.resize {
        // A full Begin/Live/End cycle: the host throttles Live and snaps on End.
        for phase in [ResizePhase::Begin, ResizePhase::Live, ResizePhase::End] {
            let _ = session.send(&ClientMessage::RequestResize {
                id,
                size: Size { w, h },
                phase,
            });
        }
        let name = windows.get(&id).map(|e| e.0.as_str()).unwrap_or("?");
        println!("[{ts:>6}ms] -> requestResize {id} \"{name}\" to {w}x{h} (begin/live/end)");
    }
}

fn send_click(session: &Session, id: u64, x: u32, y: u32, ts: u64) {
    let _ = session.send(&ClientMessage::Input {
        id,
        event: InputEvent::MouseDown {
            x,
            y,
            button: MouseButton::Left,
        },
        ts,
    });
    let _ = session.send(&ClientMessage::Input {
        id,
        event: InputEvent::MouseUp {
            x,
            y,
            button: MouseButton::Left,
        },
        ts,
    });
    println!("[{ts:>6}ms] -> click window {id} at ({x},{y})");
}

fn send_text(session: &Session, id: u64, text: &str, ts: u64) {
    for c in text.chars() {
        let Some(code) = vk::vk_for_ascii(c) else {
            eprintln!("connect: skipping un-typeable character {c:?}");
            continue;
        };
        let shift = vk::needs_shift(c);
        if shift {
            let _ = session.send(&ClientMessage::Input {
                id,
                event: InputEvent::KeyDown { vk: vk::VK_SHIFT },
                ts,
            });
        }
        let _ = session.send(&ClientMessage::Input {
            id,
            event: InputEvent::KeyDown { vk: code },
            ts,
        });
        let _ = session.send(&ClientMessage::Input {
            id,
            event: InputEvent::KeyUp { vk: code },
            ts,
        });
        if shift {
            let _ = session.send(&ClientMessage::Input {
                id,
                event: InputEvent::KeyUp { vk: vk::VK_SHIFT },
                ts,
            });
        }
    }
    println!("[{ts:>6}ms] -> typed {:?} into window {id}", text);
}

fn parse(args: &[String]) -> Result<Options, String> {
    let mut host: Option<String> = None;
    let mut control_port = DEFAULT_CONTROL_PORT;
    let mut video_port: Option<u16> = None;
    let mut seconds: Option<f64> = None;
    let mut type_text: Option<String> = None;
    let mut click: Option<(u64, u32, u32)> = None;
    let mut resize: Option<(u64, u32, u32)> = None;

    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];
        match arg.as_str() {
            "--control-port" => {
                control_port = take(args, &mut i, "--control-port")?
                    .parse()
                    .map_err(|_| "invalid --control-port".to_string())?;
            }
            "--video" => {
                video_port.get_or_insert(DEFAULT_VIDEO_PORT);
            }
            "--video-port" => {
                let p = take(args, &mut i, "--video-port")?
                    .parse()
                    .map_err(|_| "invalid --video-port".to_string())?;
                video_port = Some(p);
            }
            "--seconds" => {
                seconds = Some(
                    take(args, &mut i, "--seconds")?
                        .parse()
                        .map_err(|_| "invalid --seconds".to_string())?,
                );
            }
            "--type" => {
                type_text = Some(take(args, &mut i, "--type")?);
            }
            "--click" => {
                click = Some(parse_triple(&take(args, &mut i, "--click")?, "--click")?);
            }
            "--resize" => {
                resize = Some(parse_triple(&take(args, &mut i, "--resize")?, "--resize")?);
            }
            other if other.starts_with('-') => {
                return Err(format!("unknown option {other}"));
            }
            _ => {
                if host.is_some() {
                    return Err("unexpected extra argument".to_string());
                }
                host = Some(arg.clone());
            }
        }
        i += 1;
    }

    Ok(Options {
        host: host.ok_or("missing host (an IP like 192.168.1.20 or 127.0.0.1)")?,
        control_port,
        video_port,
        seconds,
        type_text,
        click,
        resize,
    })
}

fn take(args: &[String], i: &mut usize, name: &str) -> Result<String, String> {
    *i += 1;
    args.get(*i)
        .cloned()
        .ok_or_else(|| format!("{name} needs a value"))
}

/// Parse an `id:a:b` triple used by --click (id:x:y) and --resize (id:w:h).
fn parse_triple(s: &str, name: &str) -> Result<(u64, u32, u32), String> {
    let parts: Vec<&str> = s.split(':').collect();
    if parts.len() != 3 {
        return Err(format!("{name} expects id:a:b"));
    }
    let id = parts[0].parse().map_err(|_| format!("{name}: bad id"))?;
    let a = parts[1]
        .parse()
        .map_err(|_| format!("{name}: bad second field"))?;
    let b = parts[2]
        .parse()
        .map_err(|_| format!("{name}: bad third field"))?;
    Ok((id, a, b))
}

pub fn print_usage() {
    println!(
        "transom-client connect — drive the wire protocol against a running host\n\
         \n\
         USAGE:\n    \
         transom-client connect <host> [options]\n\
         \n\
         OPTIONS:\n    \
         --control-port <n>   control channel port (default 7000; 7010 dodges AirPlay)\n    \
         --video              also open the video channel on the default port (7001)\n    \
         --video-port <n>     also open the video channel on <n>\n    \
         --seconds <n>        run for n seconds then disconnect (default: until Ctrl-C)\n    \
         --type <text>        focus the first window and type <text> (US/ANSI keys)\n    \
         --click <id:x:y>     left-click window <id> at window-local pixel (x,y)\n    \
         --resize <id:w:h>    request a begin/live/end resize of window <id> to w x h\n\
         \n\
         EXAMPLE:\n    \
         transom-client connect 127.0.0.1 --control-port 7010 --seconds 5 --type hello"
    );
}
