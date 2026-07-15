import CoreGraphics

/// The four modifier groups a Windows keyboard exposes. Left/right physical keys
/// collapse to one group — `CGEventFlags` does not distinguish sides.
public enum WinModifier: Hashable, Sendable, CaseIterable {
    case shift
    case control
    case alt  // "Menu" in Windows VK naming
    case win  // "Super"/Windows logo key
}

/// How each Windows modifier group becomes a macOS `CGEventFlags` bit.
///
/// This is the home of the **Cmd-vs-Ctrl product decision** (issue #7): the
/// Windows client sends what its keyboard has, and whether its Ctrl becomes ⌘ or
/// ⌃ is a choice, not a fact. Both presets are provided; `serve` picks one.
public struct ModifierMap: Sendable {
    public let shift: CGEventFlags
    public let control: CGEventFlags
    public let alt: CGEventFlags
    public let win: CGEventFlags

    public init(shift: CGEventFlags, control: CGEventFlags, alt: CGEventFlags, win: CGEventFlags) {
        self.shift = shift
        self.control = control
        self.alt = alt
        self.win = win
    }

    public func flags(for modifier: WinModifier) -> CGEventFlags {
        switch modifier {
        case .shift: return shift
        case .control: return control
        case .alt: return alt
        case .win: return win
        }
    }

    /// **Default (chosen for issue #7):** swap so muscle memory carries over —
    /// Windows **Ctrl → ⌘ Command**, **Win → ⌃ Control**, Alt → ⌥ Option, Shift →
    /// ⇧. So `Ctrl+C` on the PC triggers `⌘C` (copy) on the Mac, as in most
    /// Mac-remoting tools. Trade-off: a terminal's `Ctrl+C` (SIGINT) is then
    /// `Win+C` on the PC. Recorded in protocol.md §4.
    public static let swap = ModifierMap(
        shift: .maskShift, control: .maskCommand, alt: .maskAlternate, win: .maskControl)

    /// Literal namesake mapping: Ctrl → ⌃ Control, Win → ⌘ Command, Alt → ⌥,
    /// Shift → ⇧. Predictable and terminal-friendly (`Ctrl+C` stays SIGINT) but
    /// `⌘C` requires `Win+C`. Selectable via `serve --namesake-modifiers`.
    public static let namesake = ModifierMap(
        shift: .maskShift, control: .maskControl, alt: .maskAlternate, win: .maskCommand)
}

/// The modifier **state machine** (issue #7): which modifier groups are currently
/// held. Pure and `Mac`-free, so it is unit tested without a display or AX.
///
/// The issue is explicit: *"Modifier state must be tracked, not inferred
/// per-event. A held Cmd across multiple keydowns has to stay held on the Mac
/// side."* So the host does not guess a chord from a single event — it observes
/// modifier key-down/up over time and stamps the resulting `CGEventFlags` onto
/// every event it posts (key **and** mouse). This type is that memory.
public struct ModifierState: Sendable, Equatable {
    private var held: Set<WinModifier> = []

    public init() {}

    /// Currently-held groups (for logging/tests).
    public var heldModifiers: Set<WinModifier> { held }

    /// Feed one raw key event. Returns `true` if `vk` was a modifier (state was
    /// updated and the caller should **not** post it as a character), `false` if
    /// it is an ordinary key the caller should translate + post.
    ///
    /// Making the is-it-a-modifier decision part of the state machine is what lets
    /// the whole chord path be tested from a VK sequence with no Mac in the loop.
    @discardableResult
    public mutating func apply(vk: UInt32, down: Bool) -> Bool {
        guard let modifier = Keymap.windowsModifier(forVK: vk) else { return false }
        if down {
            held.insert(modifier)
        } else {
            held.remove(modifier)
        }
        return true
    }

    /// The combined `CGEventFlags` for the currently-held modifiers under `map`,
    /// to stamp onto the next posted event.
    public func flags(using map: ModifierMap) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in held {
            flags.insert(map.flags(for: modifier))
        }
        return flags
    }

    /// Drop all held modifiers. Used when a client disconnects so a
    /// half-pressed ⌘ from a dropped session cannot wedge the next one.
    public mutating func reset() {
        held.removeAll()
    }
}
