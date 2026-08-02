//! NAR: the Nix Archive format, and the store path of a source.
//!
//! The last unspecified corner of the format (`docs/spec/canonical.md` section
//! 3), and the one half of the `.drv` references rule that nothing we produced
//! could exercise: a derivation's fingerprint lists its `inputDrvs` AND its
//! `inputSrcs`, and until now every derivation we built had an empty
//! `inputSrcs`.
//!
//! # The format
//!
//! NAR is a CANONICAL serialization of a filesystem object, and canonical is
//! the whole point: two directories with the same contents serialize to the
//! same bytes regardless of inode order, mtimes, ownership, or permissions
//! beyond one bit. Everything a filesystem records that is not content is
//! deliberately discarded.
//!
//! The grammar, from the Nix thesis (Dolstra 2006, figure 5.2):
//!
//! ```text
//! serialise(fso)  = str("nix-archive-1") ++ node(fso)
//! node(fso)       = str("(") ++ body(fso) ++ str(")")
//!
//! body(Regular)   = str("type") str("regular")
//!                   [ str("executable") str("") ]
//!                   str("contents") str(contents)
//! body(Symlink)   = str("type") str("symlink") str("target") str(target)
//! body(Directory) = str("type") str("directory") entry*
//!
//! entry           = str("entry") str("(") str("name") str(name)
//!                   str("node") node str(")")
//!
//! str(s)          = int(len s) ++ s ++ zero padding to a multiple of 8
//! int(n)          = 8 bytes, little endian
//! ```
//!
//! Three details decide whether an implementation is right, and all three are
//! invisible in a happy-path test: entries sort BYTE-wise rather than by
//! locale; the executable BIT is the only permission kept and is encoded as the
//! PRESENCE of a field; and padding to eight bytes adds NOTHING when the length
//! is already aligned rather than a full block.
//!
//! # Why this takes a TREE and not a path
//!
//! A filesystem object is an inductive type, the initial algebra of
//!
//! ```text
//! F(X) = (contents x executable) + target + (name x X)*
//! ```
//!
//! and NAR is the unique homomorphism out of it into bytes: a CATAMORPHISM.
//! Writing it that way rather than as a directory walk keeps the crate free of
//! filesystem code, makes the serializer testable without a filesystem, and
//! puts the part that decides the BYTES where it can be read.
//!
//! # The store path
//!
//! A source added to the store is the `source` kind of
//! `docs/spec/store-paths.md`, with the NAR's sha256 as the inner hash, and it
//! takes the SAME references treatment as a `.drv`: the kind becomes
//! `source:<ref>:<ref>:...`. That is `makeType` in Nix, shared by both, which
//! is why getting it wrong for `text` got it wrong for `source` too.

use sha2::{Digest, Sha256};

use crate::derivation::{Sha256Hex, StorePath};
use crate::store::store_path;

/// A filesystem object, as NAR understands one.
///
/// Note what is ABSENT: mtimes, ownership, and every permission but one. NAR
/// does not discard them as an optimisation; a format that kept them could not
/// be canonical.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Fso {
    /// A file. The executable bit is the only permission NAR keeps.
    Regular {
        /// The file's bytes.
        contents: Vec<u8>,
        /// Whether any execute bit was set.
        executable: bool,
    },
    /// A symbolic link, stored as its target text.
    Symlink(String),
    /// A directory. Entries are sorted at serialization time.
    Directory(Vec<(String, Fso)>),
}

/// Zero-pad to a multiple of eight, adding NOTHING when already aligned.
fn pad(out: &mut Vec<u8>, len: usize) {
    let remainder = len % 8;
    if remainder != 0 {
        out.extend(std::iter::repeat_n(0u8, 8 - remainder));
    }
}

fn put(out: &mut Vec<u8>, bytes: &[u8]) {
    out.extend_from_slice(&(bytes.len() as u64).to_le_bytes());
    out.extend_from_slice(bytes);
    pad(out, bytes.len());
}

fn node(out: &mut Vec<u8>, fso: &Fso) {
    put(out, b"(");
    match fso {
        Fso::Symlink(target) => {
            put(out, b"type");
            put(out, b"symlink");
            put(out, b"target");
            put(out, target.as_bytes());
        }
        Fso::Directory(entries) => {
            put(out, b"type");
            put(out, b"directory");
            // Sorted BY BYTES. A locale-aware sort produces a different archive
            // and therefore a different store path, for the same directory.
            let mut sorted: Vec<&(String, Fso)> = entries.iter().collect();
            sorted.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
            for (name, child) in sorted {
                put(out, b"entry");
                put(out, b"(");
                put(out, b"name");
                put(out, name.as_bytes());
                put(out, b"node");
                node(out, child);
                put(out, b")");
            }
        }
        Fso::Regular {
            contents,
            executable,
        } => {
            put(out, b"type");
            put(out, b"regular");
            // The executable bit is the ONLY permission NAR keeps, and it is
            // encoded as a present-or-absent FIELD rather than as a value.
            if *executable {
                put(out, b"executable");
                put(out, b"");
            }
            put(out, b"contents");
            put(out, contents);
        }
    }
    put(out, b")");
}

/// A filesystem object, serialized to its canonical NAR bytes.
pub fn nar(fso: &Fso) -> Vec<u8> {
    let mut out = Vec::with_capacity(4096);
    put(&mut out, b"nix-archive-1");
    node(&mut out, fso);
    out
}

/// The sha256 of the NAR, as 64 lowercase hex characters.
pub fn nar_hash(fso: &Fso) -> Sha256Hex {
    let mut hasher = Sha256::new();
    hasher.update(nar(fso));
    Sha256Hex::new(format!("{:x}", hasher.finalize()))
}

/// The store path a source lands at, as `nix-store --add` computes it.
///
/// `references` take the same treatment as a `.drv`'s: sorted, joined with
/// colons, and appended to the kind.
pub fn source_path(fso: &Fso, name: &str, references: &[String]) -> StorePath {
    let mut refs: Vec<&str> = references.iter().map(String::as_str).collect();
    refs.sort_unstable();
    refs.dedup();
    let kind = if refs.is_empty() {
        "source".to_string()
    } else {
        format!("source:{}", refs.join(":"))
    };
    store_path(&kind, &nar_hash(fso), name)
}
