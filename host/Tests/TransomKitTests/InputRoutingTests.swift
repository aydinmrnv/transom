import ApplicationServices
import Testing
@testable import TransomKit

@Suite("Independent window input routing")
struct InputRoutingTests {
    @Test("overlapping pointer events retain the selected process and window")
    func pointerDestination() throws {
        let point = CGPoint(x: 400, y: 300)
        let xcode = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left))
        let conductor = try #require(xcode.copy())
        InputInjector.address(xcode, pid: 123, windowID: 456)
        InputInjector.address(conductor, pid: 789, windowID: 987)
        #expect(xcode.location == conductor.location)
        #expect(xcode.getIntegerValueField(.eventTargetUnixProcessID) == 123)
        #expect(xcode.getIntegerValueField(.mouseEventWindowUnderMousePointer) == 456)
        #expect(xcode.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) == 456)
        #expect(conductor.getIntegerValueField(.eventTargetUnixProcessID) == 789)
        #expect(conductor.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) == 987)
    }

    @Test("keyboard and scroll are addressed to their selected app too")
    func keyboardAndScroll() throws {
        let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        InputInjector.address(key, pid: 123, windowID: nil)
        #expect(key.getIntegerValueField(.eventTargetUnixProcessID) == 123)
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        InputInjector.address(wheel, pid: 789, windowID: 987)
        #expect(wheel.getIntegerValueField(.eventTargetUnixProcessID) == 789)
        #expect(wheel.getIntegerValueField(.mouseEventWindowUnderMousePointer) == 987)
    }

    @Test("releasing a window discards its capture routing identity")
    func releaseDestination() {
        let registry = WindowRegistry()
        let element = AXUIElementCreateApplication(123)
        let id = registry.id(for: element).id
        registry.setCaptureID(456, for: id)
        registry.record(id: id, rect: WireRect(x: 0, y: 0, w: 800, h: 600), title: "Test")
        registry.unshare(id: id)
        #expect(registry.captureID(for: id) == nil)
        #expect(registry.entry(for: id) == nil)
        registry.setCaptureID(789, for: id)
        _ = registry.remove(element: element)
        #expect(registry.captureID(for: id) == nil)
    }
}
