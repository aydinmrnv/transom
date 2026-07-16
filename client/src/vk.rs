//! Windows virtual-key codes.
//!
//! The client sends **raw Windows VK codes** on the wire (protocol.md §4); the
//! host owns the VK → macOS-keycode mapping and the Ctrl↔⌘ swap. On the real
//! Windows client the capture layer gets these codes straight from `WM_KEYDOWN`'s
//! `wParam`, so no table is needed there. This module exists mostly for the
//! headless runner's `--type` demo (turning an ASCII string into keystrokes to
//! prove the input path end-to-end against the live host) and to give the capture
//! layer a couple of named constants.
//!
//! Values are the standard `winuser.h` `VK_*` numbers; they are the same on every
//! Windows install and independent of `windows-rs`, so this stays pure.

// A reference table: not every constant is used by the current input paths, but
// keeping the full named set here is the point (it documents the codes the wire
// carries, and the Windows capture layer forwards raw VKs without needing them).
#![allow(dead_code)]

pub const VK_BACK: u32 = 0x08;
pub const VK_TAB: u32 = 0x09;
pub const VK_RETURN: u32 = 0x0D;
pub const VK_SHIFT: u32 = 0x10;
pub const VK_CONTROL: u32 = 0x11;
pub const VK_MENU: u32 = 0x12; // Alt
pub const VK_ESCAPE: u32 = 0x1B;
pub const VK_SPACE: u32 = 0x20;
pub const VK_LEFT: u32 = 0x25;
pub const VK_UP: u32 = 0x26;
pub const VK_RIGHT: u32 = 0x27;
pub const VK_DOWN: u32 = 0x28;
pub const VK_DELETE: u32 = 0x2E;
pub const VK_LWIN: u32 = 0x5B;

/// The VK code that produces `c` on a US/ANSI layout, if it is a single
/// unmodified key. Returns `None` for characters that need Shift or a dead key —
/// the caller can still send the Shift chord itself. Letters map to their
/// uppercase ASCII value (which is the VK code), digits to their ASCII value.
pub fn vk_for_ascii(c: char) -> Option<u32> {
    match c {
        'a'..='z' => Some(c.to_ascii_uppercase() as u32),
        'A'..='Z' => Some(c as u32),
        '0'..='9' => Some(c as u32),
        ' ' => Some(VK_SPACE),
        '\n' | '\r' => Some(VK_RETURN),
        '\t' => Some(VK_TAB),
        _ => None,
    }
}

/// Whether typing `c` on a US/ANSI layout requires holding Shift (an uppercase
/// letter). Used by the `--type` demo to bracket a keystroke in Shift.
pub fn needs_shift(c: char) -> bool {
    c.is_ascii_uppercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn letters_map_to_uppercase_ascii() {
        assert_eq!(vk_for_ascii('a'), Some(0x41));
        assert_eq!(vk_for_ascii('z'), Some(0x5A));
        assert_eq!(vk_for_ascii('A'), Some(0x41));
    }

    #[test]
    fn digits_and_whitespace() {
        assert_eq!(vk_for_ascii('0'), Some(0x30));
        assert_eq!(vk_for_ascii('9'), Some(0x39));
        assert_eq!(vk_for_ascii(' '), Some(VK_SPACE));
        assert_eq!(vk_for_ascii('\n'), Some(VK_RETURN));
    }

    #[test]
    fn uppercase_needs_shift() {
        assert!(needs_shift('A'));
        assert!(!needs_shift('a'));
        assert!(!needs_shift('1'));
    }

    #[test]
    fn unmapped_returns_none() {
        assert_eq!(vk_for_ascii('€'), None);
        assert_eq!(vk_for_ascii('!'), None);
    }
}
