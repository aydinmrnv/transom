# AGENTS.md: transom

Two halves, one repo.

| Path | What | Read |
|---|---|---|
| `host/` | macOS host. Swift, SwiftPM. Captures pixels, obeys geometry. | [`host/AGENTS.md`](host/AGENTS.md) |
| `client/` | Windows client. Rust, windows-rs. **The real window manager.** | [`client/AGENTS.md`](client/AGENTS.md) |
| `docs/` | **Shared and canonical.** Binding for both. | below |

## Read first, whichever half you are on

1. [`docs/invariants.md`](docs/invariants.md) — **binding rules.** Not suggestions.
2. [`docs/architecture.md`](docs/architecture.md) — the design and why.
3. [`docs/protocol.md`](docs/protocol.md) — **the contract.** Real, implemented, not a draft.
4. Then your half's `AGENTS.md`.

## Why this repo is merged

It was two repos until the wire protocol became real. Then it stopped making sense: a protocol change has to touch `host/Sources/TransomKit/WireProtocol.swift`, `docs/protocol.md`, and the client's parser **in one atomic commit**, or the two halves drift.

They did drift. Every wall the client hit on its first real connection (undocumented ports, an undocumented `hello`, a framing scheme the doc hedged on) was a documentation gap that a shared `docs/` would have caught.

## The discipline that used to be free

When these were separate repos, neither agent *could* see the other half, so coding against the contract rather than the implementation was enforced by physics.

It isn't anymore. So:

> **Read the other half to diagnose. Code to `docs/protocol.md`.**

If you find yourself matching a Swift implementation detail from Rust, or vice versa, stop. That is coupling, and it breaks the next time the other half refactors.

**If the host's behaviour and `docs/protocol.md` disagree, the host wins** — but the fix is to update the doc **in the same commit**, not to code around it silently.

## Scope

Touch one half per PR where you can. If a change genuinely spans both (a protocol change usually does), say so in the PR and update `docs/protocol.md` alongside.

CI is path-filtered: `host/**` runs the macOS job, `client/**` runs the Windows job.

## Verification (`docs/invariants.md` I-7)

Unchanged and it still matters most:

- **CI cannot verify the host.** A `macos-latest` runner has no Screen Recording grant and no virtual display. It proves the Swift compiles, nothing more.
- **CI cannot verify the client's 1:1 guarantee.** Whether physical client rect equals swapchain size at 150% scaling is only answerable on the real Windows box with real scaled monitors.

Show real output from the real machine, or say plainly that you could not.
