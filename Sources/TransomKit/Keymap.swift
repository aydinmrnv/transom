import CoreGraphics

/// Windows virtual-key codes → macOS virtual keycodes (issue #7).
///
/// The client sends **Windows VK codes** (`InputEvent.keyDown/keyUp`), because it
/// only knows its own physical keyboard. The host must translate each one to the
/// macOS keycode `CGEventCreateKeyboardEvent` expects. "The mapping table is the
/// boring, error-prone part" — so it lives here, alone, pure, and is unit tested.
///
/// Two honesty rules the issue insists on:
///
/// 1. **Unmapped keys are reported, not silently dropped.** `macKeyCode(forVK:)`
///    returns `nil` for a VK this table does not cover; the injector logs it (see
///    `InputInjector`) rather than swallowing the keystroke.
/// 2. **Modifiers are not "keys" here.** Shift/Ctrl/Alt/Win are classified by
///    `windowsModifier(forVK:)` and tracked by `ModifierState`; they are *stamped*
///    onto other events as flags, never posted as characters, so `macKeyCode`
///    deliberately returns `nil` for them.
///
/// **Layout caveat:** macOS keycodes are physical-position codes (ANSI layout).
/// The *character* produced depends on the Mac's active keyboard layout. This
/// table is correct for the US/ANSI layout, which is what the target set (a
/// terminal, Conductor) uses. A non-US Mac layout would produce different
/// characters for the same positions; remapping for other layouts is out of scope
/// for v1 and noted in protocol.md §4.
public enum Keymap {

    /// The macOS keycode to post for a Windows VK, or `nil` if unmapped (caller
    /// must report, per the issue) **or** if the VK is a modifier (handled by
    /// `windowsModifier`/`ModifierState`, not posted as a character).
    public static func macKeyCode(forVK vk: UInt32) -> CGKeyCode? {
        table[vk]
    }

    /// Which macOS-modifier group a Windows VK belongs to, or `nil` if it is not
    /// a modifier key. Left/right variants collapse to the same group; the
    /// physical-side distinction does not matter for `CGEventFlags`.
    public static func windowsModifier(forVK vk: UInt32) -> WinModifier? {
        switch vk {
        case WinVK.shift, WinVK.lShift, WinVK.rShift: return .shift
        case WinVK.control, WinVK.lControl, WinVK.rControl: return .control
        case WinVK.menu, WinVK.lMenu, WinVK.rMenu: return .alt
        case WinVK.lWin, WinVK.rWin: return .win
        default: return nil
        }
    }

    /// Every VK this table posts as a character/navigation key (for tests and for
    /// documenting coverage). Excludes modifiers by construction.
    public static var mappedVKs: Set<UInt32> { Set(table.keys) }

    /// The table. Kept as raw hex on both sides so it reads like the reference
    /// docs (Microsoft `WinUser.h`, Apple `HIToolbox/Events.h`) and can be
    /// diffed against them. Values are `MacKey` constants; keys are `WinVK`.
    private static let table: [UInt32: CGKeyCode] = {
        var t: [UInt32: CGKeyCode] = [:]

        // Letters A–Z. Windows VK is ASCII 'A'…'Z' (0x41–0x5A); macOS keycodes
        // are non-sequential, so this is a per-letter map, not an offset.
        let letters: [Character: CGKeyCode] = [
            "A": 0x00, "S": 0x01, "D": 0x02, "F": 0x03, "H": 0x04, "G": 0x05,
            "Z": 0x06, "X": 0x07, "C": 0x08, "V": 0x09, "B": 0x0B, "Q": 0x0C,
            "W": 0x0D, "E": 0x0E, "R": 0x0F, "Y": 0x10, "T": 0x11, "O": 0x1F,
            "U": 0x20, "I": 0x22, "P": 0x23, "L": 0x25, "J": 0x26, "K": 0x28,
            "N": 0x2D, "M": 0x2E,
        ]
        for (ch, code) in letters {
            // swift-format-ignore: NeverForceUnwrap — ASCII letters have scalars.
            t[UInt32(ch.unicodeScalars.first!.value)] = code
        }

        // Digits 0–9 on the top row. Windows VK is ASCII '0'…'9' (0x30–0x39).
        let digits: [Character: CGKeyCode] = [
            "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17,
            "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D,
        ]
        for (ch, code) in digits {
            // swift-format-ignore: NeverForceUnwrap — ASCII digits have scalars.
            t[UInt32(ch.unicodeScalars.first!.value)] = code
        }

        // Whitespace / editing.
        t[WinVK.space] = 0x31  // kVK_Space
        t[WinVK.returnKey] = 0x24  // kVK_Return
        t[WinVK.tab] = 0x30  // kVK_Tab
        t[WinVK.escape] = 0x35  // kVK_Escape
        t[WinVK.back] = 0x33  // kVK_Delete (Backspace)
        t[WinVK.delete] = 0x75  // kVK_ForwardDelete (Del)
        t[WinVK.insert] = 0x72  // kVK_Help (Insert has no dedicated mac key)

        // Navigation.
        t[WinVK.left] = 0x7B  // kVK_LeftArrow
        t[WinVK.right] = 0x7C  // kVK_RightArrow
        t[WinVK.down] = 0x7D  // kVK_DownArrow
        t[WinVK.up] = 0x7E  // kVK_UpArrow
        t[WinVK.home] = 0x73  // kVK_Home
        t[WinVK.end] = 0x77  // kVK_End
        t[WinVK.pageUp] = 0x74  // kVK_PageUp
        t[WinVK.pageDown] = 0x79  // kVK_PageDown

        // OEM punctuation (US/ANSI layout).
        t[WinVK.oem1] = 0x29  // ; :   kVK_ANSI_Semicolon
        t[WinVK.oemPlus] = 0x18  // = +   kVK_ANSI_Equal
        t[WinVK.oemComma] = 0x2B  // , <   kVK_ANSI_Comma
        t[WinVK.oemMinus] = 0x1B  // - _   kVK_ANSI_Minus
        t[WinVK.oemPeriod] = 0x2F  // . >   kVK_ANSI_Period
        t[WinVK.oem2] = 0x2C  // / ?   kVK_ANSI_Slash
        t[WinVK.oem3] = 0x32  // ` ~   kVK_ANSI_Grave
        t[WinVK.oem4] = 0x21  // [ {   kVK_ANSI_LeftBracket
        t[WinVK.oem5] = 0x2A  // \ |   kVK_ANSI_Backslash
        t[WinVK.oem6] = 0x1E  // ] }   kVK_ANSI_RightBracket
        t[WinVK.oem7] = 0x27  // ' "   kVK_ANSI_Quote

        // Numeric keypad.
        let keypad: [(UInt32, CGKeyCode)] = [
            (0x60, 0x52), (0x61, 0x53), (0x62, 0x54), (0x63, 0x55), (0x64, 0x56),
            (0x65, 0x57), (0x66, 0x58), (0x67, 0x59), (0x68, 0x5B), (0x69, 0x5C),
        ]
        for (vk, code) in keypad { t[vk] = code }
        t[WinVK.multiply] = 0x43  // kVK_ANSI_KeypadMultiply
        t[WinVK.add] = 0x45  // kVK_ANSI_KeypadPlus
        t[WinVK.subtract] = 0x4E  // kVK_ANSI_KeypadMinus
        t[WinVK.decimal] = 0x41  // kVK_ANSI_KeypadDecimal
        t[WinVK.divide] = 0x4B  // kVK_ANSI_KeypadDivide

        // Function keys F1–F12. macOS keycodes are famously scattered.
        let fkeys: [(UInt32, CGKeyCode)] = [
            (0x70, 0x7A), (0x71, 0x78), (0x72, 0x63), (0x73, 0x76),  // F1–F4
            (0x74, 0x60), (0x75, 0x61), (0x76, 0x62), (0x77, 0x64),  // F5–F8
            (0x78, 0x65), (0x79, 0x6D), (0x7A, 0x67), (0x7B, 0x6F),  // F9–F12
        ]
        for (vk, code) in fkeys { t[vk] = code }

        return t
    }()
}

/// Named Windows virtual-key code constants (subset we translate). Mirrors
/// Microsoft `WinUser.h` so the table above can be diffed against the reference.
/// Letters/digits are ASCII and not named here.
public enum WinVK {
    public static let back: UInt32 = 0x08
    public static let tab: UInt32 = 0x09
    public static let returnKey: UInt32 = 0x0D
    public static let shift: UInt32 = 0x10
    public static let control: UInt32 = 0x11
    public static let menu: UInt32 = 0x12  // Alt
    public static let capital: UInt32 = 0x14  // Caps Lock
    public static let escape: UInt32 = 0x1B
    public static let space: UInt32 = 0x20
    public static let pageUp: UInt32 = 0x21
    public static let pageDown: UInt32 = 0x22
    public static let end: UInt32 = 0x23
    public static let home: UInt32 = 0x24
    public static let left: UInt32 = 0x25
    public static let up: UInt32 = 0x26
    public static let right: UInt32 = 0x27
    public static let down: UInt32 = 0x28
    public static let insert: UInt32 = 0x2D
    public static let delete: UInt32 = 0x2E
    public static let lWin: UInt32 = 0x5B
    public static let rWin: UInt32 = 0x5C
    public static let multiply: UInt32 = 0x6A
    public static let add: UInt32 = 0x6B
    public static let subtract: UInt32 = 0x6D
    public static let decimal: UInt32 = 0x6E
    public static let divide: UInt32 = 0x6F
    public static let lShift: UInt32 = 0xA0
    public static let rShift: UInt32 = 0xA1
    public static let lControl: UInt32 = 0xA2
    public static let rControl: UInt32 = 0xA3
    public static let lMenu: UInt32 = 0xA4
    public static let rMenu: UInt32 = 0xA5
    public static let oem1: UInt32 = 0xBA  // ; :
    public static let oemPlus: UInt32 = 0xBB  // = +
    public static let oemComma: UInt32 = 0xBC  // , <
    public static let oemMinus: UInt32 = 0xBD  // - _
    public static let oemPeriod: UInt32 = 0xBE  // . >
    public static let oem2: UInt32 = 0xBF  // / ?
    public static let oem3: UInt32 = 0xC0  // ` ~
    public static let oem4: UInt32 = 0xDB  // [ {
    public static let oem5: UInt32 = 0xDC  // \ |
    public static let oem6: UInt32 = 0xDD  // ] }
    public static let oem7: UInt32 = 0xDE  // ' "
}
