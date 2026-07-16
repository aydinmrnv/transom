//! transom-client — Windows client for the Transom seamless remote windowing
//! system.
//!
//! The client is the real window manager: it crops per-window sub-rectangles out
//! of a single shared texture streamed from the Mac host and draws each as its own
//! native Windows window (protocol.md, architecture.md).
//!
//! ## Shape of this crate
//!
//! The code is split by verifiability, not just by concern:
//!
//!  * **Pure protocol core** (`wire`, `model`, `net`, `session`, `runner`, `vk`) —
//!    no `windows-rs`, compiles and unit-tests on *any* host. This is the half
//!    that must agree with the Swift host byte-for-byte, so it is kept portable
//!    and pointed at the real host on `127.0.0.1` to verify the wire (I-7).
//!  * **Windows window manager** (`win`, `doctor`) — `#[cfg(windows)]`,
//!    Per-Monitor-V2 DPI, a `DXGI_SCALING_NONE` flip swapchain, a point-sampled
//!    1:1 blit, and the resize roundtrip. This is where the 1:1 guarantee is held.
//!
//! ## Commands
//!
//!  * `connect <host>` — headless: drive the wire, print the protocol, send test
//!    input/resize. Runs everywhere. The integration test for the protocol.
//!  * `run <host>` — the real window manager (Windows only).
//!  * `doctor` — D3D11 / DPI / monitor health check (Windows only).

mod model;
mod net;
mod runner;
mod session;
mod vk;
mod wire;

#[cfg(windows)]
mod doctor;
#[cfg(windows)]
mod win;

use std::process::ExitCode;

fn main() -> ExitCode {
    // Hand-rolled arg handling: no clap (invariants I-8, keep the dependency
    // budget at `windows` + the manifest embedder).
    let args: Vec<String> = std::env::args().skip(1).collect();
    let command = args.first().map(String::as_str);

    match command {
        Some("doctor") => run_doctor(),
        Some("connect") => runner::run(&args[1..]),
        Some("run") => run_gui(&args[1..]),
        Some("-h") | Some("--help") | Some("help") | None => {
            print_usage();
            ExitCode::SUCCESS
        }
        Some("--version") | Some("-V") => {
            println!("transom-client {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        Some(other) => {
            eprintln!("transom-client: unknown command '{other}'\n");
            print_usage();
            ExitCode::FAILURE
        }
    }
}

#[cfg(windows)]
fn run_doctor() -> ExitCode {
    doctor::run()
}

#[cfg(not(windows))]
fn run_doctor() -> ExitCode {
    eprintln!(
        "doctor checks D3D11, DPI awareness, and monitors — it only runs on Windows.\n\
         On this host, use `connect` to exercise the wire protocol against a running host."
    );
    ExitCode::FAILURE
}

#[cfg(windows)]
fn run_gui(args: &[String]) -> ExitCode {
    win::run(args)
}

#[cfg(not(windows))]
fn run_gui(_args: &[String]) -> ExitCode {
    eprintln!(
        "`run` is the native Windows window manager (D3D11 + Win32) and only runs on Windows.\n\
         On this host, use `connect <host>` to drive and verify the wire protocol."
    );
    ExitCode::FAILURE
}

fn print_usage() {
    println!(
        "transom-client {} — Windows client for the Transom remote windowing system\n\
         \n\
         USAGE:\n    \
         transom-client <command> [args]\n\
         \n\
         COMMANDS:\n    \
         run <host>       Connect and manage proxy windows (Windows only)\n    \
         connect <host>   Headless: drive the wire protocol, print events, send test input\n    \
         doctor           Check D3D11, monitors, and DPI awareness, then exit (Windows only)\n    \
         help             Show this message\n    \
         --version        Print version\n\
         \n\
         Run `transom-client connect` with no host for its own options.\n\
         The host is `transom-host serve` on the Mac; connect by IP (no discovery).",
        env!("CARGO_PKG_VERSION")
    );
}
