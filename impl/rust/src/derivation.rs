//! The derivation types.
//!
//! These are the carrier of the whole crate: everything else parses into them,
//! serializes out of them, or hashes them.
//!
//! The newtypes are not decoration, and here they are load-bearing in a way
//! Python's `NewType` cannot be. A store path, a hex digest and an output name
//! are all strings at runtime, and confusing them is exactly the class of bug
//! this project has already paid for once: a derivation's own path and the hash
//! by which it is known as an input are both 64-character strings, and swapping
//! them yields a plausible wrong answer rather than an error. In Python that
//! confusion is caught only by `mypy`; here it does not typecheck at all, which
//! is one row of the typing table in `README.md`.
//!
//! Note what is deliberately NOT strongly typed: `Output::hash_algo` is a
//! `String`, not the [`HashAlgo`](crate::HashAlgo) enum. The wire type has to
//! round-trip whatever real Nix wrote, so parsing must be TOTAL; strictness
//! belongs on the construction side, in [`crate::edsl`].

use std::collections::BTreeSet;
use std::fmt;

/// A macro for the string newtypes, so the boilerplate is written once.
macro_rules! string_newtype {
    ($(#[$meta:meta])* $name:ident) => {
        $(#[$meta])*
        #[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
        pub struct $name(String);

        impl $name {
            /// Wrap a string. Deliberately explicit: this is the one place the
            /// distinction between these types can be lost.
            pub fn new(s: impl Into<String>) -> Self {
                Self(s.into())
            }

            /// The underlying string.
            pub fn as_str(&self) -> &str {
                &self.0
            }

            /// Consume and return the underlying string.
            pub fn into_string(self) -> String {
                self.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&self.0)
            }
        }

        impl From<&str> for $name {
            fn from(s: &str) -> Self {
                Self(s.to_owned())
            }
        }

        impl From<String> for $name {
            fn from(s: String) -> Self {
                Self(s)
            }
        }

        impl AsRef<str> for $name {
            fn as_ref(&self) -> &str {
                &self.0
            }
        }
    };
}

string_newtype! {
    /// An absolute path in the store, e.g. `/nix/store/<32 chars>-hello`.
    StorePath
}

string_newtype! {
    /// A sha256 digest as 64 lowercase hex characters.
    Sha256Hex
}

string_newtype! {
    /// The name of one output of a derivation: `out`, `dev`, `lib`, ...
    OutputName
}

/// One output of a derivation.
///
/// `hash_algo` and `hash` are empty for an ordinary derivation. When they are
/// set the derivation is FIXED-OUTPUT: it declares its result in advance, so
/// its identity comes from the declared hash rather than from how it is built.
/// That is the escape hatch that lets a build fetch from the network while
/// staying reproducible.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub struct Output {
    /// The output's name: `out`, `dev`, `lib`, ...
    pub name: OutputName,
    /// The store path this output will occupy.
    pub path: StorePath,
    /// Empty, or the ingestion method and algorithm (`sha256`, `r:sha256`).
    /// A `String` and not an enum on purpose: parsing must be total.
    pub hash_algo: String,
    /// Empty, or the declared hash as lowercase hex.
    pub hash: String,
}

impl Output {
    /// Whether this output declares its content hash in advance.
    pub fn fixed(&self) -> bool {
        !self.hash_algo.is_empty()
    }
}

/// A dependency on specific outputs of another derivation.
///
/// Depending on `dev` alone is a real and common case, so the set of needed
/// output names belongs to the EDGE rather than to the target.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub struct InputDrv {
    /// The `.drv` path of the derivation depended on.
    pub path: StorePath,
    /// The outputs of it that are actually needed.
    pub outputs: Vec<OutputName>,
}

/// A build description: the seven fields of the `Derive(...)` form.
///
/// Field order is the serialization order and is load-bearing. See
/// `docs/spec/canonical.md`.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Derivation {
    /// This derivation's own outputs, sorted by name when canonical.
    pub outputs: Vec<Output>,
    /// Edges to other derivations, sorted by store path when canonical.
    pub input_drvs: Vec<InputDrv>,
    /// Store paths used directly as sources, sorted when canonical.
    pub input_srcs: Vec<StorePath>,
    /// The platform to build on, e.g. `x86_64-linux`.
    pub system: String,
    /// The program to run.
    pub builder: String,
    /// Arguments to the builder. Order is the MEANING and is never sorted.
    pub args: Vec<String>,
    /// Environment entries, sorted by key when canonical.
    pub env: Vec<(String, String)>,
}

impl Derivation {
    /// The names of this derivation's own outputs.
    ///
    /// Used when masking: an env entry is blanked when its KEY is one of these,
    /// never when an output path merely appears inside some value.
    pub fn output_names(&self) -> BTreeSet<&str> {
        self.outputs.iter().map(|o| o.name.as_str()).collect()
    }

    /// The fixed output, if this is a fixed-output derivation.
    pub fn fixed_output(&self) -> Option<&Output> {
        self.outputs.iter().find(|o| o.fixed())
    }

    /// The derivation name, from the `name` environment variable.
    ///
    /// Every derivation carries one, and it is what output store names are
    /// built from.
    pub fn name(&self) -> &str {
        self.env
            .iter()
            .find(|(k, _)| k == "name")
            .map(|(_, v)| v.as_str())
            .unwrap_or("")
    }
}
