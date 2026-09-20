//! The native Windows window manager: `transom-client run [<host>]`.
//!
//! This is the real client (architecture.md): it opens the control channel, turns
//! each Mac window into a native borderless proxy window, samples that window's
//! sub-rect out of the decoded stream, and blits it 1:1 with point sampling.
//! Resize, DPI changes, focus, and input all round-trip to the host.
//!
//! Everything under `win` is `#[cfg(windows)]`. It is verified only by
//! compilation on a Windows toolchain (there is no runtime harness on a Mac —
//! invariants I-7); the wire it speaks is the same one the pure `wire`/`model`
//! core is unit-tested against and was driven live against the Swift host, so the
//! protocol half is trustworthy and this half is the native shell around it.

mod app;
mod connect;
mod decode;
mod dpi;
mod frame;
mod gallery;
mod gpu;
mod input;
mod proxy;

use std::process::ExitCode;

use windows::Win32::System::Com::{CoInitializeEx, COINIT_APARTMENTTHREADED};

use crate::wire::{DEFAULT_CONTROL_PORT, DEFAULT_VIDEO_PORT};
use app::{App, AppConfig};

struct Args {
    host: String,
    control_port: u16,
    video_port: Option<u16>,
    checkerboard: bool,
}

pub fn run(args: &[String]) -> ExitCode {
    let parsed = if args.is_empty() || args == ["--interactive"] {
        None
    } else {
        match parse(args) {
            Ok(a) => Some(a),
            Err(msg) => {
                connect::show_error(Default::default(), &msg);
                print_usage();
                return ExitCode::FAILURE;
            }
        }
    };

    // COM is needed for Media Foundation (the decoder). Apartment-threaded is fine
    // for a single UI thread; the decoder is driven from the pump.
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
    }

    let gpu = match gpu::Gpu::new() {
        Ok(g) => g,
        Err(e) => {
            connect::show_error(
                Default::default(),
                &format!("Could not initialize graphics: {e}"),
            );
            return ExitCode::FAILURE;
        }
    };

    if let Err(e) = app::register_class() {
        eprintln!("failed to register window class: {e}");
        return ExitCode::FAILURE;
    }

    let dashboard = match connect::Dashboard::new() {
        Ok(d) => d,
        Err(e) => {
            connect::show_error(Default::default(), &format!("Could not open Transom: {e}"));
            return ExitCode::FAILURE;
        }
    };
    let cfg = parsed.map(|p| AppConfig {
        host: p.host,
        control_port: p.control_port,
        video_port: p.video_port,
        checkerboard: p.checkerboard,
    });
    app::run_pump(Box::new(App::new(gpu, cfg, dashboard)));
    ExitCode::SUCCESS
}

fn parse(args: &[String]) -> Result<Args, String> {
    let mut host: Option<String> = None;
    let mut control_port = DEFAULT_CONTROL_PORT;
    // Video is ON by default: `run` is the real window manager, and with video off
    // every window shows only the placeholder checkerboard, which reads as "the app
    // is broken." `--no-video` opts out for control-plane-only debugging. The video
    // channel is best-effort (see `Session::connect`), so defaulting it on can't
    // stop the client from managing windows when the host has no video.
    let mut video_port: Option<u16> = Some(DEFAULT_VIDEO_PORT);
    let mut checkerboard = false;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--control-port" => {
                i += 1;
                control_port = args
                    .get(i)
                    .ok_or("--control-port needs a value")?
                    .parse()
                    .map_err(|_| "invalid --control-port")?;
            }
            "--video" => {
                video_port.get_or_insert(DEFAULT_VIDEO_PORT);
            }
            "--no-video" => {
                video_port = None;
            }
            "--video-port" => {
                i += 1;
                let p = args
                    .get(i)
                    .ok_or("--video-port needs a value")?
                    .parse()
                    .map_err(|_| "invalid --video-port")?;
                video_port = Some(p);
            }
            "--checkerboard" => checkerboard = true,
            other if other.starts_with('-') => return Err(format!("unknown option {other}")),
            _ => {
                if host.is_some() {
                    return Err("unexpected extra argument".into());
                }
                host = Some(args[i].clone());
            }
        }
        i += 1;
    }

    let host = host.ok_or("missing Mac hostname or IP address")?;
    crate::connections::Connection::manual(
        &host,
        &control_port.to_string(),
        &video_port.map(|p| p.to_string()).unwrap_or_default(),
    )?;
    Ok(Args {
        host,
        control_port,
        video_port,
        checkerboard,
    })
}

fn print_usage() {
    println!(
        "transom-client run — manage Mac windows as native Windows proxy windows\n\
         \n\
         USAGE:\n    \
         transom-client run [<host>] [options]\n\
         \n\
         OPTIONS:\n    \
         --interactive        open the connection window (also used when host is omitted)\n    \
         --control-port <n>   control channel port (default 47100)\n    \
         --video              open the video channel on the default port (47101) [on by default]\n    \
         --no-video           control-plane only; every window shows the placeholder\n    \
         --video-port <n>     open the video channel on <n>\n    \
         --checkerboard       draw a 1px checkerboard test pattern in each window (M0 probe)\n\
         \n\
         EXAMPLES:\n    \
         transom-client run                         # open the connection window\n    \
         transom-client run 192.168.1.20             # connect directly\n    \
         transom-client run 192.168.1.20 --no-video"
    );
}
