import ArgumentParser
import CoreGraphics
import CoreMedia
import Foundation
import TransomKit
import os

/// `encode <display>` — Phase 2 of issue #3: capture the whole virtual display
/// with one SCK stream at its exact pixel size, feed the IOSurface buffers
/// zero-copy into VideoToolbox, encode HEVC 4:4:4 10-bit in hardware, and report
/// the measured frame rate and bitrate.
///
/// This is the capture→encode half of the pipeline with no network yet. The two
/// load-bearing checks: SCK must deliver the display's **exact** native pixels
/// (else it is scaling and I-1 is violated), and the encoder must run in
/// **hardware** at 4:4:4 (Phase 0). Both are asserted and printed.
struct Encode: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "encode",
        abstract:
            "Capture a display and hardware-encode it to HEVC 4:4:4 10-bit; report fps + bitrate.")

    @Argument(help: "Display id, as printed by `displays`.")
    var display: UInt32

    @Option(name: .long, help: "How long to capture and encode, in seconds.")
    var seconds: Double = 5

    @Option(name: .long, help: "Target average bitrate in Mbps.")
    var bitrate: Int = 40

    @Option(name: .long, help: "Target capture/encode frame rate.")
    var fps: Int = 60

    /// Locked, `Sendable` accumulator for the encode stats. The encoder's output
    /// handler fires on a VideoToolbox thread, so this must be thread-safe;
    /// `OSAllocatedUnfairLock` gives that without an `@unchecked` escape hatch.
    private struct Totals {
        var frames = 0
        var bytes = 0
        var keyframes = 0
        var firstError: String?
    }

    func run() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw ProbeError(
                "Screen Recording is not granted. Run `transom-host doctor` for guidance.")
        }
        guard let disp = TransomKit.Displays.byID(display) else {
            throw ProbeError("no active display with id \(display). See `displays`.")
        }

        print(
            "encode: display \(display), native \(disp.pixelWidth)x\(disp.pixelHeight) px, "
                + "target \(fps)fps @ \(bitrate)Mbps HEVC 4:4:4 10-bit")
        print(String(repeating: "-", count: 72))

        // Build the encoder. Hardware is REQUIRED, so this throws loudly if the
        // 4:4:4 hardware path is somehow unavailable rather than falling to
        // software (Phase 0 proved it is available on this Mac).
        let config = HEVCEncoder.Config(
            width: disp.pixelWidth, height: disp.pixelHeight, fps: fps,
            bitrateBitsPerSecond: bitrate * 1_000_000, maxKeyFrameInterval: fps * 2)
        let encoder: HEVCEncoder
        do {
            encoder = try HEVCEncoder(config: config)
        } catch {
            throw ProbeError("encoder init failed: \(error)")
        }
        print("  encoder usingHardware: \(encoder.usingHardware)")

        let totals = OSAllocatedUnfairLock(initialState: Totals())
        encoder.onEncodedFrame = { frame in
            totals.withLock {
                $0.frames += 1
                $0.bytes += frame.byteCount
                if frame.isKeyframe { $0.keyframes += 1 }
            }
        }

        let capture = DisplayCapture(display: disp, fps: fps)
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        capture.onPixelBuffer = { pixelBuffer, pts in
            do {
                try encoder.encode(pixelBuffer, pts: pts, duration: frameDuration)
            } catch {
                totals.withLock { if $0.firstError == nil { $0.firstError = "\(error)" } }
                Log.encode.error(
                    "encode frame failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        try await capture.start()
        let startNanos = DispatchTime.now().uptimeNanoseconds
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await capture.stop()
        // Flush any frames still in the encoder before reading the totals.
        encoder.finish()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startNanos) / 1_000_000_000

        let stats = capture.stats
        let snap = totals.withLock { $0 }

        report(disp: disp, stats: stats, encoder: encoder, totals: snap, elapsed: elapsed)

        if snap.frames == 0 {
            throw ProbeError("no frames were encoded — see the errors above.")
        }
    }

    private func report(
        disp: DisplayInfo, stats: DisplayCapture.FrameStats?, encoder: HEVCEncoder,
        totals: Totals, elapsed: Double
    ) {
        // I-1: SCK must deliver the exact native pixel size, no scaling.
        if let s = stats {
            print(
                "  SCK configured : \(s.configuredWidth)x\(s.configuredHeight) px (\(s.pixelFormatString))"
            )
            print("  SCK delivered  : \(s.deliveredWidth)x\(s.deliveredHeight) px")
            print(
                "  I-1 CHECK      : "
                    + (s.matchesNativePixels
                        ? "PASS — SCK delivered exact native pixels, no scaling."
                        : "FAIL — delivered != native; SCK is scaling, I-1 violated."))
        } else {
            print("  SCK delivered  : (no frame stats — did any frame arrive?)")
        }
        print(String(repeating: "-", count: 72))

        let measuredFPS = elapsed > 0 ? Double(totals.frames) / elapsed : 0
        let measuredMbps = elapsed > 0 ? Double(totals.bytes) * 8 / elapsed / 1_000_000 : 0
        let avgFrameBytes = totals.frames > 0 ? totals.bytes / totals.frames : 0

        print("  frames encoded : \(totals.frames) over \(fmt(elapsed))s")
        print("  measured fps   : \(fmt(measuredFPS))")
        print("  measured bitrate: \(fmt(measuredMbps)) Mbps")
        print("  keyframes      : \(totals.keyframes)")
        print("  avg frame size : \(avgFrameBytes) B")
        print("  encoder HW     : \(encoder.usingHardware)")
        print("  output format  : \(encoder.outputFormatSummary)")
        if let err = totals.firstError {
            print("  first error    : \(err)")
        }

        Log.encode.notice(
            "encode display=\(self.display, privacy: .public) frames=\(totals.frames, privacy: .public) fps=\(measuredFPS, privacy: .public) mbps=\(measuredMbps, privacy: .public) hw=\(encoder.usingHardware, privacy: .public)"
        )
    }

    private func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
}
