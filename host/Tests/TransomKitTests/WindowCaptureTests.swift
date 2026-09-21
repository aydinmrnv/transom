import CoreGraphics
import ApplicationServices
import Testing

@testable import TransomKit

@Suite("Window capture bounds")
struct WindowCaptureTests {
    @Test("unreadable AX notifications cannot fabricate a window")
    func rejectsInvalidNotificationElements() {
        let display = DisplayInfo(id: 1, originPoints: .zero,
            sizePoints: CGSize(width: 1920, height: 1080),
            pixelWidth: 3840, pixelHeight: 2160, scale: 2, isMain: true)
        // No such process exists: both the element and focused-window reads fail.
        // Previously either event still minted a zero-origin, zero-size window.
        let pid: pid_t = 999_999_999
        for notification in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            let registry = WindowRegistry()
            let watcher = WindowWatcher(pid: pid, display: display, registry: registry)
            watcher.handle(element: AXWindow.application(pid: pid), notification: notification)
            #expect(registry.snapshot().isEmpty)
        }
    }

    @Test("only real positive window crops fit the capture surface")
    func validCrop() {
        #expect(WindowWatcher.captureRect(CGRect(x: 20, y: 60, width: 1200, height: 800),
            displayWidth: 3840, displayHeight: 2160) == WireRect(x: 20, y: 60, w: 1200, h: 800))
        #expect(WindowWatcher.captureRect(CGRect(x: 0, y: 0, width: 3840, height: 2160),
            displayWidth: 3840, displayHeight: 2160) == WireRect(x: 0, y: 0, w: 3840, h: 2160))
    }

    @Test("invalid AX frames cannot become desktop-origin or partial crops")
    func rejectsInvalidCrops() {
        for frame in [CGRect.zero, CGRect.null, CGRect.infinite,
            CGRect(x: -50, y: 20, width: 500, height: 500),
            CGRect(x: 20, y: -50, width: 500, height: 500),
            CGRect(x: 3500, y: 20, width: 500, height: 500),
            CGRect(x: 20, y: 2000, width: 500, height: 500),
            CGRect(x: 0, y: 0, width: 0.1, height: 0.1)] {
            #expect(WindowWatcher.captureRect(frame, displayWidth: 3840, displayHeight: 2160) == nil)
        }
    }
}
