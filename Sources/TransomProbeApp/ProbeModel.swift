import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import SwiftUI
import TransomKit

/// One line in the live event log.
struct ProbeEvent: Identifiable {
    let id = UUID()
    let t: TimeInterval
    let kind: String
    let detail: String
}

/// User-tunable probe settings, persisted in `UserDefaults` via `@AppStorage`
/// on the view side and handed to the model at Start. The overlay toggles apply
/// live; `fps` and `pollHz` take effect on the next Start.
struct ProbeSettings: Equatable {
    var fps: Int = 60
    var pollHz: Int = 10
    var showWindowRects: Bool = true
    var showMenuRects: Bool = true
    var showLabels: Bool = true

    static let storageKeys = (
        fps: "settings.fps",
        pollHz: "settings.pollHz",
        showWindowRects: "settings.showWindowRects",
        showMenuRects: "settings.showMenuRects",
        showLabels: "settings.showLabels"
    )
}

/// Drives the live probe: an SCK capture of a chosen display, AX window rects
/// polled at ~10Hz and drawn on top, and an event log fed by an AXObserver that
/// catches menu open/close and window create/destroy.
///
/// This is the model behind the section that answers OQ-1: pick Xcode, open the
/// Product menu, and watch both the pixels (does the menu appear in the capture?)
/// and the overlay (did AX give it a rect, with a distinguishable role/subrole?).
@MainActor
final class ProbeModel: ObservableObject {
    @Published var running = false
    @Published var frameImage: NSImage?
    @Published var statsLine = ""
    @Published var events: [ProbeEvent] = []
    @Published var overlayCount = 0
    @Published var lastError: String?

    /// Live-tunable settings. Overlay toggles are read every tick; fps/pollHz are
    /// captured at `start`.
    var settings = ProbeSettings()

    private var capture: DisplayCapture?
    private var display: DisplayInfo?
    private var pid: pid_t = 0
    private var timer: Timer?
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private let start = Date()

    /// Transient AX elements (menus, popovers) currently open, kept so their
    /// rects can be drawn even though they are not in the app's window list.
    private var transientElements: [AXUIElement] = []

    private static let palette: [CGColor] = [
        CGColor(red: 1, green: 0.25, blue: 0.25, alpha: 1),
        CGColor(red: 0.25, green: 1, blue: 0.35, alpha: 1),
        CGColor(red: 0.35, green: 0.65, blue: 1, alpha: 1),
        CGColor(red: 1, green: 0.9, blue: 0.25, alpha: 1),
        CGColor(red: 1, green: 0.45, blue: 1, alpha: 1),
        CGColor(red: 0.3, green: 1, blue: 1, alpha: 1),
    ]

    private static let menuColor = CGColor(red: 1, green: 0.55, blue: 0.0, alpha: 1)

    func start(app: TargetApp, display: DisplayInfo, settings: ProbeSettings) {
        stop()
        lastError = nil
        self.settings = settings
        self.display = display
        self.pid = app.pid
        self.appElement = AXWindow.application(pid: app.pid)

        let capture = DisplayCapture(display: display, fps: settings.fps)
        self.capture = capture

        Task { @MainActor in
            do {
                try await capture.start()
                self.running = true
                self.log(kind: "capture", detail: "started on display \(display.id)")
                self.startObserver()
                self.startTimer()
            } catch {
                self.lastError = "capture failed: \(error)"
                self.log(kind: "error", detail: "\(error)")
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer, let appElement {
            for n in Self.notifications {
                AXObserverRemoveNotification(observer, appElement, n as CFString)
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        transientElements.removeAll()
        if let capture {
            Task { await capture.stop() }
        }
        capture = nil
        running = false
    }

    // MARK: - Timer / overlay

    private func startTimer() {
        let interval = 1.0 / Double(max(1, settings.pollHz))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let capture, let display, let base = capture.latestImage() else { return }

        var overlays: [OverlayRect] = []

        // Standard AX windows.
        if settings.showWindowRects {
            for w in AXWindow.windows(pid: pid) {
                guard let f = w.frame() else { continue }
                let px = Coordinates.displayPixels(
                    fromAXRect: f, displayOriginPoints: display.originPoints, scale: display.scale)
                overlays.append(
                    OverlayRect(
                        rect: px,
                        label: settings.showLabels ? "[\(w.index)] \(w.role)/\(w.subrole)" : "",
                        color: Self.palette[w.index % Self.palette.count]))
            }
        }

        // Transient elements (open menus/popovers) — the OQ-1 payload.
        if settings.showMenuRects {
            for el in transientElements {
                let w = AXWindow(element: el, index: -1)
                guard let f = w.frame() else { continue }
                let px = Coordinates.displayPixels(
                    fromAXRect: f, displayOriginPoints: display.originPoints, scale: display.scale)
                overlays.append(
                    OverlayRect(
                        rect: px, label: settings.showLabels ? "\(w.role)/\(w.subrole)" : "",
                        color: Self.menuColor))
            }
        }

        overlayCount = overlays.count
        if let composed = ImageOutput.overlay(base: base, rects: overlays) {
            frameImage = NSImage(
                cgImage: composed, size: NSSize(width: composed.width, height: composed.height))
        }
        if let s = capture.stats {
            let tag = s.matchesNativePixels ? "1:1 (I-1 ok)" : "SCALED — I-1 VIOLATED"
            statsLine =
                "delivered \(s.deliveredWidth)x\(s.deliveredHeight) "
                + "\(s.pixelFormatString)  [\(tag)]  overlays: \(overlays.count)"
        }
    }

    // MARK: - AX observer

    private static let notifications: [String] = [
        kAXWindowCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXMenuOpenedNotification,
        kAXMenuClosedNotification,
        kAXFocusedUIElementChangedNotification,
    ]

    private func startObserver() {
        guard let appElement else { return }
        var obs: AXObserver?
        guard AXObserverCreate(pid, probeAXCallback, &obs) == .success, let obs else {
            log(kind: "error", detail: "AXObserverCreate failed")
            return
        }
        observer = obs
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in Self.notifications {
            AXObserverAddNotification(obs, appElement, n as CFString, refcon)
        }
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    /// Called (on the main run loop) from the C trampoline.
    func handleAX(element: AXUIElement, notification: String) {
        let w = AXWindow(element: element, index: -1)
        let role = w.role
        let subrole = w.subrole
        let frameStr =
            w.frame().map {
                "(\(Int($0.origin.x)),\(Int($0.origin.y))) \(Int($0.size.width))x\(Int($0.size.height)) pt"
            } ?? "(no frame)"

        switch notification {
        case kAXMenuOpenedNotification:
            transientElements.append(element)
            log(kind: "menu-opened", detail: "\(role)/\(subrole)  \(frameStr)")
        case kAXMenuClosedNotification:
            transientElements.removeAll { CFEqual($0, element) }
            log(kind: "menu-closed", detail: "\(role)/\(subrole)")
        case kAXWindowCreatedNotification:
            log(kind: "window-created", detail: "\(role)/\(subrole)  \(frameStr)")
        case kAXUIElementDestroyedNotification:
            transientElements.removeAll { CFEqual($0, element) }
            log(kind: "destroyed", detail: "\(role)/\(subrole)")
        case kAXFocusedUIElementChangedNotification:
            log(kind: "focus", detail: "\(role)/\(subrole)  \(frameStr)")
        default:
            log(kind: notification, detail: "\(role)/\(subrole)")
        }
    }

    private func log(kind: String, detail: String) {
        let e = ProbeEvent(t: Date().timeIntervalSince(start), kind: kind, detail: detail)
        events.insert(e, at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
    }
}

/// C trampoline for the app's AXObserver. Delivered on the main run loop, so it
/// is safe to hop onto the main actor synchronously.
private func probeAXCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let model = Unmanaged<ProbeModel>.fromOpaque(refcon).takeUnretainedValue()
    // The callback fires on the main run loop (that is the source we registered),
    // so assumeIsolated runs synchronously on this thread — no cross-thread send
    // actually happens. Box the non-Sendable AXUIElement to satisfy the checker.
    let boxed = UncheckedSendableBox(element)
    let note = notification as String
    MainActor.assumeIsolated {
        model.handleAX(element: boxed.value, notification: note)
    }
}

/// Ferries a non-Sendable CoreFoundation value across a statically-checked
/// boundary that is dynamically single-threaded (the main run loop).
struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
