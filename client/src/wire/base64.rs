//! Bounded standard base64 for catalogue JPEGs. No new runtime dependency.
pub fn decode(input: &str) -> Option<Vec<u8>> {
    if input.len() > 172_000 || input.len() % 4 != 0 {
        return None;
    }
    fn digit(b: u8) -> Option<u8> {
        Some(match b {
            b'A'..=b'Z' => b - b'A',
            b'a'..=b'z' => b - b'a' + 26,
            b'0'..=b'9' => b - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        })
    }
    let mut out = Vec::with_capacity(input.len() / 4 * 3);
    for (i, c) in input.as_bytes().chunks_exact(4).enumerate() {
        let a = digit(c[0])?;
        let b = digit(c[1])?;
        out.push((a << 2) | (b >> 4));
        if c[2] == b'=' {
            if c[3] != b'=' || b & 15 != 0 || (i + 1) * 4 != input.len() {
                return None;
            }
        } else {
            let d = digit(c[2])?;
            out.push((b << 4) | (d >> 2));
            if c[3] == b'=' {
                if d & 3 != 0 || (i + 1) * 4 != input.len() {
                    return None;
                }
            } else {
                out.push((d << 6) | digit(c[3])?);
            }
        }
    }
    Some(out)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn decodes_swift_data_and_rejects_invalid_padding_or_large_data() {
        for (encoded, plain) in [("", ""), ("Zg==", "f"), ("Zm8=", "fo"), ("Zm9v", "foo")] {
            assert_eq!(decode(encoded).unwrap(), plain.as_bytes());
        }
        for bad in ["a", "====", "Zh==", "Zm9=", "Zg==Zg==", "Zm8*"] {
            assert!(decode(bad).is_none());
        }
        assert!(decode(&"A".repeat(172004)).is_none());
    }
}
