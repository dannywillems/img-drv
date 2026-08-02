//! Store path computation.
//!
//! Verified against real derivations: 1259 of 1259 output paths across 805 real
//! nixpkgs derivations, plus 12 of 12 golden examples. The rules are written up
//! in `docs/spec/store-paths.md`, and the structure behind them (output paths
//! FACTOR through masking rather than solving a fixed point) in
//! `docs/theory.md` section 7.

use std::collections::BTreeMap;

use sha2::{Digest, Sha256};

use crate::aterm::{Serialize, unparse_with};
use crate::derivation::{Derivation, Output, OutputName, Sha256Hex, StorePath};

/// The store root every fingerprint is built against.
pub const STORE: &str = "/nix/store";

/// Nix's own base-32 alphabet.
///
/// Note the omissions: `e`, `o`, `u` and `t` are absent, so that no store path
/// can accidentally spell a word.
pub const BASE32_ALPHABET: &[u8; 32] = b"0123456789abcdfghijklmnpqrsvwxyz";

/// How many base-32 digits encode `size` bytes.
pub fn base32_length(size: usize) -> usize {
    (size * 8 - 1) / 5 + 1
}

/// Nix base-32: least significant digit first, five bits at a time.
///
/// Not RFC 4648. Digits are emitted from the END of the buffer backwards, which
/// is why a stock base-32 library produces a different string. This is the
/// first thing to check when a path is close but wrong.
pub fn base32(data: &[u8]) -> String {
    let length = base32_length(data.len());
    let mut out = String::with_capacity(length);
    for i in (0..length).rev() {
        let bit = i * 5;
        let (idx, offset) = (bit / 8, bit % 8);
        let mut c = data[idx] >> offset;
        // The `offset != 0` guard is not an optimisation. Python can write
        // this without it because its integers are unbounded, but here the
        // shift amount would be 8, which panics in debug and is MASKED to a
        // shift of 0 in release, quietly corrupting every digit that straddles
        // a byte boundary. A release-only wrong answer is the worst kind.
        if idx + 1 < data.len() && offset != 0 {
            c |= data[idx + 1] << (8 - offset);
        }
        out.push(BASE32_ALPHABET[(c & 0x1f) as usize] as char);
    }
    out
}

/// A base-32 string that is not a digest of the expected length.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Base32Error(
    /// Why the string is not a digest of the expected length.
    pub String,
);

impl std::fmt::Display for Base32Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Base32Error {}

/// The inverse of [`base32`].
///
/// Needed because real fixed-output derivations write their hash in base-32 (or
/// SRI) while the outputs tuple carries it as hex, so an implementation that
/// cannot decode cannot reproduce the bytes. `size` is the expected digest
/// length, which the encoding does not carry.
pub fn base32_decode(text: &str, size: usize) -> Result<Vec<u8>, Base32Error> {
    if text.len() != base32_length(size) {
        return Err(Base32Error(format!(
            "expected {} digits, got {}",
            base32_length(size),
            text.len()
        )));
    }
    let mut out = vec![0u8; size];
    for (n, c) in text.bytes().rev().enumerate() {
        let digit = BASE32_ALPHABET
            .iter()
            .position(|&a| a == c)
            .ok_or_else(|| Base32Error(format!("not a Nix base-32 digit: {:?}", c as char)))?
            as u16;
        let bit = n * 5;
        let (idx, offset) = (bit / 8, bit % 8);
        out[idx] |= ((digit << offset) & 0xff) as u8;
        let carry = (digit >> (8 - offset)) as u8;
        if idx + 1 < size {
            out[idx + 1] |= carry;
        } else if carry != 0 {
            return Err(Base32Error(
                "base-32 digits overflow the digest length".to_owned(),
            ));
        }
    }
    Ok(out)
}

/// XOR-fold a digest down to `size` bytes.
///
/// A store path carries 20 bytes, not 32, and the sha256 is folded rather than
/// truncated: byte `i` of the digest is XORed into byte `i mod size`.
/// Truncating gives a plausible-looking path that is wrong.
pub fn compress(h: &[u8], size: usize) -> Vec<u8> {
    let mut out = vec![0u8; size];
    for (i, b) in h.iter().enumerate() {
        out[i % size] ^= b;
    }
    out
}

/// The sha256 of a string, as 64 lowercase hex characters.
pub fn sha256_hex(s: &str) -> Sha256Hex {
    Sha256Hex::new(hex(&Sha256::digest(s.as_bytes())))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The outer step, shared by every kind of store path.
///
/// `fingerprint = "<kind>:sha256:<inner hex>:<store dir>:<name>"` and the path
/// is `<store dir>/<base32(compress(sha256(fingerprint)))>-<name>`.
///
/// Only `kind` and `inner` vary: `text` for a `.drv` file, `output:<name>` for
/// a build output, `source` for a file added directly to the store.
pub fn store_path(kind: &str, inner: &Sha256Hex, name: &str) -> StorePath {
    let fingerprint = format!("{kind}:sha256:{inner}:{STORE}:{name}");
    let digest = Sha256::digest(fingerprint.as_bytes());
    StorePath::new(format!("{STORE}/{}-{name}", base32(&compress(&digest, 20))))
}

/// The store path of a fixed-output derivation.
///
/// TWO schemes, selected by the ingestion method encoded in the algo field:
///
/// - `r:sha256`, recursive (NAR) ingestion with sha256, takes the `source` kind
///   and uses the declared hash DIRECTLY as the inner hash;
/// - everything else builds the usual `fixed:out:` fingerprint first.
///
/// Missing the first case costs exactly one path in a 226-derivation closure,
/// which is how it survived a corpus written by hand.
pub fn fixed_output_path(o: &Output, drv_name: &str) -> StorePath {
    if o.hash_algo == "r:sha256" {
        return store_path("source", &Sha256Hex::new(o.hash.clone()), drv_name);
    }
    let inner = sha256_hex(&format!("fixed:out:{}:{}:", o.hash_algo, o.hash));
    store_path("output:out", &inner, drv_name)
}

/// The hash by which a fixed-output derivation is known AS AN INPUT.
///
/// Note the trailing store path. This is NOT the string used to compute the
/// path itself, which ends at the colon; including the path there would be
/// circular.
///
/// Confusing the two is invisible until something DEPENDS on a fixed-output
/// derivation, because the derivation's own path still comes out right. It
/// accounted for every one of the 145 downstream failures in the first real
/// corpus: the fetches all verified, and everything below them did not.
pub fn fixed_output_input_hash(o: &Output) -> Sha256Hex {
    sha256_hex(&format!("fixed:out:{}:{}:{}", o.hash_algo, o.hash, o.path))
}

/// `out` keeps the plain name; every other output is suffixed.
///
/// Package `multi` with outputs `out`, `dev`, `lib` yields store names `multi`,
/// `multi-dev`, `multi-lib`.
pub fn output_store_name(drv_name: &str, output: &OutputName) -> String {
    if output.as_str() == "out" {
        drv_name.to_owned()
    } else {
        format!("{drv_name}-{output}")
    }
}

/// Every output path of a derivation.
///
/// The asymmetry that matters: mask MY outputs, because they are what is being
/// computed; do not mask my inputs'.
pub fn output_paths(
    drv: &Derivation,
    drv_name: &str,
    input_hashes: &BTreeMap<StorePath, String>,
) -> BTreeMap<OutputName, StorePath> {
    if let Some(fixed) = drv.fixed_output() {
        return BTreeMap::from([(fixed.name.clone(), fixed_output_path(fixed, drv_name))]);
    }
    let inner = sha256_hex(&unparse_with(
        drv,
        &Serialize {
            mask_outputs: true,
            input_hashes: Some(input_hashes),
        },
    ));
    drv.outputs
        .iter()
        .map(|o| {
            (
                o.name.clone(),
                store_path(
                    &format!("output:{}", o.name),
                    &inner,
                    &output_store_name(drv_name, &o.name),
                ),
            )
        })
        .collect()
}

/// The path of the `.drv` file itself: a `text` store object.
///
/// `references` are the store paths the file MENTIONS: its `inputDrvs` and its
/// `inputSrcs`. They are part of the fingerprint, sorted and inserted after
/// the `text` kind:
///
/// ```text
/// text:<ref>:<ref>:...:sha256:<inner>:<store dir>:<name>
/// ```
///
/// Omitting them is right for a derivation with no inputs and wrong for
/// everything else. Verified against 1458 real nixpkgs `.drv` files, which are
/// named by real Nix: 1458 of 1458 with references, 149 of 1458 without.
pub fn drv_path(aterm: &str, drv_name: &str, references: &[String]) -> StorePath {
    let mut refs: Vec<&str> = references.iter().map(String::as_str).collect();
    refs.sort_unstable();
    refs.dedup();
    let kind = if refs.is_empty() {
        "text".to_owned()
    } else {
        format!("text:{}", refs.join(":"))
    };
    store_path(&kind, &sha256_hex(aterm), &format!("{drv_name}.drv"))
}
