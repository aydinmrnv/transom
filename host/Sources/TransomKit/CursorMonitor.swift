import ApplicationServices
import Foundation

/// AX hit testing is isolated from input delivery. One pending location replaces
/// older locations while an app is answering, so slow accessibility never queues
/// mouse motion. Regions let the PC reject late hints outside the text field.
public final class CursorMonitor: @unchecked Sendable {
    private struct Hover { let id: UInt64; let x: UInt32; let y: UInt32; let ts: UInt64 }
    private let lock = NSLock()
    private var latest: Hover?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "one.transom.cursor", qos: .userInteractive)
    private let registry: WindowRegistry
    private let display: DisplayInfo
    private let emit: @Sendable (ControlMessage) -> Void

    public init(registry: WindowRegistry, display: DisplayInfo, emit: @escaping @Sendable (ControlMessage) -> Void) {
        self.registry = registry; self.display = display; self.emit = emit
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(40))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }
    public func observe(_ message: ClientMessage) {
        guard case let .input(id, event, ts) = message else { return }
        switch event {
        case let .mouseMove(x, y), let .mouseDown(x, y, _), let .mouseUp(x, y, _), let .scroll(x, y, _, _):
            lock.withLock { latest = Hover(id: id, x: x, y: y, ts: ts) }
        default: break
        }
    }
    public func reset() { lock.withLock { latest = nil } }
    public func stop() { timer?.cancel(); timer = nil; reset() }
    deinit { timer?.cancel() }

    static func isTextRole(_ role: String) -> Bool {
        [kAXTextFieldRole as String, kAXTextAreaRole as String, "AXSearchField"].contains(role)
    }

    private func poll() {
        guard let hover = lock.withLock({ latest }),
            let window = registry.element(for: hover.id), let entry = registry.entry(for: hover.id),
            hover.x < entry.rect.w, hover.y < entry.rect.h else { return }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.04)
        let origin = Coordinates.axGlobalRect(fromDisplayPixels: CGRect(x: Int(entry.rect.x), y: Int(entry.rect.y), width: Int(entry.rect.w), height: Int(entry.rect.h)), displayOriginPoints: display.originPoints, scale: display.scale)
        let point = CGPoint(x: origin.minX + CGFloat(hover.x) / display.scale,
                            y: origin.minY + CGFloat(hover.y) / display.scale)
        var hit: AXUIElement?
        var text = false
        var region = WireRect(x: hover.x, y: hover.y, w: 1, h: 1)
        if AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success {
            // Web editors sometimes expose a static child inside a text area.
            for _ in 0..<6 {
                guard let element = hit else { break }
                AXUIElementSetMessagingTimeout(element, 0.04)
                let ax = AXWindow(element: element, index: -1)
                if Self.isTextRole(ax.role), let frame = ax.frame(), frame.contains(point) {
                    let clipped = frame.intersection(origin)
                    if !clipped.isNull {
                        text = true
                        region = WireRect(clampingVDSPixels: CGRect(
                            x: (clipped.minX - origin.minX) * display.scale,
                            y: (clipped.minY - origin.minY) * display.scale,
                            width: clipped.width * display.scale, height: clipped.height * display.scale))
                    }
                    break
                }
                if CFEqual(element, window) { break }
                var parent: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                      let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                hit = unsafeDowncast(parent, to: AXUIElement.self)
            }
        }
        guard lock.withLock({ latest?.id == hover.id }) else { return }
        emit(.cursorShape(id: hover.id, text: text, rect: region, ts: hover.ts))
    }
}
