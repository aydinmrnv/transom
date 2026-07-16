import ArgumentParser
import CoreGraphics
import CoreMedia
import Foundation
import TransomKit
import os

/// `encode <display>` — Phase 2 of issue #3: capture the whole virtual display
/// with one SCK stream at its exact pixel size, feed the IOSurface buffers
/// zero-copy into VideoToolbox, hardware-encode HEVC (chroma per `--chroma`,
/// default 4:2:0 8-bit), and report the measured frame rate and bitrate.
///
/// This is the capture→encode half of the pipeline with no network yet. The two
/// load-bearing checks: SCK must deliver the display's **exact** native pixels
/// (else it is scaling and I-1 is violated), and the encoder must run in
/// **hardware** (Phase 0). Both are asserted and printed.
struct Encode: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "encode",
        abstract:
            "Capture a display and hardware-encode it to HEVC (--chroma 420|444); report fps + bitrate.")

    @Argument(help: "Display id, as printed by `displays`.")
    var display: UInt32

    @Option(name: .long, help: "How long to capture and encode, in seconds.")
    var seconds: Double = 5

    @Option(name: .long, help: "Target average bitrate in Mbps.")
    var bitrate: Int = 40

    @Option(name: .long, help: "Target capture/encode frame rate.")
    var fps: Int = 60

    @Option(
        name: .long,
        help: "Video chroma: 420 (HEVC Main 4:2:0 8-bit, in-box decodable — default) or 444 (4:4:4 10-bit)."
    )
    var chroma: String = "420"

    @Option(
        name: .long,
        help:
            "Write the encoded elementary stream to this path as Annex-B (.h265) — the exact bytes the wire carries, so a reference decoder (ffprobe/ffmpeg) can confirm they decode."
    )
    var dump: String?

    /// Locked, `Sendable` accumulator for the encode stats. The encoder's output
    /// handler fires on a VideoToolbox thread, so this must be thread-safe;
    /// `OSAllocatedUnfairLock` gives that without an `@unchecked` escape hatch.
    private struct Totals {
        var frames = 0
        var bytes = 0
        var keyframes = 0
        var firstError: String?
        /// The Annex-B elementary stream, accumulated only when `--dump` is set.
        var annexB = Data()
        var wroteParameterSets = false
    }

    func run() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw ProbeError(
                "Screen Recording is not granted. Run `transom-host doctor` for guidance.")
        }
        guard let disp = TransomKit.Displays.byID(display) else {
            throw ProbeError("no active display with id \(display). See `displays`.")
        }
        guard let format = HEVCEncoder.Format(cliToken: chroma) else {
            throw ProbeError("unknown --chroma \"\(chroma)\"; expected 420 or 444.")
        }

        print(
            "encode: display \(display), native \(disp.pixelWidth)x\(disp.pixelHeight) px, "
                + "target \(fps)fps @ \(bitrate)Mbps HEVC \(format.chromaTag)")
        print(String(repeating: "-", count: 72))

        // Build the encoder. Hardware is REQUIRED, so this throws loudly if the
        // hardware path is somehow unavailable rather than falling to software
        // (Phase 0 proved 4:4:4 hardware is available on this Mac; 4:2:0 is easier).
        let config = HEVCEncoder.Config(
            width: disp.pixelWidth, height: disp.pixelHeight, fps: fps,
            bitrateBitsPerSecond: bitrate * 1_000_000, maxKeyFrameInterval: fps * 2,
            format: format)
        let encoder: HEVCEncoder
        do {
            encoder = try HEVCEncoder(config: config)
        } catch {
            throw ProbeError("encoder init failed: \(error)")
        }
        print("  encoder usingHardware: \(encoder.usingHardware)")

        // With --dump we need the compressed bytes, not just their sizes.
        let dumping = dump != nil
        if dumping { encoder.extractFrameData = true }

        let totals = OSAllocatedUnfairLock(initialState: Totals())
        encoder.onEncodedFrame = { frame in
            totals.withLock {
                $0.frames += 1
                $0.bytes += frame.byteCount
                if frame.isKeyframe { $0.keyframes += 1 }
                if dumping {
                    // Prepend the parameter sets (hvcC → Annex-B) once, before any
                    // frame, exactly as VideoServer sends `config` first on the wire.
                    if !$0.wroteParameterSets, let hvcc = encoder.parameterSetsHVCC {
                        $0.annexB.append(annexBFromHVCC(hvcc))
                        $0.wroteParameterSets = true
                    }
                    $0.annexB.append(annexBFromLengthPrefixed(frame.data))
                }
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

        if let path = dump {
            let url = URL(fileURLWithPath: path)
            do {
                try snap.annexB.write(to: url)
                print(String(repeating: "-", count: 72))
                print("  dumped \(snap.annexB.count) B of Annex-B HEVC to \(path)")
                print("  verify it decodes:  ffprobe -v error -show_streams \(path)")
            } catch {
                print("  dump failed: \(error)")
            }
        }

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

// MARK: - Annex-B conversion (diagnostic dump only)

private let annexBStartCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

/// Extract the VPS/SPS/PPS NAL units from an `hvcC` configuration record and emit
/// them as Annex-B (each prefixed with a 4-byte start code). This is the same set
/// the video server sends as the first `config` message; a decoder needs them
/// before any frame. Returns empty on a malformed record rather than throwing —
/// this is a best-effort diagnostic dump.
private func annexBFromHVCC(_ hvcc: Data) -> Data {
    let b = [UInt8](hvcc)
    // Fixed 22-byte header, then numOfArrays at byte 22 (ISO/IEC 14496-15 §8.3.3.1).
    guard b.count > 22 else { return Data() }
    var out = Data()
    let numOfArrays = Int(b[22])
    var p = 23
    for _ in 0..<numOfArrays {
        // 1 byte: array_completeness(1) reserved(1) NAL_unit_type(6); skip it.
        guard p + 3 <= b.count else { break }
        p += 1
        let numNalus = Int(b[p]) << 8 | Int(b[p + 1])
        p += 2
        for _ in 0..<numNalus {
            guard p + 2 <= b.count else { return out }
            let len = Int(b[p]) << 8 | Int(b[p + 1])
            p += 2
            guard len > 0, p + len <= b.count else { return out }
            out.append(contentsOf: annexBStartCode)
            out.append(contentsOf: b[p..<p + len])
            p += len
        }
    }
    return out
}

/// Convert one access unit from CoreMedia's length-prefixed form (4-byte
/// big-endian NAL lengths, the `hvc1` convention) into Annex-B start-code NALs.
private func annexBFromLengthPrefixed(_ data: Data) -> Data {
    let b = [UInt8](data)
    var out = Data()
    var p = 0
    while p + 4 <= b.count {
        let len = Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
        p += 4
        guard len > 0, p + len <= b.count else { break }
        out.append(contentsOf: annexBStartCode)
        out.append(contentsOf: b[p..<p + len])
        p += len
    }
    return out
}
