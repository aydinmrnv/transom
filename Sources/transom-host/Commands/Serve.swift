import ArgumentParser
import Foundation
import TransomKit

/// `serve <app> <display>` — Phase 3 of issue #3: the wire.
///
/// Tiles the app's windows, watches them via AX, and serves the control channel
/// (window lifecycle + geometry, in VDS physical pixels) to a client that
/// connects by IP. With `--video`, it also captures + HEVC-encodes the display
/// and streams it on a second connection.
///
/// The whole pipeline lives in `TransomKit.HostSession`; this command is a thin
/// CLI driver over it, and the SwiftUI host app (issue #8) is another. There is
/// **no auth and no encryption** (see the README security note), so `HostSession`
/// refuses to bind to anything but a private address.
struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Tile + watch an app and serve its window rects (and optionally video) over TCP.")

    @Argument(help: "Target app: a name like \"Xcode\" or a bundle id.")
    var app: String

    @Argument(help: "Display id, as printed by `displays`.")
    var display: UInt32

    @Option(
        name: .long,
        help: "Private address to bind (default localhost). Use the LAN IP for a real client.")
    var host: String = "127.0.0.1"

    @Option(name: .long, help: "Control channel TCP port.")
    var controlPort: UInt16 = 7000

    @Option(name: .long, help: "Video channel TCP port.")
    var videoPort: UInt16 = 7001

    @Option(name: .long, help: "Gutter in VDS pixels between tiles.")
    var gutter: Int = Tiler.defaultGutter

    @Flag(inversion: .prefixedNo, help: "Tile the app's windows at startup (I-5).")
    var tile: Bool = true

    @Flag(name: .long, help: "Also capture + HEVC-encode and stream video on the 2nd connection.")
    var video: Bool = false

    @Option(name: .long, help: "Video target bitrate in Mbps.")
    var bitrate: Int = 40

    @Option(name: .long, help: "Video target frame rate.")
    var fps: Int = 60

    @Option(name: .long, help: "Auto-stop after N seconds (default: run until Ctrl-C).")
    var seconds: Double?

    @Flag(
        name: .long,
        help:
            "Map Windows modifiers namesake (Ctrl→Control) instead of the default swap (Ctrl→Command)."
    )
    var namesakeModifiers: Bool = false

    @Flag(name: .long, help: "Print the full translation chain for every injected input event.")
    var logInput: Bool = false

    func run() async throws {
        // Stream output live: stdout is block-buffered to a pipe/file, so without
        // this the status lines never appear while the long-running server runs.
        setvbuf(stdout, nil, _IONBF, 0)

        let target: TargetApp
        switch AppResolver.resolve(app) {
        case .success(let t): target = t
        case .failure(let e): throw e
        }
        guard let disp = TransomKit.Displays.byID(display) else {
            throw ProbeError("no active display with id \(display). See `displays`.")
        }

        let config = HostConfig(
            target: target, display: disp, host: host, controlPort: controlPort,
            videoPort: videoPort, gutter: gutter, tile: tile, video: video,
            bitrateMbps: bitrate, fps: fps, namesakeModifiers: namesakeModifiers, logInput: logInput
        )
        let session = HostSession(config: config)

        print(
            "serve: \(target.name) on display \(display) (\(disp.pixelWidth)x\(disp.pixelHeight) px)"
        )
        print(
            "  control: \(host):\(controlPort)   video: \(video ? "\(host):\(videoPort)" : "off")")

        // start() throws on a missing grant or a public bind before anything binds.
        try await session.start()

        // Report the startup tiling result (requested-vs-actual deltas, I-4/OQ-2).
        let started = session.status()
        if let tileError = started.tileError {
            print("  tiling failed: \(tileError)")
        } else if started.tilePlacements.isEmpty {
            print("  tiled 0 window(s)")
        } else {
            print("  tiled \(started.tilePlacements.count) window(s), gutter=\(gutter)px:")
            for p in started.tilePlacements { printPlacement(p) }
        }
        if video {
            print("  video: hardware=\(started.usingHardware), streaming HEVC 4:4:4 10-bit")
        }
        print(
            "  ready. waiting for a client to connect\(seconds.map { " (auto-stop in \($0)s)" } ?? " (Ctrl-C to stop)")."
        )

        if let seconds {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await session.stop()
            print("serve: stopped.")
        } else {
            // Run until the process is interrupted. Print a live status line each
            // second so fps/bitrate/encoder mode/clients are visible without a UI.
            while true {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                printStatusLine(session.status())
            }
        }
    }

    private func printStatusLine(_ s: HostStatus) {
        guard s.videoEnabled else {
            print(
                "  status: control-client=\(s.controlClientConnected ? "yes" : "no")  "
                    + "windows=\(s.liveWindowCount)")
            return
        }
        let mode = s.encoderIs444Hardware ? "4:4:4 10-bit HW" : "FALLBACK (not 4:4:4 HW)"
        print(
            String(
                format:
                    "  status: clients ctrl=%@ video=%@  %.0ffps  %.1fMbps  enc-lat %.1fms  [%@]",
                s.controlClientConnected ? "yes" : "no",
                s.videoClientConnected ? "yes" : "no",
                s.measuredFPS, s.measuredBitrateMbps, s.encodeLatencyMillis, mode))
    }

    private func printPlacement(_ p: TilePlacement) {
        let req = "(\(p.requested.x),\(p.requested.y)) \(p.requested.width)x\(p.requested.height)"
        guard let a = p.actual, let pd = p.positionDelta, let sd = p.sizeDelta else {
            print("    window[\(p.index)] \"\(p.title)\"  requested \(req)  actual (AX refused)")
            return
        }
        let act = "(\(a.x),\(a.y)) \(a.width)x\(a.height)"
        let delta =
            p.isExact ? "[exact]" : "[Δ pos (\(pd.dx),\(pd.dy))  Δ size (\(sd.dw),\(sd.dh))]"
        print("    window[\(p.index)] \"\(p.title)\"  requested \(req)  actual \(act)  \(delta)")
    }
}
