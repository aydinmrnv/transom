import ApplicationServices
import Testing
@testable import TransomKit

@Suite("Independent window input routing")
struct InputRoutingTests {
    private func move(_ id: UInt64, _ x: UInt32) -> ClientMessage {
        .input(id: id, event: .mouseMove(x: x, y: 10), ts: UInt64(x))
    }

    @Test("queued motion collapses to the latest position")
    func motionBacklog() {
        var mailbox = InputMailbox()
        for x in 0..<1000 { mailbox.append(move(1, UInt32(x))) }
        guard case let .message(.input(id, .mouseMove(x, _), _))? = mailbox.next() else {
            Issue.record("Missing final motion"); return
        }
        #expect(id == 1 && x == 999)
        #expect(mailbox.next() == nil)
    }

    @Test("click barriers keep motion and button order intact")
    func clickOrdering() {
        var mailbox = InputMailbox()
        mailbox.append(move(1, 10))
        mailbox.append(.input(id: 1, event: .mouseDown(x: 10, y: 10, button: .left), ts: 10))
        mailbox.append(move(1, 20))
        mailbox.append(move(1, 30))
        mailbox.append(.input(id: 1, event: .mouseUp(x: 30, y: 10, button: .left), ts: 30))
        guard case .message(.input(_, .mouseMove(10, _), _))? = mailbox.next(),
              case .message(.input(_, .mouseDown(10, _, _), _))? = mailbox.next(),
              case .message(.input(_, .mouseMove(30, _), _))? = mailbox.next(),
              case .message(.input(_, .mouseUp(30, _, _), _))? = mailbox.next() else {
            Issue.record("Motion crossed a button barrier"); return
        }
        #expect(mailbox.next() == nil)
    }

    @Test("focus and keyboard events retain their selected window and order")
    func focusOrdering() {
        var mailbox = InputMailbox()
        mailbox.append(move(1, 10))
        mailbox.append(.requestFocus(id: 2))
        mailbox.append(.input(id: 2, event: .keyDown(vk: 65), ts: 20))
        mailbox.append(move(2, 30))
        guard case .message(.input(1, .mouseMove, _))? = mailbox.next(),
              case .message(.requestFocus(2))? = mailbox.next(),
              case .message(.input(2, .keyDown(65), _))? = mailbox.next(),
              case .message(.input(2, .mouseMove, _))? = mailbox.next() else {
            Issue.record("Window focus or key ordering changed"); return
        }
    }

    @Test("disconnect discards stale input before a new session")
    func disconnectBarrier() {
        var mailbox = InputMailbox()
        mailbox.append(.input(id: 1, event: .keyDown(vk: 65), ts: 10))
        mailbox.reset()
        mailbox.append(.requestFocus(id: 2))
        guard case .reset? = mailbox.next(), case .message(.requestFocus(2))? = mailbox.next() else {
            Issue.record("Old input survived disconnect"); return
        }
        #expect(mailbox.next() == nil)
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
    }
}
