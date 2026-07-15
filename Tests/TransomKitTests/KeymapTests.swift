import CoreGraphics
import Testing

@testable import TransomKit

/// The Windows-VK → macOS-keycode table is "the boring, error-prone part" (issue
/// #7). A wrong entry types the wrong character with no crash to catch it, so the
/// table is pinned here against the two reference headers.
@Suite("Keymap")
struct KeymapTests {

    @Test("letters map to their scattered macOS ANSI keycodes")
    func letters() {
        // VK for a letter is ASCII of its uppercase form.
        #expect(Keymap.macKeyCode(forVK: 0x41) == 0x00)  // A
        #expect(Keymap.macKeyCode(forVK: 0x53) == 0x01)  // S
        #expect(Keymap.macKeyCode(forVK: 0x5A) == 0x06)  // Z
        #expect(Keymap.macKeyCode(forVK: 0x4D) == 0x2E)  // M
        #expect(Keymap.macKeyCode(forVK: 0x51) == 0x0C)  // Q
    }

    @Test("digits map, including the 5/6 macOS keycode swap")
    func digits() {
        #expect(Keymap.macKeyCode(forVK: 0x31) == 0x12)  // 1
        #expect(Keymap.macKeyCode(forVK: 0x30) == 0x1D)  // 0
        #expect(Keymap.macKeyCode(forVK: 0x35) == 0x17)  // 5
        #expect(Keymap.macKeyCode(forVK: 0x36) == 0x16)  // 6 (< 5's code)
    }

    @Test("editing / whitespace keys")
    func editing() {
        #expect(Keymap.macKeyCode(forVK: WinVK.returnKey) == 0x24)  // Return
        #expect(Keymap.macKeyCode(forVK: WinVK.tab) == 0x30)  // Tab
        #expect(Keymap.macKeyCode(forVK: WinVK.space) == 0x31)  // Space
        #expect(Keymap.macKeyCode(forVK: WinVK.escape) == 0x35)  // Escape
        #expect(Keymap.macKeyCode(forVK: WinVK.back) == 0x33)  // Backspace -> kVK_Delete
        #expect(Keymap.macKeyCode(forVK: WinVK.delete) == 0x75)  // Del -> kVK_ForwardDelete
    }

    @Test("arrow keys")
    func arrows() {
        #expect(Keymap.macKeyCode(forVK: WinVK.left) == 0x7B)
        #expect(Keymap.macKeyCode(forVK: WinVK.right) == 0x7C)
        #expect(Keymap.macKeyCode(forVK: WinVK.down) == 0x7D)
        #expect(Keymap.macKeyCode(forVK: WinVK.up) == 0x7E)
    }

    @Test("function keys F1 and F12 (the scattered ends)")
    func functionKeys() {
        #expect(Keymap.macKeyCode(forVK: 0x70) == 0x7A)  // F1
        #expect(Keymap.macKeyCode(forVK: 0x7B) == 0x6F)  // F12
    }

    @Test("OEM punctuation (US layout)")
    func punctuation() {
        #expect(Keymap.macKeyCode(forVK: WinVK.oem3) == 0x32)  // ` ~
        #expect(Keymap.macKeyCode(forVK: WinVK.oem2) == 0x2C)  // / ?
        #expect(Keymap.macKeyCode(forVK: WinVK.oemPeriod) == 0x2F)  // . >
    }

    @Test("modifiers are not posted as characters (macKeyCode returns nil)")
    func modifiersAreNotCharacters() {
        for vk in [
            WinVK.shift, WinVK.control, WinVK.menu, WinVK.lWin, WinVK.rWin,
            WinVK.lShift, WinVK.rControl, WinVK.rMenu,
        ] {
            #expect(Keymap.macKeyCode(forVK: vk) == nil)
        }
    }

    @Test("modifier classification collapses left/right into groups")
    func modifierClassification() {
        #expect(Keymap.windowsModifier(forVK: WinVK.shift) == .shift)
        #expect(Keymap.windowsModifier(forVK: WinVK.lShift) == .shift)
        #expect(Keymap.windowsModifier(forVK: WinVK.rShift) == .shift)
        #expect(Keymap.windowsModifier(forVK: WinVK.control) == .control)
        #expect(Keymap.windowsModifier(forVK: WinVK.rControl) == .control)
        #expect(Keymap.windowsModifier(forVK: WinVK.menu) == .alt)
        #expect(Keymap.windowsModifier(forVK: WinVK.rMenu) == .alt)
        #expect(Keymap.windowsModifier(forVK: WinVK.lWin) == .win)
        // A letter is not a modifier.
        #expect(Keymap.windowsModifier(forVK: 0x41) == nil)
    }

    @Test("an unmapped, non-modifier VK is nil for both queries (caller must report)")
    func unmapped() {
        // 0x92 is an unassigned Windows VK.
        #expect(Keymap.macKeyCode(forVK: 0x92) == nil)
        #expect(Keymap.windowsModifier(forVK: 0x92) == nil)
    }
}
