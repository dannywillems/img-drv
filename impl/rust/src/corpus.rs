//! A closure of derivations, and the recursive hashing over it.
//!
//! A real closure is a DAG with heavy sharing: a 226-derivation closure hashes
//! the same bootstrap tools hundreds of times. The memo table is what makes
//! verification linear in the number of edges rather than exponential in depth,
//! and it is correct because a derivation is immutable and its hash depends
//! only on its transitive inputs.
//!
//! Structurally this is a fold over a DAG. [`Corpus::input_hash`] is defined by
//! WELL-FOUNDED recursion: the graph is finite and acyclic, so the recursion
//! terminates and picks out exactly one function, which is why every conforming
//! implementation in any language must produce the same digests. See
//! `docs/abstractions.md` entry 2.

use std::collections::BTreeMap;
use std::fmt;
use std::path::Path;

use crate::aterm::{ParseError, Serialize, parse, unparse_with};
use crate::derivation::{Derivation, OutputName, Sha256Hex, StorePath};
use crate::store::{BASE32_ALPHABET, STORE, fixed_output_input_hash, output_paths, sha256_hex};

/// A store path basename is `<32 base-32 chars>-<name>`.
const HASH_LEN: usize = 32;

/// The derivation name that output paths are suffixed with.
///
/// A real store path is `<32 chars>-<name>.drv`, so the hash prefix is
/// stripped. When the file is not named that way, fall back to the `name`
/// environment variable, which every derivation carries.
pub fn name_from_path(path: &StorePath, drv: Option<&Derivation>) -> String {
    let base = path.as_str().rsplit('/').next().unwrap_or(path.as_str());
    let base = base.strip_suffix(".drv").unwrap_or(base);
    if let Some((head, tail)) = base.split_once('-')
        && head.len() == HASH_LEN
        && head.bytes().all(|c| BASE32_ALPHABET.contains(&c))
    {
        return tail.to_owned();
    }
    match drv {
        Some(d) if !d.name().is_empty() => d.name().to_owned(),
        _ => base.to_owned(),
    }
}

/// One output whose recomputed path differs from the recorded one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Mismatch {
    /// The derivation's name, as taken from its store path.
    pub drv_name: String,
    /// Which output disagreed.
    pub output: OutputName,
    /// The path the derivation records.
    pub expected: StorePath,
    /// The path we computed, or `None` when the output was not produced.
    pub got: Option<StorePath>,
}

impl fmt::Display for Mismatch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}:{}\n  expected {}\n  got      {}",
            self.drv_name,
            self.output,
            self.expected,
            match &self.got {
                Some(p) => p.as_str(),
                None => "<none>",
            }
        )
    }
}

/// A set of derivations indexed by store path.
///
/// Not every input is necessarily present: a closure exported from a store is
/// complete, but a hand-assembled directory need not be. Inputs that are absent
/// are left as paths, which is the only honest thing to do and is why an
/// incomplete corpus produces mismatches rather than silence.
#[derive(Clone, Debug, Default)]
pub struct Corpus {
    /// Every derivation loaded, keyed by its `.drv` store path.
    pub drvs: BTreeMap<StorePath, Derivation>,
}

/// A `.drv` in a corpus directory that could not be read.
#[derive(Debug)]
pub enum LoadError {
    /// The directory or a file in it could not be read.
    Io(std::io::Error),
    /// A `.drv` was read but could not be parsed.
    Parse {
        /// The file that failed.
        file: String,
        /// Why it failed.
        error: ParseError,
    },
}

impl fmt::Display for LoadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(e) => write!(f, "{e}"),
            Self::Parse { file, error } => write!(f, "{file}: {error}"),
        }
    }
}

impl std::error::Error for LoadError {}

impl From<std::io::Error> for LoadError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}

impl Corpus {
    /// Load every `*.drv` in a directory, keyed by its store path.
    pub fn from_directory(directory: &Path) -> Result<Self, LoadError> {
        let mut drvs = BTreeMap::new();
        for entry in std::fs::read_dir(directory)? {
            let path = entry?.path();
            if path.extension().is_none_or(|e| e != "drv") {
                continue;
            }
            let file = path
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            let text = std::fs::read_to_string(&path)?;
            let drv = parse(&text).map_err(|error| LoadError::Parse {
                file: file.clone(),
                error,
            })?;
            drvs.insert(StorePath::new(format!("{STORE}/{file}")), drv);
        }
        Ok(Self { drvs })
    }

    /// How many derivations the corpus holds.
    pub fn len(&self) -> usize {
        self.drvs.len()
    }

    /// Whether the corpus is empty.
    pub fn is_empty(&self) -> bool {
        self.drvs.is_empty()
    }

    /// The hash by which a derivation is known when it is someone's INPUT.
    ///
    /// Outputs are NOT masked here; that is the asymmetry documented in
    /// [`crate::store::output_paths`] and in `docs/theory.md` section 7.
    pub fn input_hash(&self, path: &StorePath) -> Option<Sha256Hex> {
        let mut memo = BTreeMap::new();
        self.input_hash_memo(path, &mut memo)
    }

    fn input_hash_memo(
        &self,
        path: &StorePath,
        memo: &mut BTreeMap<StorePath, Sha256Hex>,
    ) -> Option<Sha256Hex> {
        if let Some(h) = memo.get(path) {
            return Some(h.clone());
        }
        let drv = self.drvs.get(path)?;
        let hash = match drv.fixed_output() {
            Some(fixed) => fixed_output_input_hash(fixed),
            None => {
                let inputs = self.input_hashes_of(drv, memo);
                sha256_hex(&unparse_with(
                    drv,
                    &Serialize {
                        mask_outputs: false,
                        input_hashes: Some(&inputs),
                    },
                ))
            }
        };
        memo.insert(path.clone(), hash.clone());
        Some(hash)
    }

    fn input_hashes_of(
        &self,
        drv: &Derivation,
        memo: &mut BTreeMap<StorePath, Sha256Hex>,
    ) -> BTreeMap<StorePath, String> {
        let mut out = BTreeMap::new();
        for i in &drv.input_drvs {
            if let Some(h) = self.input_hash_memo(&i.path, memo) {
                out.insert(i.path.clone(), h.to_string());
            }
        }
        out
    }

    /// Recompute every output path of one derivation in this corpus.
    pub fn output_paths_of(&self, path: &StorePath) -> Option<BTreeMap<OutputName, StorePath>> {
        let drv = self.drvs.get(path)?;
        let mut memo = BTreeMap::new();
        let inputs = self.input_hashes_of(drv, &mut memo);
        Some(output_paths(drv, &name_from_path(path, Some(drv)), &inputs))
    }

    /// Recompute every output path and compare with the recorded one.
    ///
    /// Returns the number of outputs checked and every mismatch. These are real
    /// derivations produced by real Nix, so this is a regression test against
    /// vectors nobody wrote by hand.
    pub fn verify(&self) -> (usize, Vec<Mismatch>) {
        let mut checked = 0;
        let mut bad = Vec::new();
        // One memo table for the whole corpus, not one per derivation: sharing
        // is what makes this linear in edges.
        let mut memo = BTreeMap::new();
        for (path, drv) in &self.drvs {
            let inputs = self.input_hashes_of(drv, &mut memo);
            let got = output_paths(drv, &name_from_path(path, Some(drv)), &inputs);
            for o in &drv.outputs {
                checked += 1;
                if got.get(&o.name) != Some(&o.path) {
                    bad.push(Mismatch {
                        drv_name: name_from_path(path, Some(drv)),
                        output: o.name.clone(),
                        expected: o.path.clone(),
                        got: got.get(&o.name).cloned(),
                    });
                }
            }
        }
        (checked, bad)
    }
}
