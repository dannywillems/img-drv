//! A JSON value, and the canonical serialization `__structuredAttrs` uses.
//!
//! This is the first RECURSIVE type in the signature. Everything else is a
//! product of primitives and lists of them, which is what `docs/theory.md`
//! section 1 restricts the signature to; a JSON value is an inductive
//! datatype, a fixed point of a polynomial functor. Still first-order and
//! still algebraic, so the Lawvere argument survives, but it is a genuine
//! extension, and it is the place a language without sum types has to work
//! hardest.
//!
//! Written out rather than taking `serde_json`, for the same reason `sha2` is
//! the only dependency: the output is hashed into store paths, so the exact
//! byte form is part of this crate's contract and is better owned here than
//! inherited.

use std::collections::BTreeMap;
use std::fmt::Write as _;

/// A JSON value.
///
/// `Object` is a `BTreeMap`, so keys are sorted by construction, which is one
/// of the three canonical-form rules measured in `spec/canonical.md` 1.8.
#[derive(Clone, Debug, PartialEq)]
pub enum JsonValue {
    /// `null`.
    Null,
    /// `true` or `false`.
    Bool(bool),
    /// A 64-bit integer, which is what Nix integers are.
    Int(i64),
    /// A double.
    Float(f64),
    /// A string.
    String(String),
    /// An array, order significant.
    Array(Vec<JsonValue>),
    /// An object, keys sorted by construction.
    Object(BTreeMap<String, JsonValue>),
}

impl From<&str> for JsonValue {
    fn from(s: &str) -> Self {
        Self::String(s.to_owned())
    }
}

impl From<String> for JsonValue {
    fn from(s: String) -> Self {
        Self::String(s)
    }
}

impl From<bool> for JsonValue {
    fn from(b: bool) -> Self {
        Self::Bool(b)
    }
}

impl From<i64> for JsonValue {
    fn from(i: i64) -> Self {
        Self::Int(i)
    }
}

impl<T: Into<JsonValue>> From<Vec<T>> for JsonValue {
    fn from(v: Vec<T>) -> Self {
        Self::Array(v.into_iter().map(Into::into).collect())
    }
}

impl JsonValue {
    /// An object, built from pairs.
    pub fn object<K: Into<String>, V: Into<JsonValue>>(
        pairs: impl IntoIterator<Item = (K, V)>,
    ) -> Self {
        Self::Object(
            pairs
                .into_iter()
                .map(|(k, v)| (k.into(), v.into()))
                .collect(),
        )
    }

    /// The canonical serialization: sorted keys, compact separators, and
    /// non-ASCII emitted raw rather than `\uXXXX` escaped.
    ///
    /// All three hold on 456 of 456 structured derivations in a real closure.
    pub fn to_json(&self) -> String {
        let mut out = String::new();
        self.write(&mut out);
        out
    }

    fn write(&self, out: &mut String) {
        match self {
            Self::Null => out.push_str("null"),
            Self::Bool(true) => out.push_str("true"),
            Self::Bool(false) => out.push_str("false"),
            Self::Int(i) => {
                let _ = write!(out, "{i}");
            }
            Self::Float(f) => {
                // Match Python's repr-based output for the integral case,
                // which is what json.dumps produces and therefore what the
                // corpus was measured against.
                if f.fract() == 0.0 && f.is_finite() {
                    let _ = write!(out, "{f:.1}");
                } else {
                    let _ = write!(out, "{f}");
                }
            }
            Self::String(s) => escape_into(s, out),
            Self::Array(items) => {
                out.push('[');
                for (i, v) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    v.write(out);
                }
                out.push(']');
            }
            Self::Object(map) => {
                out.push('{');
                for (i, (k, v)) in map.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    escape_into(k, out);
                    out.push(':');
                    v.write(out);
                }
                out.push('}');
            }
        }
    }
}

/// JSON string escaping.
///
/// The five shorthand escapes plus `\b` and `\f`, `\u00XX` for the remaining
/// control characters, and every other character raw INCLUDING non-ASCII.
/// That last part is the `ensure_ascii=False` behaviour the corpus exhibits;
/// escaping non-ASCII would produce different bytes and a different store path.
fn escape_into(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}
