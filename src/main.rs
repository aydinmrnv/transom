//! transom-client — Windows client for the Transom seamless remote windowing
//! system.
//!
//! The client is the real window manager: it will crop per-window sub-rectangles
//! out of a single shared texture streamed from the Mac host and draw each as its
//! own native Windows window. None of that exists yet. Today the only command is
//! `doctor`, a console-only health check.
//!
//! See the canonical design doc in the host repo:
//! <https://github.com/aydinmrnv/transom-host/blob/main/docs/architecture.md>

mod doctor;

use std::process::ExitCode;

fn main() -> ExitCode {
    // Deliberately hand-rolled arg handling: `windows` is the only dependency, so
    // no clap. There is exactly one real command for now.
    let arg = std::env::args().nth(1);
    match arg.as_deref() {
        Some("doctor") => doctor::run(),
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

fn print_usage() {
    println!(
        "transom-client {} — Windows client for the Transom remote windowing system\n\
         \n\
         USAGE:\n    \
         transom-client <command>\n\
         \n\
         COMMANDS:\n    \
         doctor      Check D3D11, monitors, and DPI awareness, then exit\n    \
         help        Show this message\n    \
         --version   Print version\n\
         \n\
         This is a pre-alpha prototype and does not work yet. See:\n    \
         https://github.com/aydinmrnv/transom-host/blob/main/docs/architecture.md",
        env!("CARGO_PKG_VERSION")
    );
}
