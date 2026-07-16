//! Embeds the Win32 application manifest into the executable.
//!
//! Per-Monitor-V2 DPI awareness MUST be declared in the manifest, not merely set
//! at runtime with `SetProcessDpiAwarenessContext`: the manifest route is the
//! only one that is correct *before the first window is created*. A runtime call
//! happens too late to affect anything the process did during startup.

fn main() {
    // Only meaningful on Windows targets; skip cleanly elsewhere so the crate at
    // least parses/checks on other hosts.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        embed_resource::compile("transom-client.rc", embed_resource::NONE);
    }

    println!("cargo:rerun-if-changed=transom-client.rc");
    println!("cargo:rerun-if-changed=transom-client.exe.manifest");
}
