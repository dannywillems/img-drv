//! The eDSL's laws, as property tests over generated intents.
//!
//! These are the SAME laws as `impl/python/tests/test_edsl_laws.py`, which is
//! the point: a law is a property of the SPECIFICATION, so it ports rather than
//! being rewritten. When Go and OCaml arrive, this file is what they have to
//! satisfy, not this file's implementation.
//!
//! One law from the Python suite is absent on purpose. "env insertion order is
//! not observable" is a property test there because `dict` preserves insertion
//! order; here [`Build::env`] is a `BTreeMap`, so there is no insertion order
//! for the bytes to depend on and the law is unrepresentable-to-violate. The
//! test below checks the claim rather than the law: two permutations collected
//! into the map are the same map.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use img_drv::{
    Build, Corpus, Dep, Drv, FixedOutput, HashAlgo, OutputName, Serialize, base32, base32_decode,
    canonical, derivation, drv_path, parse, sha256_hex, unparse, unparse_with,
};
use proptest::prelude::*;

const RESERVED: &[&str] = &[
    "name",
    "system",
    "builder",
    "outputs",
    "outputHash",
    "outputHashAlgo",
    "outputHashMode",
];

// --------------------------------------------------------------------------
// generators
// --------------------------------------------------------------------------

/// Store names, valid by CONSTRUCTION rather than by filtering: a leading
/// letter, then only characters Nix accepts in a store path name.
fn store_names() -> impl Strategy<Value = String> {
    ("[a-z]", "[a-z0-9+._?=-]{0,12}").prop_map(|(h, t): (String, String)| format!("{h}{t}"))
}

/// Deliberately nasty values: the five escaped characters, a control character
/// that must NOT be escaped, and the `],[` sequence that defeats pattern
/// matching. Serialization has to survive all of it unchanged.
fn values() -> impl Strategy<Value = String> {
    prop::collection::vec(
        prop_oneof![
            4 => prop::sample::select(vec![
                '"', '\\', '\n', '\r', '\t', '\u{7}', ']', '[', ',', '/',
            ]),
            1 => any::<char>(),
        ],
        0..10usize,
    )
    .prop_map(|v| v.into_iter().collect())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn b64(data: &[u8]) -> String {
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let mut acc = [0u8; 3];
        acc[..chunk.len()].copy_from_slice(chunk);
        let n = u32::from_be_bytes([0, acc[0], acc[1], acc[2]]);
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(B64[((n >> (18 - 6 * i)) & 0x3f) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// A declared hash, written the way real derivations write them.
fn fixed_outputs() -> impl Strategy<Value = FixedOutput> {
    (
        prop::collection::vec(any::<u8>(), 32..=32),
        0usize..3,
        any::<bool>(),
    )
        .prop_map(|(digest, form, recursive)| {
            let f = match form {
                0 => FixedOutput::new(hex(&digest), HashAlgo::Sha256),
                1 => FixedOutput::new(base32(&digest), HashAlgo::Sha256),
                _ => FixedOutput::sri(format!("sha256-{}", b64(&digest))),
            };
            if recursive { f.recursive() } else { f }
        })
}

/// A build description, held apart from the call that realises it.
///
/// Keeping the intent as a value is what lets a law say "these two ways of
/// writing the same thing must serialize identically".
#[derive(Clone, Debug)]
struct Intent {
    name: String,
    system: String,
    builder: String,
    args: Vec<String>,
    env: Vec<(String, String)>,
    outputs: Option<Vec<String>>,
    fixed: Option<FixedOutput>,
}

impl Intent {
    fn to_build(&self, deps: Vec<Dep>) -> Build {
        Build {
            name: self.name.clone(),
            system: self.system.clone(),
            builder: self.builder.clone(),
            args: self.args.clone(),
            env: self.env.iter().cloned().collect(),
            outputs: self
                .outputs
                .as_ref()
                .map(|o| o.iter().map(OutputName::new).collect()),
            input_drvs: deps,
            input_srcs: Vec::new(),
            fixed_output: self.fixed.clone(),
        }
    }

    fn build_with(&self, deps: Vec<Dep>) -> Drv {
        derivation(self.to_build(deps)).expect("a generated intent is valid by construction")
    }

    fn build(&self) -> Drv {
        self.build_with(Vec::new())
    }
}

fn intents() -> impl Strategy<Value = Intent> {
    (
        store_names(),
        values(),
        values(),
        prop::collection::vec(values(), 0..3),
        prop::collection::vec((store_names(), values()), 0..5),
        prop::option::of(prop::collection::vec(store_names(), 1..4)),
        prop::option::of(fixed_outputs()),
    )
        .prop_map(|(name, system, builder, args, env, outputs, fixed)| {
            // Deduplicate rather than filter: filtering on a rare
            // collision only makes the strategy slow and flaky.
            let outputs = outputs.map(dedup);
            let names = outputs.clone().unwrap_or_else(|| vec!["out".to_owned()]);
            let fixed = if names.len() == 1 { fixed } else { None };
            let mut seen: Vec<(String, String)> = Vec::new();
            for (k, v) in env {
                let reserved = RESERVED.contains(&k.as_str()) || names.contains(&k);
                if !reserved && !seen.iter().any(|(o, _)| *o == k) {
                    seen.push((k, v));
                }
            }
            Intent {
                name,
                system,
                builder,
                args,
                env: seen,
                outputs,
                fixed,
            }
        })
}

fn dedup(items: Vec<String>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for i in items {
        if !out.contains(&i) {
            out.push(i);
        }
    }
    out
}

/// Depend on an output the target actually has.
///
/// The `needs(&[])` shorthand means "I need `out`", which most derivations have
/// and a generated one need not.
fn edge(drv: &Drv) -> Dep {
    let first = drv
        .outputs()
        .keys()
        .next()
        .expect("every derivation has at least one output")
        .to_string();
    drv.needs(&[&first]).expect("its own output")
}

// --------------------------------------------------------------------------
// laws
// --------------------------------------------------------------------------

proptest! {
    /// Serialization is a FUNCTION, not a process.
    ///
    /// Trivial-looking, and the first thing to break if anything reachable from
    /// here ever depends on iteration order, address, or a clock.
    #[test]
    fn describing_the_same_intent_twice_gives_the_same_bytes(i in intents()) {
        let (a, b) = (i.build(), i.build());
        prop_assert_eq!(a.aterm(), b.aterm());
        prop_assert_eq!(a.path(), b.path());
        prop_assert_eq!(a.input_hash(), b.input_hash());
    }

    /// `inputDrvs` is a SET of edges; the .drv sorts it by store path.
    ///
    /// Listing dependencies in a different order is the same description.
    #[test]
    fn dependency_order_is_not_observable(a in intents(), b in intents(), c in intents()) {
        let (x, y) = (edge(&a.build()), edge(&b.build()));
        let one = c.build_with(vec![x.clone(), y.clone()]);
        let other = c.build_with(vec![y, x]);
        prop_assert_eq!(one.aterm(), other.aterm());
        prop_assert_eq!(one.path(), other.path());
    }

    /// Edges merge: store paths are unique in `inputDrvs` in 1293 of 1293 real
    /// derivations, so a repeated reference cannot become a repeated entry.
    #[test]
    fn naming_a_dependency_twice_is_naming_it_once(i in intents()) {
        let dep = i.build();
        let once = i.build_with(vec![edge(&dep)]);
        let twice = i.build_with(vec![edge(&dep), edge(&dep), edge(&dep)]);
        prop_assert_eq!(once.aterm(), twice.aterm());
    }

    /// A fixed point of the same normalizer real Nix output is a fixed point
    /// of. Paired with `golden::real_derivations_are_already_canonical`, this
    /// is what makes the claim "our bytes are Nix's".
    #[test]
    fn what_the_edsl_builds_is_canonical(i in intents()) {
        let drv = i.build();
        prop_assert_eq!(canonical(drv.derivation()), drv.derivation().clone());
    }

    /// A normal form applied twice is applied once.
    #[test]
    fn canonical_is_idempotent(i in intents()) {
        let d = canonical(i.build().derivation());
        prop_assert_eq!(canonical(&d), d.clone());
    }

    /// The store path is not metadata: it is a function of the file content.
    #[test]
    fn the_path_is_the_hash_of_the_bytes(i in intents()) {
        let drv = i.build();
        prop_assert_eq!(drv.path(), &drv_path(&drv.aterm(), &i.name));
    }

    /// The two halves of the crate are inverse on the eDSL's image.
    ///
    /// `parse . unparse = id` holds everywhere; `unparse . parse = id` holds
    /// only on CANONICAL text, which is exactly what the eDSL emits.
    #[test]
    fn what_the_edsl_writes_the_parser_reads(i in intents()) {
        let drv = i.build();
        let text = drv.aterm();
        let read = parse(&text).expect("its own output parses");
        prop_assert_eq!(&read, drv.derivation());
        prop_assert_eq!(unparse(&read), text);
    }

    /// `None` and `Some(["out"])` are different derivations, for every intent.
    ///
    /// Both forms occur in real nixpkgs, so an implementation that conflates
    /// them cannot reproduce one of them.
    #[test]
    fn declaring_outputs_is_observable(i in intents()) {
        let mut implicit = i.clone();
        implicit.outputs = None;
        let mut explicit = i.clone();
        explicit.outputs = Some(vec!["out".to_owned()]);
        let (a, b) = (implicit.build(), explicit.build());
        prop_assert_ne!(a.aterm(), b.aterm());
        prop_assert_ne!(a.path(), b.path());
    }

    /// Invariant 6 of spec/signature.md, for every intent rather than one.
    #[test]
    fn every_output_is_an_env_variable_holding_its_own_path(i in intents()) {
        let drv = i.build();
        let env: BTreeMap<&str, &str> = drv
            .derivation()
            .env
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        for (name, path) in drv.outputs() {
            prop_assert_eq!(env.get(name), Some(&path.as_str()));
        }
    }

    /// The asymmetry that cost this repository 145 downstream failures.
    ///
    /// A derivation's own path is computed from a form with its outputs
    /// MASKED; the hash by which it is known as someone's INPUT is not.
    #[test]
    fn the_input_hash_is_not_the_self_hash(i in intents()) {
        let drv = i.build();
        let masked = sha256_hex(&unparse_with(
            drv.derivation(),
            &Serialize { mask_outputs: true, input_hashes: None },
        ));
        prop_assert_ne!(drv.input_hash(), &masked);
    }

    /// `env` is a `BTreeMap`, so there is no insertion order to leak.
    ///
    /// In Python this is a genuine property test over a dict; here the type
    /// already rules the failure out, and the test records that claim.
    #[test]
    fn env_has_no_insertion_order_to_observe(i in intents()) {
        let forward: BTreeMap<String, String> = i.env.iter().cloned().collect();
        let backward: BTreeMap<String, String> = i.env.iter().rev().cloned().collect();
        prop_assert_eq!(&forward, &backward);
        let build_with = |env| derivation(Build { env, ..i.to_build(vec![]) }).expect("valid");
        prop_assert_eq!(build_with(forward).aterm(), build_with(backward).aterm());
    }

    /// An inverse, not an approximation of one.
    #[test]
    fn base32_decode_inverts_base32(data in prop::collection::vec(any::<u8>(), 1..64)) {
        prop_assert_eq!(base32_decode(&base32(&data), data.len()), Ok(data));
    }

    /// Representation-independence, which is why fetchers share cache entries.
    ///
    /// Two fixed-output derivations declaring the same BYTES agree on the
    /// output path however differently the hash was spelled, while remaining
    /// distinguishable as files, because the env keeps the spelling verbatim.
    #[test]
    fn a_digest_means_the_same_however_it_is_written(
        digest in prop::collection::vec(any::<u8>(), 32..=32),
        recursive in any::<bool>(),
    ) {
        let spell = |f: FixedOutput| {
            let f = if recursive { f.recursive() } else { f };
            derivation(Build {
                name: "f".into(),
                system: "x86_64-linux".into(),
                builder: "/bin/sh".into(),
                fixed_output: Some(f),
                ..Default::default()
            })
            .expect("valid")
        };
        let drvs = [
            spell(FixedOutput::new(hex(&digest), HashAlgo::Sha256)),
            spell(FixedOutput::new(base32(&digest), HashAlgo::Sha256)),
            spell(FixedOutput::sri(format!("sha256-{}", b64(&digest)))),
        ];
        let outs: Vec<_> = drvs.iter().map(|d| d.output("out").expect("out")).collect();
        prop_assert!(outs.windows(2).all(|w| w[0] == w[1]));
        let paths: std::collections::BTreeSet<_> = drvs.iter().map(Drv::path).collect();
        prop_assert_eq!(paths.len(), 3);
    }
}

// The closure law does filesystem work, so it runs fewer cases.
proptest! {
    #![proptest_config(ProptestConfig::with_cases(32))]

    /// Describe a DAG, write it out, and check it the way nixpkgs is checked.
    ///
    /// The strongest law available without invoking Nix: the eDSL's output is
    /// handed to the same recursive path computation that reproduces 1259 of
    /// 1259 real output paths, reached by a different route (parse the files
    /// back, rebuild the memo table, re-derive every path).
    #[test]
    fn a_described_closure_verifies_like_a_real_one(
        plan in prop::collection::vec(intents(), 1..5),
    ) {
        let mut built: Vec<Drv> = Vec::new();
        for i in &plan {
            // A chain, so inputDrvs carries real edges and the recursive
            // input-hash substitution has somewhere to recurse.
            let deps = built.iter().rev().take(2).map(edge).collect();
            built.push(i.build_with(deps));
        }

        let dir = scratch_dir();
        std::fs::create_dir_all(&dir).expect("scratch");
        for drv in &built {
            drv.write(&dir).expect("writable");
        }
        let corpus = Corpus::from_directory(&dir).expect("loadable");
        let (checked, mismatches) = corpus.verify();
        std::fs::remove_dir_all(&dir).expect("removable");

        prop_assert!(
            mismatches.is_empty(),
            "{}",
            mismatches.iter().map(ToString::to_string).collect::<Vec<_>>().join("\n")
        );
        prop_assert!(checked >= 1);
    }
}

/// A unique scratch directory, without a `tempfile` dependency.
fn scratch_dir() -> PathBuf {
    static N: AtomicUsize = AtomicUsize::new(0);
    std::env::temp_dir().join(format!(
        "img-drv-laws-{}-{}",
        std::process::id(),
        N.fetch_add(1, Ordering::Relaxed)
    ))
}
