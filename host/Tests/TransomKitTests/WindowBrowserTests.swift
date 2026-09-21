import CoreGraphics
import Foundation
import Testing
@testable import TransomKit

@Suite("Client window selection and cursor hints")
struct WindowBrowserTests {
    @Test("capture badges are excluded without hiding standard windows or normal dialogs")
    func captureBadge() {
        #expect(!WindowBrowser.selectableWindow(role: "AXWindow", subrole: "AXDialog", size: CGSize(width: 66, height: 20)))
        #expect(WindowBrowser.selectableWindow(role: "AXWindow", subrole: "AXDialog", size: CGSize(width: 400, height: 180)))
        #expect(WindowBrowser.selectableWindow(role: "AXWindow", subrole: "AXStandardWindow", size: CGSize(width: 180, height: 30)))
        #expect(!WindowBrowser.selectableWindow(role: "AXMenu", subrole: "", size: CGSize(width: 400, height: 180)))
    }
    @Test("same-title windows use geometry; ambiguous windows are refused")
    func identity() {
        let a = CGRect(x: 10, y: 10, width: 800, height: 600)
        let b = CGRect(x: 900, y: 10, width: 800, height: 600)
        #expect(WindowBrowser.matchIndex(title: "Document", frame: a, choices: [("Document", b),("Document",a)]) == 1)
        #expect(WindowBrowser.matchIndex(title: "Document", frame: a, choices: [("Document",a),("Document",a)]) == nil)
        #expect(WindowBrowser.matchIndex(title: "Document", frame: a, choices: [("Other",b)]) == nil)
        #expect(WindowBrowser.matchIndex(title: "Document", frame: a, choices: [("Document",b)]) == 0)
    }
    @Test("only text editing roles request an I-beam")
    func cursorRoles() {
        for role in ["AXTextField", "AXTextArea", "AXSearchField"] { #expect(CursorMonitor.isTextRole(role)) }
        for role in ["AXButton", "AXWindow", "AXStaticText", "AXScrollArea"] { #expect(!CursorMonitor.isTextRole(role)) }
    }
    @Test("catalogue has no crop, and cursor regions use physical pixels")
    func protocolRoundTrip() throws {
        let messages: [ControlMessage] = [
            .windowCatalog(windows: [AvailableWindow(id: UInt64.max, title: "Editor — 日本語", minimized: true)]),
            .windowPreview(id: 42, jpeg: "Zm9v"), .windowOpened(id: 42),
            .cursorShape(id: 42, text: true, rect: WireRect(x: 20, y: 100, w: 800, h: 40), ts: 12345)
        ]
        for message in messages {
            let data = try JSONEncoder().encode(message)
            #expect(try JSONDecoder().decode(ControlMessage.self, from: data) == message)
        }
        for message in [ClientMessage.openWindow(id: 42), .releaseWindow(id: 42), .previewWindow(id: 42)] {
            #expect(try JSONDecoder().decode(ClientMessage.self, from: JSONEncoder().encode(message)) == message)
        }
    }
}
