# Contributing to transom-client

**This project is pre-alpha and does not work yet.** It is an attempt at
something that does not currently exist (seamless single-window streaming from a
Mac host), built on an unproven design. Expect churn.

## Start with the architecture doc

Before anything else, read the canonical design doc. It lives in the host repo
and is the source of truth for *both* the [macOS
host](https://github.com/aydinmrnv/transom-host) and this Windows client:

**<https://github.com/aydinmrnv/transom-host/blob/main/docs/architecture.md>**

It explains why the design is what it is — the sprite-sheet virtual display,
geometry mirroring, the no-resampling rule, and the live-resize compromise. If
code disagrees with that document, the code is wrong (or the document must be
updated first, deliberately).

## Ground rules

- **Dependencies:** the only runtime dependency is `windows` (windows-rs), plus
  `embed-resource` at build time for the manifest. **Ask before adding any
  other.**
- **DPI awareness stays in the manifest.** Per-Monitor V2 must be declared at load
  time via `transom-client.exe.manifest`, not with a runtime call. Don't "simplify"
  it into `SetProcessDpiAwarenessContext`.
- **CI must stay green**, and CI actually compiles the client (`cargo build`) —
  it is not just a formatting check. Also required: `cargo clippy --all-targets
  -- -D warnings` and `cargo fmt --all -- --check`.

## Building

```sh
cargo build
cargo run -- doctor
```

Windows 10 1607+ with the MSVC toolchain and stable Rust.
