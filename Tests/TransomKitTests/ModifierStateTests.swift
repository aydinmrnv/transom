import CoreGraphics
import Testing

@testable import TransomKit

/// The modifier state machine (issue #7): "modifier state must be tracked, not
/// inferred per-event." Pure, so the whole chord path is tested here with no Mac.
@Suite("ModifierState")
struct ModifierStateTests {

    @Test("a fresh state holds nothing and stamps no flags")
    func empty() {
        let state = ModifierState()
        #expect(state.heldModifiers.isEmpty)
        #expect(state.flags(using: .swap) == [])
    }

    @Test("apply reports whether the VK was a modifier")
    func applyReturnsModifierness() {
        var state = ModifierState()
        #expect(state.apply(vk: WinVK.control, down: true) == true)
        #expect(state.apply(vk: 0x41, down: true) == false)  // 'A' is not a modifier
    }

    @Test("default swap maps Windows Ctrl to ⌘ and Win to ⌃")
    func swapMapping() {
        var state = ModifierState()
        state.apply(vk: WinVK.control, down: true)
        #expect(state.flags(using: .swap) == .maskCommand)

        state.apply(vk: WinVK.control, down: false)
        state.apply(vk: WinVK.lWin, down: true)
        #expect(state.flags(using: .swap) == .maskControl)
    }

    @Test("namesake mapping keeps Ctrl as ⌃ and Win as ⌘")
    func namesakeMapping() {
        var state = ModifierState()
        state.apply(vk: WinVK.control, down: true)
        #expect(state.flags(using: .namesake) == .maskControl)

        state.apply(vk: WinVK.control, down: false)
        state.apply(vk: WinVK.lWin, down: true)
        #expect(state.flags(using: .namesake) == .maskCommand)
    }

    @Test("a held modifier stays held across other keydowns (the Cmd+A case)")
    func heldAcrossKeys() {
        var state = ModifierState()
        // Windows Ctrl down (→ ⌘ under swap), then A down, A up — Ctrl stays held.
        state.apply(vk: WinVK.control, down: true)
        #expect(state.apply(vk: 0x41, down: true) == false)  // A: not a modifier
        #expect(state.flags(using: .swap) == .maskCommand)  // ⌘ still applied to A
        #expect(state.apply(vk: 0x41, down: false) == false)
        #expect(state.flags(using: .swap) == .maskCommand)  // still held after A up
        // Now release Ctrl.
        state.apply(vk: WinVK.control, down: false)
        #expect(state.flags(using: .swap) == [])
    }

    @Test("multiple modifiers combine into one flag set")
    func combined() {
        var state = ModifierState()
        state.apply(vk: WinVK.control, down: true)  // → ⌘
        state.apply(vk: WinVK.shift, down: true)  // → ⇧
        #expect(state.flags(using: .swap) == [.maskCommand, .maskShift])
        #expect(state.heldModifiers == [.control, .shift])
    }

    @Test("left/right variants are the same held group")
    func leftRightCollapse() {
        var state = ModifierState()
        state.apply(vk: WinVK.lShift, down: true)
        // Releasing the *right* shift clears the group — sides collapse.
        state.apply(vk: WinVK.rShift, down: false)
        #expect(state.flags(using: .swap) == [])
    }

    @Test("reset drops everything (client disconnect)")
    func reset() {
        var state = ModifierState()
        state.apply(vk: WinVK.control, down: true)
        state.apply(vk: WinVK.menu, down: true)
        state.reset()
        #expect(state.heldModifiers.isEmpty)
        #expect(state.flags(using: .swap) == [])
    }
}
