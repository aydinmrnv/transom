# Contributing to Transom

**This project is early access and hardware-dependent.** The host and Windows
client now run end to end on the intended Mac/Windows pair, but capture,
encoding, permissions, and DPI behavior still need to be verified on the target
machines. Expect churn.

## Start with the architecture doc

Before anything else, read **[`docs/architecture.md`](docs/architecture.md)**. It
is canonical for *both* the host and the Windows client in [`client/`](client/),
and it explains why the
design is what it is (the sprite-sheet virtual display, geometry mirroring, the
no-resampling rule, the live-resize compromise). If code disagrees with that
document, the code is wrong — or the document needs updating first, deliberately.

## Ground rules

- **Dependencies:** the only dependency is `swift-argument-parser`. **Ask before
  adding any other.**
- **Swift 6, strict concurrency.** The package builds in Swift 6 language mode.
  Keep it warning-clean.
- **Formatting:** `swift format lint --recursive Sources Package.swift` must pass
  (CI runs it). Run `swift format --in-place --recursive Sources` to fix.
- **The open questions in the architecture doc are real.** If you're here to help,
  the highest-value work right now is the `probe` experiments that de-risk them.

## Building

```sh
swift build
swift run transom-host doctor
```

macOS 14+ and a Swift 6 toolchain (Xcode 16 or equivalent).
