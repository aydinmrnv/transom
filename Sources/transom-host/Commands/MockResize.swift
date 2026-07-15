import ArgumentParser
import Foundation
import TransomKit

/// `mockresize <host> <port>` — a host-side **mock client** that drives the
/// geometry roundtrip (issue #6 Phase 4) end to end, so Phase 4 can be verified
/// without the real Rust/Windows client, exactly as #5 verified the wire.
///
/// It connects to a running `serve` control channel, reads the resync to learn a
/// window id and its current size, then drives a resize drag:
/// `begin` → a burst of `live` at `--rate` Hz interpolating toward the target size
/// → `end`. It counts what it sent against the `windowMoved` replies it gets back,
/// which is the visible half of the throttle: the client fires resizes far faster
/// than AX can keep up, and the host applies ~10Hz of them (architecture.md 2.1).
///
/// The authoritative in/out ratio is printed by `serve` itself
/// (`resize: N request(s) in, M AX write(s) out`); this side shows the request
/// rate and the final requested-vs-actual snap (the clamp, I-4/OQ-2).
struct MockResize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mockresize",
        abstract:
            "Mock client: drive a Live/End resize drag against `serve` and measure throttling.")

    @Argument(help: "Host running `serve` (e.g. 127.0.0.1).")
    var host: String

    @Argument(help: "Control channel port.")
    var port: UInt16 = 7000

    @Option(name: .long, help: "Window id to resize (default: the first window in the resync).")
    var id: UInt64?

    @Option(name: .long, help: "Target width in physical pixels to drag toward.")
    var toW: UInt32 = 320

    @Option(name: .long, help: "Target height in physical pixels to drag toward.")
    var toH: UInt32 = 240

    @Option(name: .long, help: "Client resize request rate (RequestResize/sec).")
    var rate: Double = 60

    @Option(name: .long, help: "Seconds of live dragging before release.")
    var duration: Double = 2.0

    func run() async throws {
        let transport = try await TCPTransport.connect(host: host, port: port)
        print("mockresize: connected to \(host):\(port)")

        // Read the resync (hello + windowCreated* + tileLayout) to pick a window.
        var windows: [(id: UInt64, rect: WireRect)] = []
        var vds: WireSize?
        resync: while let frame = try await transport.receiveFrame() {
            switch try WireCodec.decodeControl(frame) {
            case let .hello(_, vdsSize):
                vds = vdsSize
            case let .windowCreated(id, rect, _, _):
                windows.append((id, rect))
            case .tileLayout:
                break resync
            default:
                continue
            }
        }
        guard let vds else { throw ProbeError("no hello received; is `serve` running?") }
        print("  vds: \(vds.w)x\(vds.h) px, \(windows.count) window(s) in resync")

        let target: (id: UInt64, rect: WireRect)
        if let wid = id {
            guard let match = windows.first(where: { $0.id == wid }) else {
                throw ProbeError("no window with id \(wid) in the resync")
            }
            target = match
        } else {
            guard let first = windows.first else {
                throw ProbeError("the app has no windows to resize")
            }
            target = first
        }
        let start = target.rect
        print(
            "  resizing window id=\(target.id): from \(start.w)x\(start.h) px "
                + "toward \(toW)x\(toH) px, \(rate)Hz for \(duration)s")

        // Count windowMoved replies (the host's readback of each applied AX write)
        // while we drive the drag. A programmatic AX resize also makes the host's
        // AXObserver fire, so replies can arrive ~2x per write — the definitive
        // count is `serve`'s own "AX write(s) out" line.
        let moves = MoveCounter()
        let reader = Task {
            while let frame = try? await transport.receiveFrame() {
                if case let .windowMoved(mid, rect)? = try? WireCodec.decodeControl(frame),
                    mid == target.id
                {
                    await moves.record(rect)
                }
            }
        }

        let t0 = DispatchTime.now()
        func send(_ size: WireSize, _ phase: ResizePhase) async throws {
            try await transport.send(
                try WireCodec.encode(.requestResize(id: target.id, size: size, phase: phase)))
        }

        try await send(WireSize(w: start.w, h: start.h), .begin)
        var liveCount = 0
        let stepNanos = UInt64(1_000_000_000 / max(1, rate))
        let total = Int((duration * rate).rounded())
        for step in 1...max(1, total) {
            let f = Double(step) / Double(max(1, total))
            let w = UInt32((Double(start.w) + (Double(toW) - Double(start.w)) * f).rounded())
            let h = UInt32((Double(start.h) + (Double(toH) - Double(start.h)) * f).rounded())
            try await send(WireSize(w: w, h: h), .live)
            liveCount += 1
            try await Task.sleep(nanoseconds: stepNanos)
        }
        // The authoritative 1:1 snap. Never skipped.
        try await send(WireSize(w: toW, h: toH), .end)
        let sendElapsed = elapsed(since: t0)

        // Let trailing windowMoved (incl. the end readback) arrive, then stop.
        try await Task.sleep(nanoseconds: 400_000_000)
        reader.cancel()
        await transport.close()

        let received = await moves.count
        let last = await moves.last
        print(String(repeating: "-", count: 64))
        print(
            "  sent: 1 begin + \(liveCount) live + 1 end  "
                + "(\(String(format: "%.1f", Double(liveCount) / sendElapsed)) live/s in over \(String(format: "%.2f", sendElapsed))s)"
        )
        print(
            "  windowMoved received: \(received)  "
                + "(includes AXObserver echo; see serve's \"AX write(s) out\" for the applied count)"
        )
        if let last {
            let dw = Int(last.w) - Int(toW)
            let dh = Int(last.h) - Int(toH)
            let exact = dw == 0 && dh == 0
            print(
                "  end snap: requested \(toW)x\(toH) px, actual \(last.w)x\(last.h) px  "
                    + (exact
                        ? "[exact]"
                        : "[CLAMPED Δ \(dw)x\(dh) — app minimum or non-overlap, reported per I-4]"))
        }
    }

    private func elapsed(since t0: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000_000
    }
}

/// Thread-safe tally of the `windowMoved` replies the mock client sees.
private actor MoveCounter {
    private(set) var count = 0
    private(set) var last: WireRect?
    func record(_ rect: WireRect) {
        count += 1
        last = rect
    }
}
