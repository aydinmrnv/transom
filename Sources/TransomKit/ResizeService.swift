import CoreGraphics
import Foundation

/// Drives the geometry roundtrip (issue #6 Phase 4, protocol.md §5): takes client
/// `RequestResize` messages, throttles `live` to ~10Hz, writes `AXSize`, reads the
/// **actual** geometry back (I-4), and emits `windowMoved` with what macOS really
/// did — clamped or not (OQ-2).
///
/// It is an `actor`, so `handle` (driven from the control receive path) and `tick`
/// (the trailing-flush timer) serialise without a lock, and AX writes never run
/// concurrently with themselves. The pure decision logic lives in `ResizeThrottle`
/// and `ResizeClamp` (both unit tested with no Mac); this type is the thin impure
/// shell that supplies a clock and talks to AX.
///
/// Emitted moves go out through the same ordered `WindowWatcher.WindowEvent`
/// stream the watcher uses, so the client sees one in-order geometry feed. Note
/// that a programmatic `AXSize` write also makes the watcher's `AXObserver` fire
/// `kAXWindowResized`, so the client may receive a second, identical `windowMoved`
/// for the same resize — harmless, since both carry the same actual rect and the
/// client keys on the id.
public actor ResizeService {
    private let registry: WindowRegistry
    private let display: DisplayInfo
    private let gutter: Int
    private let emit: @Sendable (WindowWatcher.WindowEvent) -> Void
    private let now: @Sendable () -> Double
    private var throttle: ResizeThrottle

    /// Counters for the throttle demo (issue #6 verification): how many requests
    /// arrived vs how many actually reached AX. The ratio is the throttle working.
    public private(set) var requestsIn = 0
    public private(set) var axWrites = 0

    public init(
        registry: WindowRegistry,
        display: DisplayInfo,
        gutter: Int,
        interval: Double = 0.1,
        now: @escaping @Sendable () -> Double = ResizeService.monotonicSeconds,
        emit: @escaping @Sendable (WindowWatcher.WindowEvent) -> Void
    ) {
        self.registry = registry
        self.display = display
        self.gutter = gutter
        self.emit = emit
        self.now = now
        self.throttle = ResizeThrottle(interval: interval)
    }

    /// Handle one client `RequestResize`.
    public func handle(id: UInt64, size: WireSize, phase: ResizePhase) {
        requestsIn += 1
        apply(throttle.onRequest(id: id, size: size, phase: phase, now: now()))
        if phase == .end {
            // A drag just ended: surface the running in/out ratio — the throttle.
            Log.general.notice(
                "resize: cumulative in=\(self.requestsIn, privacy: .public) axWrites=\(self.axWrites, privacy: .public)"
            )
        }
    }

    /// Release a trailing coalesced `live` whose throttle window has elapsed. Drive
    /// this from a periodic tick.
    public func tick() {
        apply(throttle.onTick(now: now()))
    }

    private func apply(_ outcome: ResizeThrottle.Outcome) {
        guard case let .write(id, size) = outcome else { return }
        performResize(id: id, size: size)
    }

    /// The impure half: clamp for non-overlap, cross the AX boundary, read back the
    /// actual geometry, and emit it.
    private func performResize(id: UInt64, size: WireSize) {
        guard let element = registry.element(for: id) else {
            Log.ax.notice("resize: unknown window id \(id, privacy: .public), ignoring")
            return
        }

        // Clamp the requested growth so it does not cross into a neighbour (I-5).
        // At N=1 `others` is empty and this is just a display-edge clamp.
        let entries = registry.snapshot()
        let requested = TileSize(width: Int(size.w), height: Int(size.h))
        let target: TileSize
        if let current = entries.first(where: { $0.id == id })?.rect {
            let others = entries.filter { $0.id != id }.map { Self.tileRect($0.rect) }
            target = ResizeClamp.clamp(
                current: Self.tileRect(current),
                desired: requested,
                others: others,
                display: TileSize(width: display.pixelWidth, height: display.pixelHeight),
                gutter: gutter)
        } else {
            target = requested
        }

        // VDS pixels → AX points (the one boundary division, I-3), then write.
        let pointsSize = CGSize(
            width: Coordinates.axPoints(fromVDSPixels: Double(target.width), scale: display.scale),
            height: Coordinates.axPoints(fromVDSPixels: Double(target.height), scale: display.scale)
        )
        let readback = AXWindow(element: element, index: -1).resize(to: pointsSize)
        axWrites += 1

        // Report the ACTUAL geometry, never the requested (I-4).
        guard let p = readback.actualPosition, let s = readback.actualSize else {
            Log.ax.notice(
                "resize: AX would not report geometry back for id \(id, privacy: .public)")
            return
        }
        let vds = Coordinates.displayPixels(
            fromAXRect: CGRect(origin: p, size: s),
            displayOriginPoints: display.originPoints,
            scale: display.scale)
        let rect = WireRect(clampingVDSPixels: vds)
        registry.updateRect(id: id, rect: rect)
        emit(.moved(id: id, rect: rect))
    }

    private static func tileRect(_ r: WireRect) -> TileRect {
        TileRect(x: Int(r.x), y: Int(r.y), width: Int(r.w), height: Int(r.h))
    }

    /// A monotonic clock in seconds (never walks backwards under NTP), for the
    /// throttle. Injected so tests use synthetic time instead.
    public static func monotonicSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
