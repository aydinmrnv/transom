import ArgumentParser
import Foundation
import TransomKit

/// `encodeprobe` — Phase 0 of issue #3 (OQ-4): does the M1 Max media engine
/// hardware-encode HEVC 4:4:4?
///
/// Prints the advertised encoder list, then runs a real test encode per chroma
/// mode under both hardware-required and software-allowed configs, and states a
/// verdict. This is a diagnostic; it writes no files and touches no display, so
/// it needs no permissions and is safe to run anywhere — but the answer is only
/// meaningful on the target Mac, so run it there (I-7).
struct EncodeProbe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "encodeprobe",
        abstract: "Probe HEVC 4:4:4 hardware-encode support (issue #3 phase 0, OQ-4).")

    @Option(name: .long, help: "Test-encode frame width in pixels.")
    var width: Int = 1280

    @Option(name: .long, help: "Test-encode frame height in pixels.")
    var height: Int = 720

    func run() throws {
        print("encodeprobe: HEVC chroma / hardware-encode probe (OQ-4)")
        print("  test frame: \(width)x\(height)")
        print(String(repeating: "=", count: 72))

        // 1. Advertised HEVC encoders.
        print("VTCopyVideoEncoderList — HEVC encoders:")
        let encoders = EncoderProbe.hevcEncoders()
        if encoders.isEmpty {
            print("  (none reported)")
        } else {
            for e in encoders {
                let tag = e.isHardware ? "hardware" : "software"
                print("  - \(e.displayName)  [\(tag)]  id=\(e.encoderID)")
            }
        }
        if let id = EncoderProbe.supportedHardwareEncoderID(
            width: Int32(width), height: Int32(height))
        {
            print("  VTCopySupportedPropertyDictionaryForEncoder (require HW): \(id)")
        } else {
            print("  VTCopySupportedPropertyDictionaryForEncoder (require HW): none")
        }
        print(String(repeating: "-", count: 72))

        // 2. The real test encodes.
        print("Test encode per chroma mode (require-HW vs allow-SW):")
        let results = EncoderProbe.probeAllModes(width: width, height: height)
        for r in results {
            print("")
            print(
                "  \(r.label)   source=\(r.sourceFormatString)\(r.profile.map { "  profile=\($0)" } ?? "")"
            )
            print("    require HW : \(describe(r.requireHardware))")
            print("    allow  SW  : \(describe(r.allowSoftware))")
            print("    VERDICT    : \(r.verdict.rawValue)")
        }
        print(String(repeating: "=", count: 72))

        // 3. The OQ-4 answer, stated plainly.
        guard let fourFourFour = results.first(where: { $0.label.contains("4:4:4") }) else {
            print("OQ-4: no 4:4:4 mode was probed — this is a bug in the probe.")
            throw ExitCode.failure
        }
        // Prefer the 8-bit 4:4:4 result for the headline; report either that
        // encoded in hardware as a win.
        let anyFourFourFourHW =
            results
            .filter { $0.label.contains("4:4:4") }
            .contains { $0.verdict == .hardware }
        let anyFourFourFourSW =
            results
            .filter { $0.label.contains("4:4:4") }
            .contains { $0.verdict == .softwareOnly || $0.verdict == .hardware }

        print("OQ-4 ANSWER:")
        if anyFourFourFourHW {
            print(
                "  HEVC 4:4:4 encodes in HARDWARE on this Mac. Use it (issue: 4:4:4 if HW allows).")
        } else if anyFourFourFourSW {
            print("  ⚠️  HEVC 4:4:4 is SOFTWARE-ONLY on this Mac — too slow for a live stream.")
            print(
                "  ⚠️  Fall back to 4:2:0 (or 4:2:2 if it is hardware) and log a loud startup warning."
            )
            print(
                "  ⚠️  4:2:0 fringes syntax-highlighted text — this is the failure the project exists to avoid."
            )
        } else {
            print(
                "  ⚠️  HEVC 4:4:4 is UNAVAILABLE on this Mac (\(fourFourFour.requireHardware.status))."
            )
            print(
                "  ⚠️  Fall back to 4:2:0 (or 4:2:2 if it is hardware) and log a loud startup warning."
            )
        }

        // A quick note on the hardware fallbacks, since the decision needs them.
        let hwModes = results.filter { $0.verdict == .hardware }.map(\.label)
        print(
            "  Hardware-capable modes on this Mac: "
                + (hwModes.isEmpty ? "(none)" : hwModes.joined(separator: ", ")))
    }

    private func describe(_ a: EncoderProbe.Attempt) -> String {
        var parts: [String] = []
        parts.append(a.sessionCreated ? "session:ok" : "session:FAIL")
        parts.append(a.frameEncoded ? "encoded:yes(\(a.outputBytes)B)" : "encoded:no")
        if let hw = a.usingHardware {
            parts.append("usingHW:\(hw)")
        }
        if a.status != 0 {
            parts.append("status:\(a.status)")
        }
        parts.append("(\(a.detail))")
        return parts.joined(separator: "  ")
    }
}
