import TransomKit

/// Client-side input simulation for the verification commands (`inject`,
/// `mock-client`). This is deliberately **not** in `TransomKit`: producing
/// Windows VK codes from text/chords is the *client's* job (issue #7), and the
/// host never does it. It lives here only so a mock client can stand in for the
/// real Rust one that does not exist yet (protocol.md, I-7).
///
/// Everything here emits **Windows VK codes**, exactly as the real client would.
/// The host then maps them (VK → macOS keycode) and applies the modifier mapping
/// (default swap: Ctrl → ⌘). So `chord("ctrl+a")` here becomes ⌘A on the Mac.
enum MockInput {

    /// `keyDown`/`keyUp` events to type `text`, plus any characters this small
    /// US-layout table does not cover (reported, never silently dropped).
    static func typing(_ text: String) -> (events: [InputEvent], unsupported: [Character]) {
        var events: [InputEvent] = []
        var unsupported: [Character] = []
        for ch in text {
            guard let (vk, shift) = Self.character(ch) else {
                unsupported.append(ch)
                continue
            }
            if shift { events.append(.keyDown(vk: WinVK.shift)) }
            events.append(.keyDown(vk: vk))
            events.append(.keyUp(vk: vk))
            if shift { events.append(.keyUp(vk: WinVK.shift)) }
        }
        return (events, unsupported)
    }

    /// Parse a `+`-separated chord like `ctrl+a`, `ctrl+shift+t`, `alt+f4` (all
    /// Windows-side names) into press-all / release-all-in-reverse events.
    static func chord(_ spec: String) -> (events: [InputEvent], error: String?) {
        let tokens = spec.split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard let keyToken = tokens.last, tokens.count >= 1 else {
            return ([], "empty chord")
        }
        var modVKs: [UInt32] = []
        for token in tokens.dropLast() {
            guard let vk = Self.modifier(token) else {
                return ([], "unknown modifier \"\(token)\" (use ctrl/shift/alt/win)")
            }
            modVKs.append(vk)
        }
        guard let keyVK = Self.namedKey(keyToken) else {
            return ([], "unknown key \"\(keyToken)\"")
        }
        var events: [InputEvent] = []
        for vk in modVKs { events.append(.keyDown(vk: vk)) }
        events.append(.keyDown(vk: keyVK))
        events.append(.keyUp(vk: keyVK))
        for vk in modVKs.reversed() { events.append(.keyUp(vk: vk)) }
        return (events, nil)
    }

    // MARK: - Tables (US/ANSI layout)

    private static func modifier(_ name: String) -> UInt32? {
        switch name {
        case "ctrl", "control": return WinVK.control
        case "shift": return WinVK.shift
        case "alt", "menu", "option": return WinVK.menu
        case "win", "super", "meta", "cmd": return WinVK.lWin
        default: return nil
        }
    }

    /// A single named key for a chord's final token: a letter/digit, or one of a
    /// few named keys a terminal/editor chord actually uses.
    private static func namedKey(_ token: String) -> UInt32? {
        if token.count == 1, let ch = token.first, let (vk, _) = character(ch) { return vk }
        switch token {
        case "enter", "return": return WinVK.returnKey
        case "tab": return WinVK.tab
        case "esc", "escape": return WinVK.escape
        case "space": return WinVK.space
        case "backspace": return WinVK.back
        case "delete", "del": return WinVK.delete
        case "left": return WinVK.left
        case "right": return WinVK.right
        case "up": return WinVK.up
        case "down": return WinVK.down
        case "home": return WinVK.home
        case "end": return WinVK.end
        case "f1": return 0x70
        case "f2": return 0x71
        case "f3": return 0x72
        case "f4": return 0x73
        case "f5": return 0x74
        default: return nil
        }
    }

    /// Character → (Windows VK, needs-Shift) for typing on a US/ANSI keyboard.
    private static func character(_ ch: Character) -> (vk: UInt32, shift: Bool)? {
        // Letters.
        if let ascii = ch.asciiValue {
            if ascii >= 0x61, ascii <= 0x7A {  // a–z
                return (UInt32(ascii - 0x20), false)  // VK is the uppercase code
            }
            if ascii >= 0x41, ascii <= 0x5A {  // A–Z
                return (UInt32(ascii), true)
            }
            if ascii >= 0x30, ascii <= 0x39 {  // 0–9
                return (UInt32(ascii), false)
            }
        }
        switch ch {
        case " ": return (WinVK.space, false)
        case "\n", "\r": return (WinVK.returnKey, false)
        case "\t": return (WinVK.tab, false)
        // Shifted digits.
        case "!": return (0x31, true)
        case "@": return (0x32, true)
        case "#": return (0x33, true)
        case "$": return (0x34, true)
        case "%": return (0x35, true)
        case "^": return (0x36, true)
        case "&": return (0x37, true)
        case "*": return (0x38, true)
        case "(": return (0x39, true)
        case ")": return (0x30, true)
        // OEM punctuation.
        case "`": return (WinVK.oem3, false)
        case "~": return (WinVK.oem3, true)
        case "-": return (WinVK.oemMinus, false)
        case "_": return (WinVK.oemMinus, true)
        case "=": return (WinVK.oemPlus, false)
        case "+": return (WinVK.oemPlus, true)
        case "[": return (WinVK.oem4, false)
        case "{": return (WinVK.oem4, true)
        case "]": return (WinVK.oem6, false)
        case "}": return (WinVK.oem6, true)
        case "\\": return (WinVK.oem5, false)
        case "|": return (WinVK.oem5, true)
        case ";": return (WinVK.oem1, false)
        case ":": return (WinVK.oem1, true)
        case "'": return (WinVK.oem7, false)
        case "\"": return (WinVK.oem7, true)
        case ",": return (WinVK.oemComma, false)
        case "<": return (WinVK.oemComma, true)
        case ".": return (WinVK.oemPeriod, false)
        case ">": return (WinVK.oemPeriod, true)
        case "/": return (WinVK.oem2, false)
        case "?": return (WinVK.oem2, true)
        default: return nil
        }
    }
}
