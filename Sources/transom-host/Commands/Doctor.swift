import ApplicationServices
import ArgumentParser
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// `doctor` — check that the machine can host a Transom capture session.
///
/// Reports Screen Recording and Accessibility permission state, enumerates the
/// attached displays, and confirms ScreenCaptureKit can actually see them. It
/// deliberately prints the TCC-attribution caveat at the end, because a CLI run
/// from a terminal inherits the *terminal app's* privacy grants, not its own —
/// the single most common reason this pipeline appears "broken".
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check permissions, displays, and ScreenCaptureKit readiness."
    )

    @Flag(
        name: [.customLong("prompt")],
        help: "Trigger the system Accessibility permission prompt if not yet trusted."
    )
    var promptForAccessibility = false

    func run() async throws {
        Log.doctor.info("doctor: starting diagnostics")

        print("transom-host doctor")
        print("===================\n")

        var allClear = true

        allClear = checkScreenRecording() && allClear
        allClear = checkAccessibility() && allClear
        reportDisplays()
        allClear = await checkScreenCaptureKit() && allClear

        printPermissionCaveat()

        print("")
        if allClear {
            print("Summary: ready.")
        } else {
            print("Summary: NOT ready — resolve the [FAIL] items above.")
            Log.doctor.error("doctor: one or more checks failed")
            throw ExitCode.failure
        }
    }

    // MARK: - Screen Recording

    private func checkScreenRecording() -> Bool {
        // Preflight does not prompt; it just reports the current grant.
        let granted = CGPreflightScreenCaptureAccess()
        if granted {
            print("[ ok ] Screen Recording: granted")
        } else {
            print("[FAIL] Screen Recording: NOT granted")
            print("       System Settings > Privacy & Security > Screen Recording")
            print("       (see the terminal/TCC note at the bottom)")
        }
        Log.doctor.info("screen recording granted: \(granted, privacy: .public)")
        return granted
    }

    // MARK: - Accessibility

    private func checkAccessibility() -> Bool {
        let trusted: Bool
        if promptForAccessibility {
            // Use the literal key rather than the imported global
            // `kAXTrustedCheckOptionPrompt`: under Swift 6 strict concurrency,
            // referencing that mutable global is an error. Its value is the
            // stable constant string "AXTrustedCheckOptionPrompt".
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(options)
        } else {
            trusted = AXIsProcessTrusted()
        }

        if trusted {
            print("[ ok ] Accessibility: trusted")
        } else {
            print("[FAIL] Accessibility: NOT trusted")
            print("       System Settings > Privacy & Security > Accessibility")
            print("       Needed to move/resize app windows via the AX API.")
            if !promptForAccessibility {
                print("       Re-run with `--prompt` to trigger the system dialog.")
            }
        }
        Log.doctor.info("accessibility trusted: \(trusted, privacy: .public)")
        return trusted
    }

    // MARK: - Displays

    private func reportDisplays() {
        print("\nDisplays:")

        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            print("  (none reported)")
            return
        }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            print("  (failed to enumerate)")
            return
        }

        let mainID = CGMainDisplayID()
        for id in ids {
            let bounds = CGDisplayBounds(id)
            let scale = backingScale(of: id)
            let isMain = (id == mainID)
            let flag = isMain ? " [main]" : ""
            print(
                "  - id=\(id)\(flag) "
                    + "origin=(\(Int(bounds.origin.x)),\(Int(bounds.origin.y))) "
                    + "size=\(Int(bounds.size.width))x\(Int(bounds.size.height)) pt "
                    + "scale=\(String(format: "%.1f", scale))x"
            )
        }
        Log.doctor.info("enumerated \(count, privacy: .public) display(s)")
    }

    /// Backing scale factor derived from the current display mode: the ratio of
    /// backing pixels to points. 2.0 on Retina, 1.0 otherwise.
    private func backingScale(of id: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return 1.0 }
        let points = mode.width
        let pixels = mode.pixelWidth
        guard points > 0 else { return 1.0 }
        return Double(pixels) / Double(points)
    }

    // MARK: - ScreenCaptureKit

    private func checkScreenCaptureKit() async -> Bool {
        do {
            // Fails (throws) when Screen Recording permission is absent — this is
            // the real, end-to-end confirmation that capture will work.
            let content = try await SCShareableContent.current
            print("\n[ ok ] ScreenCaptureKit: usable")
            print(
                "       sees \(content.displays.count) display(s), "
                    + "\(content.windows.count) window(s), "
                    + "\(content.applications.count) application(s)"
            )
            Log.doctor.info("SCK ok: \(content.displays.count, privacy: .public) displays")
            return true
        } catch {
            print("\n[FAIL] ScreenCaptureKit: not usable")
            print("       \(error.localizedDescription)")
            print("       This almost always means Screen Recording permission is missing.")
            Log.doctor.error("SCK failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - The caveat everyone trips over

    private func printPermissionCaveat() {
        print(
            """

            Permissions & the terminal — READ THIS
            --------------------------------------
            macOS attributes TCC (privacy) permissions to the application that
            LAUNCHED this process, not to the transom-host binary itself. When you
            run this from a terminal, the Screen Recording and Accessibility grants
            you need are attributed to your terminal app (Terminal, iTerm2, Ghostty,
            VS Code, …), NOT to "transom-host".

            Consequences:
              - The checkbox you must tick is for your TERMINAL app, not this binary.
              - Running the same binary from a different terminal, or later from a
                bundled .app, is a DIFFERENT TCC identity and will prompt again.
              - After granting, fully quit and relaunch the terminal so already-open
                shells pick up the new permission.

            Grant here:
              System Settings > Privacy & Security > Screen Recording  (add your terminal)
              System Settings > Privacy & Security > Accessibility     (add your terminal)
            """
        )
    }
}
