//! The eDSL surface: DESCRIBE a build, and get a derivation back.
//!
//! ```
//! use img_drv::{Build, derivation};
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
//! assert_eq!(
//!     hello.output("out").unwrap().as_str(),
//!     "/nix/store/mjs27ix6ig2bkbi3s3sm470vrv4lf7ic-hello"
//! );
//! ```
//!
//! That path is Nix's, byte for byte, and it is known BEFORE anything is built.
//!
//! What this module adds over the raw [`Derivation`] record is exactly two
//! things: the CANONICAL form (which orderings are load-bearing), and the KNOT
//! (output paths are the hash of the derivation that contains them, resolved by
//! factoring rather than by iteration; see `docs/theory.md` section 7).
//!
//! Two deliberate differences from the Python reference, both forced by the
//! language and both recorded in the typing table in `README.md`:
//!
//! - `Build` is a struct with `..Default::default()` rather than keyword
//!   arguments. It is also the more honest translation, since the signature in
//!   `docs/spec/signature.md` IS a finite product.
//! - `Drv::needs` is Python's `Drv.ref`, renamed because `ref` is a keyword.
//!   There is no bare-derivation shorthand: converting a `Drv` to a `Dep`
//!   can fail when the target has no output named `out`, and `From` cannot
//!   fail without panicking.

use std::collections::{BTreeMap, BTreeSet};
use std::error::Error;
use std::fmt;
use std::io;
use std::path::{Path, PathBuf};

use crate::aterm::{Serialize, unparse, unparse_with};
use crate::derivation::{Derivation, InputDrv, Output, OutputName, Sha256Hex, StorePath};
use crate::json::JsonValue;
use crate::store::{
    base32_decode, base32_length, drv_path, fixed_output_input_hash, output_paths, sha256_hex,
};

/// The hash algorithms Nix accepts for a fixed-output derivation.
///
/// An enum, where Python has a `Literal`. The difference is real: Python's is
/// erased at runtime and needs a check on the way in, while an out-of-range
/// algorithm does not typecheck here at all.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum HashAlgo {
    /// MD5, 16 bytes. Present because Nix accepts it, not because it should
    /// be used.
    Md5,
    /// SHA-1, 20 bytes. Likewise.
    Sha1,
    /// SHA-256, 32 bytes. What every fixed-output derivation in the corpus
    /// uses.
    Sha256,
    /// SHA-512, 64 bytes.
    Sha512,
}

impl HashAlgo {
    /// The name as it appears in `outputHashAlgo`.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Md5 => "md5",
            Self::Sha1 => "sha1",
            Self::Sha256 => "sha256",
            Self::Sha512 => "sha512",
        }
    }

    /// The digest length in bytes, which the written hash does not carry.
    pub fn digest_bytes(self) -> usize {
        match self {
            Self::Md5 => 16,
            Self::Sha1 => 20,
            Self::Sha256 => 32,
            Self::Sha512 => 64,
        }
    }

    fn parse(text: &str) -> Option<Self> {
        match text {
            "md5" => Some(Self::Md5),
            "sha1" => Some(Self::Sha1),
            "sha256" => Some(Self::Sha256),
            "sha512" => Some(Self::Sha512),
            _ => None,
        }
    }
}

impl fmt::Display for HashAlgo {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// How the output is ingested: a single file, or a NAR of a directory tree.
///
/// `Recursive` is what puts the `r:` prefix on the serialized algorithm, and
/// `r:sha256` selects an entirely different store-path scheme.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum HashMode {
    /// A single file, hashed directly.
    #[default]
    Flat,
    /// A directory tree, hashed as a NAR. This is what puts `r:` on the
    /// serialized algorithm.
    Recursive,
}

impl HashMode {
    /// The value of the `outputHashMode` env entry.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Flat => "flat",
            Self::Recursive => "recursive",
        }
    }
}

/// A description that violates an invariant in `docs/spec/signature.md`.
///
/// Returned at CONSTRUCTION time. The alternative is a derivation that
/// serializes perfectly and means something else, which this project has
/// already paid for once.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InvalidDerivation {
    /// Not usable as a store path name.
    Name(String),
    /// `outputs` was empty.
    EmptyOutputs,
    /// The same output was named twice.
    DuplicateOutputs(Vec<String>),
    /// A fixed-output derivation must have exactly one output.
    FixedNeedsOneOutput(Vec<String>),
    /// Env keys that are derived from the other fields were supplied directly.
    ReservedEnvKeys(Vec<String>),
    /// An output was asked for that the derivation does not have.
    NoSuchOutput {
        /// The derivation that was asked.
        drv: String,
        /// The output name that was wanted.
        wanted: String,
        /// The outputs it actually has.
        have: Vec<String>,
    },
    /// A declared hash that could not be decoded.
    Hash(String),
    /// Non-string env values were supplied without `structured_attrs`.
    UntypedEnvNeedsStructuredAttrs(Vec<String>),
}

impl fmt::Display for InvalidDerivation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Name(n) => write!(
                f,
                "{n:?} is not a valid store path name (see spec/signature.md)"
            ),
            Self::EmptyOutputs => f.write_str("outputs must not be empty"),
            Self::DuplicateOutputs(n) => write!(f, "duplicate output names in {n:?}"),
            Self::FixedNeedsOneOutput(n) => write!(
                f,
                "a fixed-output derivation has exactly one output, got {n:?}"
            ),
            Self::ReservedEnvKeys(k) => write!(
                f,
                "env keys {k:?} are derived from the other fields; set them \
                 through name/system/builder/outputs/fixed_output"
            ),
            Self::NoSuchOutput { drv, wanted, have } => {
                write!(f, "{drv:?} has no output {wanted:?}; it has {have:?}")
            }
            Self::Hash(why) => f.write_str(why),
            Self::UntypedEnvNeedsStructuredAttrs(k) => write!(
                f,
                "env values {k:?} are not strings; the flat encoding can only \
                 carry strings, so set structured_attrs: true"
            ),
        }
    }
}

impl Error for InvalidDerivation {}

/// Nix's store-name length cap.
const NAME_MAX: usize = 211;

/// Whether `name` is usable as a store path name.
///
/// Accepts every name in the real corpus. That shows the predicate is not too
/// strict; it does not show it is not too permissive, which is why
/// `spec/signature.md` still lists the exact rules as open.
pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= NAME_MAX
        && name != "."
        && name != ".."
        && !name.starts_with('.')
        && name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"+-._?=".contains(&c))
}

/// A declared result: the derivation's identity comes from this hash.
///
/// `hash` is kept EXACTLY as written, because that is what reaches the env,
/// while the outputs tuple carries it re-encoded as hex. Both forms are in
/// `examples/fixed.drv`, and the rule is verified on all 93 fixed-output
/// derivations in the real corpus.
///
/// `algo` may be omitted when `hash` is SRI (`sha256-<base64>`), which already
/// names its algorithm. Real derivations do exactly that: 11 of the 93 carry no
/// `outputHashAlgo` at all.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FixedOutput {
    /// The hash EXACTLY as written; this is what reaches the env. Accepts
    /// hex, Nix base-32, base-64 and SRI.
    pub hash: String,
    /// The algorithm, or `None` when `hash` is SRI and names its own.
    pub algo: Option<HashAlgo>,
    /// Flat or recursive ingestion.
    pub mode: HashMode,
}

impl FixedOutput {
    /// A flat, non-SRI hash of a known algorithm.
    pub fn new(hash: impl Into<String>, algo: HashAlgo) -> Self {
        Self {
            hash: hash.into(),
            algo: Some(algo),
            mode: HashMode::Flat,
        }
    }

    /// An SRI hash (`sha256-<base64>`), which names its own algorithm.
    pub fn sri(hash: impl Into<String>) -> Self {
        Self {
            hash: hash.into(),
            algo: None,
            mode: HashMode::Flat,
        }
    }

    /// The same declaration, ingested recursively (as a NAR).
    pub fn recursive(mut self) -> Self {
        self.mode = HashMode::Recursive;
        self
    }

    /// `(algorithm, hex digest)`, decoded from whatever was written.
    ///
    /// Accepts hex, Nix base-32, base-64 and SRI. The corpus contains SRI and
    /// base-32 and no hex at all, so an implementation that accepts only hex
    /// parses nothing real.
    pub fn resolved(&self) -> Result<(HashAlgo, String), InvalidDerivation> {
        let (algo, raw) = if let Some((prefix, body)) = self.hash.split_once('-') {
            let algo = HashAlgo::parse(prefix).ok_or_else(|| {
                InvalidDerivation::Hash(format!("unknown hash algorithm {prefix:?}"))
            })?;
            if let Some(declared) = self.algo
                && declared != algo
            {
                return Err(InvalidDerivation::Hash(format!(
                    "algo={declared} contradicts the SRI prefix {prefix:?}"
                )));
            }
            (algo, b64_decode(body)?)
        } else {
            let algo = self.algo.ok_or_else(|| {
                InvalidDerivation::Hash(
                    "algo is required unless the hash is SRI (sha256-...)".to_owned(),
                )
            })?;
            let size = algo.digest_bytes();
            let raw = if self.hash.len() == size * 2 {
                hex_decode(&self.hash)?
            } else if self.hash.len() == base32_length(size) {
                base32_decode(&self.hash, size)
                    .map_err(|e| InvalidDerivation::Hash(e.to_string()))?
            } else {
                b64_decode(&self.hash)?
            };
            (algo, raw)
        };
        if raw.len() != algo.digest_bytes() {
            return Err(InvalidDerivation::Hash(format!(
                "{algo} needs {} bytes, got {}",
                algo.digest_bytes(),
                raw.len()
            )));
        }
        Ok((algo, raw.iter().map(|b| format!("{b:02x}")).collect()))
    }

    /// The serialized algorithm, with the `r:` prefix when recursive.
    pub fn hash_algo_field(&self) -> Result<String, InvalidDerivation> {
        let (algo, _) = self.resolved()?;
        Ok(match self.mode {
            HashMode::Recursive => format!("r:{algo}"),
            HashMode::Flat => algo.to_string(),
        })
    }

    /// The serialized hash: always lowercase hex.
    pub fn hash_field(&self) -> Result<String, InvalidDerivation> {
        Ok(self.resolved()?.1)
    }

    /// The env entries Nix synthesizes for a fixed-output derivation.
    ///
    /// `outputHashAlgo` is omitted for an SRI hash, matching what real Nix
    /// emits; writing it anyway would change the bytes.
    fn env(&self) -> BTreeMap<String, String> {
        let mut out = BTreeMap::from([
            ("outputHash".to_owned(), self.hash.clone()),
            ("outputHashMode".to_owned(), self.mode.as_str().to_owned()),
        ]);
        if let Some(algo) = self.algo {
            out.insert("outputHashAlgo".to_owned(), algo.as_str().to_owned());
        }
        out
    }
}

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn b64_decode(text: &str) -> Result<Vec<u8>, InvalidDerivation> {
    let bad = || InvalidDerivation::Hash(format!("not base-64: {text:?}"));
    let bytes = text.as_bytes();
    if bytes.is_empty() || !bytes.len().is_multiple_of(4) {
        return Err(bad());
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    let chunks: Vec<&[u8]> = bytes.chunks(4).collect();
    for (n, chunk) in chunks.iter().enumerate() {
        let last = n + 1 == chunks.len();
        let mut acc: u32 = 0;
        let mut pad = 0usize;
        for &c in chunk.iter() {
            acc <<= 6;
            if c == b'=' {
                if !last {
                    return Err(bad());
                }
                pad += 1;
            } else {
                if pad > 0 {
                    return Err(bad());
                }
                acc |= B64.iter().position(|&a| a == c).ok_or_else(bad)? as u32;
            }
        }
        if pad > 2 {
            return Err(bad());
        }
        let full = acc.to_be_bytes();
        out.extend_from_slice(&full[1..4 - pad]);
    }
    Ok(out)
}

fn hex_decode(text: &str) -> Result<Vec<u8>, InvalidDerivation> {
    let bad = || InvalidDerivation::Hash(format!("not hex: {text:?}"));
    if !text.len().is_multiple_of(2) {
        return Err(bad());
    }
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).map_err(|_| bad()))
        .collect()
}

/// An edge: a derivation, and the outputs of it actually needed.
///
/// The outputs belong to the EDGE rather than to the target, because two
/// dependents of one package routinely need different outputs of it, and
/// depending on `dev` alone is the common case in nixpkgs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Dep {
    path: StorePath,
    input_hash: Sha256Hex,
    outputs: Vec<OutputName>,
}

impl Dep {
    /// The `.drv` path of the derivation this edge points at.
    pub fn path(&self) -> &StorePath {
        &self.path
    }

    /// The outputs this edge needs.
    pub fn outputs(&self) -> &[OutputName] {
        &self.outputs
    }
}

/// A described derivation, and everything derivable from it.
///
/// `input_hash` is the hash by which this derivation is known when it is
/// someone ELSE's input, which is NOT the hash used to compute its own output
/// paths. Keeping both on the value is what lets a dependent be built without
/// re-walking the graph, and keeping them named apart is what stops them being
/// swapped.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Drv {
    derivation: Derivation,
    path: StorePath,
    input_hash: Sha256Hex,
}

impl Drv {
    /// The underlying derivation record.
    pub fn derivation(&self) -> &Derivation {
        &self.derivation
    }

    /// The path of the `.drv` file itself.
    pub fn path(&self) -> &StorePath {
        &self.path
    }

    /// The hash by which this derivation is known as someone else's input.
    pub fn input_hash(&self) -> &Sha256Hex {
        &self.input_hash
    }

    /// The derivation name, as it appears in store path suffixes.
    pub fn name(&self) -> &str {
        self.derivation.name()
    }

    /// Every output name mapped to the path it will occupy.
    pub fn outputs(&self) -> BTreeMap<&str, &StorePath> {
        self.derivation
            .outputs
            .iter()
            .map(|o| (o.name.as_str(), &o.path))
            .collect()
    }

    /// The path of one output, known before anything is built.
    pub fn output(&self, name: &str) -> Result<&StorePath, InvalidDerivation> {
        self.derivation
            .outputs
            .iter()
            .find(|o| o.name.as_str() == name)
            .map(|o| &o.path)
            .ok_or_else(|| InvalidDerivation::NoSuchOutput {
                drv: self.name().to_owned(),
                wanted: name.to_owned(),
                have: self.outputs().keys().map(|k| (*k).to_owned()).collect(),
            })
    }

    /// An edge to this derivation, needing `outputs` (empty means `out`).
    ///
    /// This is Python's `Drv.ref`; `ref` is a keyword here.
    pub fn needs(&self, outputs: &[&str]) -> Result<Dep, InvalidDerivation> {
        let wanted: Vec<&str> = if outputs.is_empty() {
            vec!["out"]
        } else {
            outputs.to_vec()
        };
        let mut names = BTreeSet::new();
        for n in wanted {
            self.output(n)?; // fail here rather than at build time
            names.insert(OutputName::new(n));
        }
        Ok(Dep {
            path: self.path.clone(),
            input_hash: self.input_hash.clone(),
            outputs: names.into_iter().collect(),
        })
    }

    /// The canonical bytes.
    ///
    /// These ARE the artifact: `path` is their hash, so a difference of one
    /// separator is a different derivation.
    pub fn aterm(&self) -> String {
        unparse(&self.derivation)
    }

    /// Write the `.drv` under `directory`, named as in the store.
    ///
    /// No trailing newline: the store object does not have one, and adding one
    /// would change the hash of anything that reads it back.
    pub fn write(&self, directory: &Path) -> io::Result<PathBuf> {
        let name = self
            .path
            .as_str()
            .rsplit('/')
            .next()
            .unwrap_or(self.path.as_str());
        let target = directory.join(name);
        std::fs::write(&target, self.aterm())?;
        Ok(target)
    }
}

/// Put a derivation into canonical form.
///
/// The orderings, all of which are load-bearing (`spec/canonical.md`): outputs
/// by name, env by key, `inputDrvs` by store path with each inner name list
/// sorted, `inputSrcs` ascending. `args` keeps its order, because there it is
/// the meaning.
///
/// This is idempotent, and it is the IDENTITY on every derivation real Nix
/// emits, which is the sense in which the form is canonical rather than merely
/// ours. Both are property-tested.
pub fn canonical(drv: &Derivation) -> Derivation {
    let mut outputs = drv.outputs.clone();
    outputs.sort_by(|a, b| a.name.cmp(&b.name));

    let mut input_drvs: Vec<InputDrv> = drv
        .input_drvs
        .iter()
        .map(|i| InputDrv {
            path: i.path.clone(),
            outputs: i
                .outputs
                .iter()
                .cloned()
                .collect::<BTreeSet<_>>()
                .into_iter()
                .collect(),
        })
        .collect();
    input_drvs.sort_by(|a, b| a.path.cmp(&b.path));

    let input_srcs: Vec<StorePath> = drv
        .input_srcs
        .iter()
        .cloned()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();

    let mut env = drv.env.clone();
    env.sort();

    Derivation {
        outputs,
        input_drvs,
        input_srcs,
        system: drv.system.clone(),
        builder: drv.builder.clone(),
        args: drv.args.clone(),
        env,
    }
}

/// A build description: the first-order signature, as a product.
///
/// `env` is a `BTreeMap` rather than a list of pairs, which makes two
/// invariants FREE rather than checked: keys are unique, and insertion order
/// cannot leak into the bytes. The Python reference needs a property test for
/// the second; here it is unrepresentable.
#[derive(Clone, Debug, Default)]
pub struct Build {
    /// The package name. Must be a valid store path name.
    pub name: String,
    /// The platform to build on, e.g. `x86_64-linux`.
    pub system: String,
    /// The program to run.
    pub builder: String,
    /// Arguments to the builder. Order is the meaning; it is never sorted.
    pub args: Vec<String>,
    /// Extra environment entries. The ones derived from the other fields
    /// (`name`, `system`, `builder`, `outputs`, the output names, and the
    /// `outputHash*` trio) are rejected here, because supplying one would let
    /// the env disagree with the field it mirrors.
    /// Values are [`JsonValue`] rather than `String` because `structured_attrs`
    /// can carry types. With it off, every value must be a
    /// [`JsonValue::String`]; anything else is refused, because the flat
    /// encoding cannot represent it.
    pub env: BTreeMap<String, JsonValue>,
    /// Select the SECOND env encoding (`spec/canonical.md` section 1.8):
    /// attributes carried as one `__json` entry with their types preserved,
    /// rather than one string-valued variable each. 1223 of 2516 real
    /// derivations use it.
    pub structured_attrs: bool,
    /// `None` and `Some(vec!["out"])` are DIFFERENT derivations with different
    /// store paths: Nix emits an `outputs` env variable exactly when the caller
    /// declared the attribute. Both occur in real nixpkgs. See
    /// `spec/canonical.md` section 1.7.
    pub outputs: Option<Vec<OutputName>>,
    /// Edges to other derivations, built with [`Drv::needs`].
    pub input_drvs: Vec<Dep>,
    /// Store paths used directly as sources.
    pub input_srcs: Vec<StorePath>,
    /// Set to declare the result in advance, making this a fixed-output
    /// derivation: the escape hatch that lets a build fetch from the network.
    pub fixed_output: Option<FixedOutput>,
}

/// Env keys derived from the other fields. Supplying one directly would let the
/// env disagree with the field it mirrors, which is a derivation Nix would
/// never emit.
const RESERVED: &[&str] = &[
    "name",
    "system",
    "builder",
    "outputs",
    "outputHash",
    "outputHashAlgo",
    "outputHashMode",
    "__json",
    "__structuredAttrs",
];

/// Describe a build. This is the whole eDSL.
///
/// # Errors
///
/// Returns [`InvalidDerivation`] if any invariant in `spec/signature.md` fails.
pub fn derivation(b: Build) -> Result<Drv, InvalidDerivation> {
    if !valid_name(&b.name) {
        return Err(InvalidDerivation::Name(b.name));
    }

    let declared = b.outputs.is_some();
    let names: Vec<OutputName> = b
        .outputs
        .clone()
        .unwrap_or_else(|| vec![OutputName::new("out")]);
    if names.is_empty() {
        return Err(InvalidDerivation::EmptyOutputs);
    }
    let as_strings = || names.iter().map(|n| n.to_string()).collect::<Vec<_>>();
    if names.iter().collect::<BTreeSet<_>>().len() != names.len() {
        return Err(InvalidDerivation::DuplicateOutputs(as_strings()));
    }
    for n in &names {
        if !valid_name(n.as_str()) {
            return Err(InvalidDerivation::Name(n.to_string()));
        }
    }
    if b.fixed_output.is_some() && names.len() != 1 {
        return Err(InvalidDerivation::FixedNeedsOneOutput(as_strings()));
    }

    let reserved: BTreeSet<&str> = RESERVED
        .iter()
        .copied()
        .chain(names.iter().map(|n| n.as_str()))
        .collect();
    let clashes: Vec<String> = b
        .env
        .keys()
        .filter(|k| reserved.contains(k.as_str()))
        .cloned()
        .collect();
    if !clashes.is_empty() {
        return Err(InvalidDerivation::ReservedEnvKeys(clashes));
    }

    if !b.structured_attrs {
        let untyped: Vec<String> = b
            .env
            .iter()
            .filter(|(_, v)| !matches!(v, JsonValue::String(_)))
            .map(|(k, _)| k.clone())
            .collect();
        if !untyped.is_empty() {
            return Err(InvalidDerivation::UntypedEnvNeedsStructuredAttrs(untyped));
        }
    }

    let mut env: BTreeMap<String, String> = BTreeMap::new();
    if b.structured_attrs {
        // One __json entry carrying every attribute WITH ITS TYPE, plus one
        // entry per output. The output paths stay OUTSIDE the JSON, which is
        // why masking needs no special case. See spec/canonical.md 1.8.
        let mut attrs = b.env.clone();
        attrs.insert("name".to_owned(), JsonValue::String(b.name.clone()));
        attrs.insert("system".to_owned(), JsonValue::String(b.system.clone()));
        attrs.insert("builder".to_owned(), JsonValue::String(b.builder.clone()));
        if declared {
            attrs.insert(
                "outputs".to_owned(),
                JsonValue::Array(
                    names
                        .iter()
                        .map(|n| JsonValue::String(n.to_string()))
                        .collect(),
                ),
            );
        }
        if let Some(fixed) = &b.fixed_output {
            for (k, v) in fixed.env() {
                attrs.insert(k, JsonValue::String(v));
            }
        }
        env.insert("__json".to_owned(), JsonValue::Object(attrs).to_json());
    } else {
        for (k, v) in &b.env {
            if let JsonValue::String(s) = v {
                env.insert(k.clone(), s.clone());
            }
        }
        env.insert("name".to_owned(), b.name.clone());
        env.insert("system".to_owned(), b.system.clone());
        env.insert("builder".to_owned(), b.builder.clone());
        if declared {
            let joined = names
                .iter()
                .map(|n| n.to_string())
                .collect::<Vec<_>>()
                .join(" ");
            env.insert("outputs".to_owned(), joined);
        }
        if let Some(fixed) = &b.fixed_output {
            env.extend(fixed.env());
        }
    }
    // Placeholders. The real paths are the hash of the derivation that contains
    // them, so they cannot be known until the next step, and the masked form
    // used to compute them blanks these anyway.
    for n in &names {
        env.insert(n.to_string(), String::new());
    }

    let (algo, digest) = match &b.fixed_output {
        Some(f) => (f.hash_algo_field()?, f.hash_field()?),
        None => (String::new(), String::new()),
    };

    let edges = merge_edges(&b.input_drvs);
    let draft = canonical(&Derivation {
        outputs: names
            .iter()
            .map(|n| Output {
                name: n.clone(),
                path: StorePath::default(),
                hash_algo: algo.clone(),
                hash: digest.clone(),
            })
            .collect(),
        input_drvs: edges
            .iter()
            .map(|d| InputDrv {
                path: d.path.clone(),
                outputs: d.outputs.clone(),
            })
            .collect(),
        input_srcs: b.input_srcs.clone(),
        system: b.system.clone(),
        builder: b.builder.clone(),
        args: b.args.clone(),
        env: env.into_iter().collect(),
    });

    let input_hashes: BTreeMap<StorePath, String> = edges
        .iter()
        .map(|d| (d.path.clone(), d.input_hash.to_string()))
        .collect();
    let paths = output_paths(&draft, &b.name, &input_hashes);

    let mut final_drv = draft;
    for o in &mut final_drv.outputs {
        o.path = paths[&o.name].clone();
    }
    for (k, v) in &mut final_drv.env {
        if let Some(p) = paths.get(&OutputName::new(k.clone())) {
            *v = p.to_string();
        }
    }

    let aterm = unparse(&final_drv);
    let input_hash = match final_drv.fixed_output() {
        Some(fixed) => fixed_output_input_hash(fixed),
        None => sha256_hex(&unparse_with(
            &final_drv,
            &Serialize {
                mask_outputs: false,
                input_hashes: Some(&input_hashes),
            },
        )),
    };
    Ok(Drv {
        path: drv_path(&aterm, &b.name),
        derivation: final_drv,
        input_hash,
    })
}

/// Merge duplicate targets into one edge with the union of the outputs needed.
///
/// That is what Nix emits: store paths are unique within `inputDrvs` in 1293 of
/// 1293 real derivations.
fn merge_edges(deps: &[Dep]) -> Vec<Dep> {
    let mut merged: BTreeMap<StorePath, (Sha256Hex, BTreeSet<OutputName>)> = BTreeMap::new();
    for d in deps {
        let slot = merged
            .entry(d.path.clone())
            .or_insert_with(|| (d.input_hash.clone(), BTreeSet::new()));
        slot.1.extend(d.outputs.iter().cloned());
    }
    merged
        .into_iter()
        .map(|(path, (input_hash, outputs))| Dep {
            path,
            input_hash,
            outputs: outputs.into_iter().collect(),
        })
        .collect()
}
