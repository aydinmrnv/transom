//! A tiny, dependency-free JSON reader/writer, scoped to exactly what the Transom
//! control channel needs (protocol.md §4).
//!
//! Why hand-rolled and not `serde_json`: the client's dependency budget is
//! deliberately "`windows` plus a manifest embedder, ask before adding others"
//! (invariants I-8, client `AGENTS.md`). The control protocol is a fixed, tiny set
//! of flat JSON objects, so a purpose-built parser is small, has no supply chain,
//! and — being pure Rust with no `windows-rs` — compiles and unit-tests on any
//! host, not just Windows. That last property is what lets the wire layer be
//! verified against the real Swift host on a Mac.
//!
//! It is a conformant-enough reader for what the host emits (Swift's
//! `JSONEncoder`): full string escapes including `\uXXXX` surrogate pairs, and
//! integers kept as their exact source text so a `u64` window id never round-trips
//! through `f64`.

use std::fmt::Write as _;

/// A parsed JSON value. Objects keep insertion order (a `Vec` of pairs) because
/// the messages are small and order sometimes aids debugging; lookups are linear.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Null,
    Bool(bool),
    /// The number's exact source text, converted to a concrete integer type only
    /// at the field accessor. Keeps `u64` ids exact.
    Num(String),
    Str(String),
    Array(Vec<Value>),
    Object(Vec<(String, Value)>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JsonError {
    pub message: String,
    pub at: usize,
}

impl std::fmt::Display for JsonError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "JSON error at byte {}: {}", self.at, self.message)
    }
}

impl std::error::Error for JsonError {}

impl Value {
    /// Parse a whole JSON document. Trailing whitespace is allowed; trailing
    /// non-whitespace is an error.
    pub fn parse(input: &str) -> Result<Value, JsonError> {
        let mut p = Parser {
            bytes: input.as_bytes(),
            pos: 0,
        };
        p.skip_ws();
        let value = p.parse_value()?;
        p.skip_ws();
        if p.pos != p.bytes.len() {
            return Err(p.err("trailing characters after JSON value"));
        }
        Ok(value)
    }

    // --- typed accessors -------------------------------------------------

    /// Look up a key in an object, or `None` if this isn't an object / no key.
    pub fn get(&self, key: &str) -> Option<&Value> {
        match self {
            Value::Object(fields) => fields.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Value::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&[Value]> {
        match self {
            Value::Array(items) => Some(items),
            _ => None,
        }
    }

    pub fn as_u64(&self) -> Option<u64> {
        match self {
            Value::Num(text) => text.parse::<u64>().ok(),
            _ => None,
        }
    }

    pub fn as_u32(&self) -> Option<u32> {
        match self {
            Value::Num(text) => text.parse::<u32>().ok(),
            _ => None,
        }
    }

    // Used by the scroll-delta decode path and the JSON tests; not referenced on
    // a Windows-only build where those tests don't compile.
    #[allow(dead_code)]
    pub fn as_i32(&self) -> Option<i32> {
        match self {
            Value::Num(text) => text.parse::<i32>().ok(),
            _ => None,
        }
    }

    // --- serialization ---------------------------------------------------

    /// Serialize to compact JSON (no insignificant whitespace), matching the
    /// host's `JSONEncoder` default output closely enough to be byte-comparable
    /// for the messages we emit.
    pub fn to_json(&self) -> String {
        let mut out = String::new();
        self.write(&mut out);
        out
    }

    fn write(&self, out: &mut String) {
        match self {
            Value::Null => out.push_str("null"),
            Value::Bool(true) => out.push_str("true"),
            Value::Bool(false) => out.push_str("false"),
            Value::Num(text) => out.push_str(text),
            Value::Str(s) => write_escaped(s, out),
            Value::Array(items) => {
                out.push('[');
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    item.write(out);
                }
                out.push(']');
            }
            Value::Object(fields) => {
                out.push('{');
                for (i, (k, v)) in fields.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    write_escaped(k, out);
                    out.push(':');
                    v.write(out);
                }
                out.push('}');
            }
        }
    }
}

/// Small builder helpers so message encoders read declaratively.
impl Value {
    pub fn str(s: impl Into<String>) -> Value {
        Value::Str(s.into())
    }
    pub fn uint(n: u64) -> Value {
        Value::Num(n.to_string())
    }
    pub fn int(n: i64) -> Value {
        Value::Num(n.to_string())
    }
    pub fn object(fields: Vec<(&str, Value)>) -> Value {
        Value::Object(fields.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
    }
}

fn write_escaped(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0C}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

struct Parser<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn err(&self, message: impl Into<String>) -> JsonError {
        JsonError {
            message: message.into(),
            at: self.pos,
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn skip_ws(&mut self) {
        while let Some(b) = self.peek() {
            if b == b' ' || b == b'\t' || b == b'\n' || b == b'\r' {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn parse_value(&mut self) -> Result<Value, JsonError> {
        match self.peek() {
            Some(b'{') => self.parse_object(),
            Some(b'[') => self.parse_array(),
            Some(b'"') => Ok(Value::Str(self.parse_string()?)),
            Some(b't') => self.parse_lit("true", Value::Bool(true)),
            Some(b'f') => self.parse_lit("false", Value::Bool(false)),
            Some(b'n') => self.parse_lit("null", Value::Null),
            Some(b'-') | Some(b'0'..=b'9') => self.parse_number(),
            _ => Err(self.err("expected a JSON value")),
        }
    }

    fn parse_lit(&mut self, lit: &str, value: Value) -> Result<Value, JsonError> {
        let end = self.pos + lit.len();
        if self.bytes.get(self.pos..end) == Some(lit.as_bytes()) {
            self.pos = end;
            Ok(value)
        } else {
            Err(self.err(format!("expected `{lit}`")))
        }
    }

    fn parse_number(&mut self) -> Result<Value, JsonError> {
        let start = self.pos;
        if self.peek() == Some(b'-') {
            self.pos += 1;
        }
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.pos += 1;
        }
        // Fraction / exponent: accepted and preserved verbatim so we don't reject
        // a well-formed number, even though the protocol only sends integers.
        if self.peek() == Some(b'.') {
            self.pos += 1;
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.pos += 1;
            }
        }
        if matches!(self.peek(), Some(b'e') | Some(b'E')) {
            self.pos += 1;
            if matches!(self.peek(), Some(b'+') | Some(b'-')) {
                self.pos += 1;
            }
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.pos += 1;
            }
        }
        if self.pos == start {
            return Err(self.err("invalid number"));
        }
        // Safe: the number grammar above only accepts ASCII bytes.
        let text = std::str::from_utf8(&self.bytes[start..self.pos])
            .unwrap()
            .to_string();
        Ok(Value::Num(text))
    }

    fn parse_string(&mut self) -> Result<String, JsonError> {
        debug_assert_eq!(self.peek(), Some(b'"'));
        self.pos += 1; // opening quote
        let mut out = String::new();
        loop {
            let b = self.peek().ok_or_else(|| self.err("unterminated string"))?;
            match b {
                b'"' => {
                    self.pos += 1;
                    return Ok(out);
                }
                b'\\' => {
                    self.pos += 1;
                    self.parse_escape(&mut out)?;
                }
                // A raw control character is invalid in a JSON string.
                0x00..=0x1F => return Err(self.err("control character in string")),
                // Any other byte is part of a UTF-8 sequence; copy the whole
                // code point through so multibyte characters survive intact.
                _ => {
                    let ch = self.next_utf8_char()?;
                    out.push(ch);
                }
            }
        }
    }

    /// Decode one already-`\`-consumed escape sequence into `out`.
    fn parse_escape(&mut self, out: &mut String) -> Result<(), JsonError> {
        let b = self.peek().ok_or_else(|| self.err("unterminated escape"))?;
        self.pos += 1;
        match b {
            b'"' => out.push('"'),
            b'\\' => out.push('\\'),
            b'/' => out.push('/'),
            b'b' => out.push('\u{08}'),
            b'f' => out.push('\u{0C}'),
            b'n' => out.push('\n'),
            b'r' => out.push('\r'),
            b't' => out.push('\t'),
            b'u' => {
                let cp = self.parse_hex4()?;
                if (0xD800..=0xDBFF).contains(&cp) {
                    // High surrogate: must be followed by a low surrogate.
                    if self.peek() != Some(b'\\') {
                        return Err(self.err("unpaired high surrogate"));
                    }
                    self.pos += 1;
                    if self.peek() != Some(b'u') {
                        return Err(self.err("unpaired high surrogate"));
                    }
                    self.pos += 1;
                    let low = self.parse_hex4()?;
                    if !(0xDC00..=0xDFFF).contains(&low) {
                        return Err(self.err("invalid low surrogate"));
                    }
                    let c = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                    out.push(
                        char::from_u32(c).ok_or_else(|| self.err("invalid surrogate pair"))?,
                    );
                } else if (0xDC00..=0xDFFF).contains(&cp) {
                    return Err(self.err("unexpected low surrogate"));
                } else {
                    out.push(char::from_u32(cp).ok_or_else(|| self.err("invalid \\u escape"))?);
                }
            }
            _ => return Err(self.err("invalid escape")),
        }
        Ok(())
    }

    fn parse_hex4(&mut self) -> Result<u32, JsonError> {
        let slice = self
            .bytes
            .get(self.pos..self.pos + 4)
            .ok_or_else(|| self.err("truncated \\u escape"))?;
        let mut value = 0u32;
        for &b in slice {
            let digit = match b {
                b'0'..=b'9' => (b - b'0') as u32,
                b'a'..=b'f' => (b - b'a' + 10) as u32,
                b'A'..=b'F' => (b - b'A' + 10) as u32,
                _ => return Err(self.err("invalid hex digit in \\u escape")),
            };
            value = value * 16 + digit;
        }
        self.pos += 4;
        Ok(value)
    }

    /// Consume one UTF-8 encoded code point starting at `pos`.
    fn next_utf8_char(&mut self) -> Result<char, JsonError> {
        let rest = &self.bytes[self.pos..];
        // Decode via `str` to stay correct without hand-rolling UTF-8.
        let s = std::str::from_utf8(rest).map_err(|e| {
            // Take just the valid prefix so a single bad byte gives a precise error.
            let valid = e.valid_up_to();
            JsonError {
                message: "invalid UTF-8 in string".to_string(),
                at: self.pos + valid,
            }
        })?;
        let ch = s.chars().next().ok_or_else(|| self.err("unexpected end"))?;
        self.pos += ch.len_utf8();
        Ok(ch)
    }

    fn parse_array(&mut self) -> Result<Value, JsonError> {
        self.pos += 1; // '['
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(Value::Array(items));
        }
        loop {
            self.skip_ws();
            items.push(self.parse_value()?);
            self.skip_ws();
            match self.peek() {
                Some(b',') => {
                    self.pos += 1;
                }
                Some(b']') => {
                    self.pos += 1;
                    return Ok(Value::Array(items));
                }
                _ => return Err(self.err("expected `,` or `]` in array")),
            }
        }
    }

    fn parse_object(&mut self) -> Result<Value, JsonError> {
        self.pos += 1; // '{'
        let mut fields = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(Value::Object(fields));
        }
        loop {
            self.skip_ws();
            if self.peek() != Some(b'"') {
                return Err(self.err("expected string key in object"));
            }
            let key = self.parse_string()?;
            self.skip_ws();
            if self.peek() != Some(b':') {
                return Err(self.err("expected `:` after object key"));
            }
            self.pos += 1;
            self.skip_ws();
            let value = self.parse_value()?;
            fields.push((key, value));
            self.skip_ws();
            match self.peek() {
                Some(b',') => {
                    self.pos += 1;
                }
                Some(b'}') => {
                    self.pos += 1;
                    return Ok(Value::Object(fields));
                }
                _ => return Err(self.err("expected `,` or `}` in object")),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_flat_object() {
        let v = Value::parse(r#"{"type":"windowMoved","id":1,"rect":{"x":2300,"y":500}}"#).unwrap();
        assert_eq!(v.get("type").and_then(Value::as_str), Some("windowMoved"));
        assert_eq!(v.get("id").and_then(Value::as_u64), Some(1));
        assert_eq!(
            v.get("rect").and_then(|r| r.get("x")).and_then(Value::as_u32),
            Some(2300)
        );
    }

    #[test]
    fn keeps_u64_ids_exact() {
        // Beyond f64's integer range: proves we don't round-trip through f64.
        let v = Value::parse(r#"{"id":9007199254740993}"#).unwrap();
        assert_eq!(v.get("id").and_then(Value::as_u64), Some(9_007_199_254_740_993));
    }

    #[test]
    fn parses_signed_numbers() {
        let v = Value::parse(r#"{"dx":-3,"dy":7}"#).unwrap();
        assert_eq!(v.get("dx").and_then(Value::as_i32), Some(-3));
        assert_eq!(v.get("dy").and_then(Value::as_i32), Some(7));
    }

    #[test]
    fn parses_string_escapes() {
        let v = Value::parse(r#"{"t":"a\"b\\c\n\td\/e"}"#).unwrap();
        assert_eq!(v.get("t").and_then(Value::as_str), Some("a\"b\\c\n\td/e"));
    }

    #[test]
    fn parses_unicode_escape_and_surrogate_pair() {
        let v = Value::parse(r#"{"t":"é😀"}"#).unwrap();
        assert_eq!(v.get("t").and_then(Value::as_str), Some("é😀"));
    }

    #[test]
    fn preserves_raw_utf8() {
        let v = Value::parse(r#"{"t":"café — 世界"}"#).unwrap();
        assert_eq!(v.get("t").and_then(Value::as_str), Some("café — 世界"));
    }

    #[test]
    fn parses_arrays_and_empty_containers() {
        let v = Value::parse(r#"{"windows":[{"id":1},{"id":2}],"empty":[],"o":{}}"#).unwrap();
        let arr = v.get("windows").and_then(Value::as_array).unwrap();
        assert_eq!(arr.len(), 2);
        assert_eq!(arr[1].get("id").and_then(Value::as_u64), Some(2));
        assert_eq!(v.get("empty").and_then(Value::as_array).unwrap().len(), 0);
    }

    #[test]
    fn rejects_trailing_garbage() {
        assert!(Value::parse(r#"{"a":1} x"#).is_err());
        assert!(Value::parse(r#"{"a":}"#).is_err());
        assert!(Value::parse(r#"{"a":1,}"#).is_err());
    }

    #[test]
    fn round_trips_via_builder() {
        let v = Value::object(vec![
            ("type", Value::str("requestFocus")),
            ("id", Value::uint(7)),
        ]);
        assert_eq!(v.to_json(), r#"{"type":"requestFocus","id":7}"#);
    }

    #[test]
    fn escapes_on_write() {
        let v = Value::object(vec![("t", Value::str("a\"b\nc"))]);
        assert_eq!(v.to_json(), r#"{"t":"a\"b\nc"}"#);
    }

    #[test]
    fn reparses_what_it_writes() {
        let original = r#"{"type":"input","id":7,"event":{"kind":"mouseDown","x":400,"y":300,"button":"left"},"ts":12897}"#;
        let v = Value::parse(original).unwrap();
        let reparsed = Value::parse(&v.to_json()).unwrap();
        assert_eq!(v, reparsed);
    }
}
