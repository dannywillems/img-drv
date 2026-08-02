//! img-drv: a content-addressed IR for reproducible build descriptions.
//!
//! Describe a build, compute its store paths, serialize it, and get bytes
//! identical to what Nix emits.
//!
//! ```
//! use img_drv::{Build, derivation, parse, unparse};
//!
//! let hello = derivation(Build {
//!     name: "hello".into(),
//!     system: "x86_64-linux".into(),
//!     builder: "/bin/sh".into(),
//!     args: vec!["-c".into(), "echo hi > $out".into()],
//!     ..Default::default()
//! })
//! .unwrap();
//!
//! // Canonical text round-trips exactly.
//! assert_eq!(unparse(&parse(&hello.aterm()).unwrap()), hello.aterm());
//! ```
//!
//! The public surface mirrors the Python reference implementation, and is
//! semver'd: a change to the bytes any of these produce is a MAJOR change,
//! because the bytes are the artifact.

#![deny(warnings)]
#![deny(missing_docs)]
// The README's examples are compiled and run as doctests, so they cannot rot
// into documentation that no longer describes the crate.
#![doc = include_str!("../README.md")]

pub mod aterm;
pub mod corpus;
pub mod derivation;
pub mod edsl;
pub mod examples;
pub mod json;
pub mod nar;
pub mod nix;
pub mod store;

pub use aterm::{ParseError, Serialize, escape, parse, quote, unparse, unparse_with};
pub use corpus::{Corpus, LoadError, Mismatch, name_from_path};
pub use derivation::{Derivation, InputDrv, Output, OutputName, Sha256Hex, StorePath};
pub use edsl::{
    Build, Dep, Drv, FixedOutput, HashAlgo, HashMode, InvalidDerivation, canonical, derivation,
    valid_name,
};
pub use json::JsonValue;
pub use store::{
    BASE32_ALPHABET, Base32Error, STORE, base32, base32_decode, base32_length, compress, drv_path,
    fixed_output_input_hash, fixed_output_path, output_paths, output_store_name, sha256_hex,
    store_path,
};
