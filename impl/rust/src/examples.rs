//! The conformance corpus: intents, and the bytes real Nix produced for them.
//!
//! This is the language-independent set `PLAN.md` phase 2 asks for. Each entry
//! is an INTENT expressed through the eDSL, paired with the name of the golden
//! file in `docs/spec/examples/` that real Nix emitted for the same intent.
//!
//! It lives in the library rather than in the tests because three things
//! consume it: the test suite, the `examples` CLI command, and `make
//! conformance`, which diffs what Rust emits against what Python emits against
//! what Nix emitted.
//!
//! These are the SAME ten intents as `img_drv.examples` in Python, transcribed
//! rather than shared, because there is nothing to share them THROUGH: that is
//! exactly the claim under test. A transcription slip shows up as a
//! conformance failure, which is the point.

use std::collections::BTreeMap;

use crate::derivation::{OutputName, StorePath};
use crate::edsl::{Build, Drv, FixedOutput, HashAlgo, HashMode, derivation};
use crate::json::JsonValue;

/// Every example targets one system, so the corpus is comparable across
/// machines: a derivation's store path depends on its system.
pub const SYSTEM: &str = "x86_64-linux";

/// The builder every example runs.
pub const SH: &str = "/bin/sh";

fn base(name: &str) -> Build {
    Build {
        name: name.into(),
        system: SYSTEM.into(),
        builder: SH.into(),
        ..Default::default()
    }
}

fn echo(name: &str, word: &str) -> Drv {
    derivation(Build {
        args: vec!["-c".into(), format!("echo {word} > $out")],
        ..base(name)
    })
    .expect("a fixed example is valid")
}

/// The smallest real derivation: one output, no dependencies.
pub fn hello() -> Drv {
    echo("hello", "hi")
}

/// One of three leaves used to exercise multi-entry `inputDrvs`.
pub fn aaa() -> Drv {
    echo("aaa", "aaa")
}

/// One of three leaves used to exercise multi-entry `inputDrvs`.
pub fn mmm() -> Drv {
    echo("mmm", "mmm")
}

/// One of three leaves used to exercise multi-entry `inputDrvs`.
pub fn zzz() -> Drv {
    echo("zzz", "zzz")
}

/// The dependency of [`dependent`], and a reconstruction target itself.
pub fn dep_a() -> Drv {
    echo("dep-a", "a")
}

/// One edge, which is what pins the mask/do-not-mask asymmetry.
pub fn dependent() -> Drv {
    let a = dep_a();
    let out = a.output("out").expect("out").clone();
    derivation(Build {
        args: vec!["-c".into(), format!("cat {out} > $out")],
        input_drvs: vec![a.needs(&[]).expect("out")],
        ..base("dependent")
    })
    .expect("a fixed example is valid")
}

/// Three edges, named in an order that is NOT their store-path order.
///
/// That is what makes this example evidence: `inputDrvs` has to come out
/// sorted by path regardless of the order the caller used them in.
pub fn many() -> Drv {
    let (a, m, z) = (aaa(), mmm(), zzz());
    let cat = format!(
        "cat {} {} {} > $out",
        z.output("out").expect("out"),
        a.output("out").expect("out"),
        m.output("out").expect("out"),
    );
    derivation(Build {
        args: vec!["-c".into(), cat],
        input_drvs: vec![
            z.needs(&[]).expect("out"),
            a.needs(&[]).expect("out"),
            m.needs(&[]).expect("out"),
        ],
        ..base("many")
    })
    .expect("a fixed example is valid")
}

/// Env declared out of order, to pin that env is sorted by key.
pub fn ordering() -> Drv {
    derivation(Build {
        env: BTreeMap::from([
            ("zzz".to_owned(), "last-declared-first".into()),
            ("aaa".to_owned(), "first".into()),
            ("mmm".to_owned(), "middle".into()),
        ]),
        ..base("ordering")
    })
    .expect("a fixed example is valid")
}

/// Three outputs, which carries TWO orderings of the same list.
pub fn multi() -> Drv {
    derivation(Build {
        outputs: Some(vec![
            OutputName::new("out"),
            OutputName::new("dev"),
            OutputName::new("lib"),
        ]),
        ..base("multi")
    })
    .expect("a fixed example is valid")
}

/// A fixed-output derivation, with the hash written in base-32.
///
/// The outputs tuple must carry it re-encoded as hex while the env keeps it
/// exactly as written, which is the rule an implementation is most likely to
/// get wrong.
pub fn fixed() -> Drv {
    derivation(Build {
        fixed_output: Some(FixedOutput::new("0".repeat(52), HashAlgo::Sha256)),
        ..base("fixed")
    })
    .expect("a fixed example is valid")
}

/// `__structuredAttrs`: attributes as JSON, with their types preserved.
///
/// The flat encoding can only carry strings, so a boolean, an integer, a list
/// or a nested attribute set has to be flattened and re-parsed by the builder.
/// This one keeps them. 1223 of 2516 real derivations use it.
///
/// It also exercises the same two-orderings rule as [`multi`]: the outputs
/// tuple comes out sorted (`dev`, `out`) while `outputs` inside the JSON keeps
/// declaration order (`out`, `dev`).
pub fn structured() -> Drv {
    derivation(Build {
        args: vec!["-c".into(), "echo hi > $out".into()],
        outputs: Some(vec![OutputName::new("out"), OutputName::new("dev")]),
        structured_attrs: true,
        env: BTreeMap::from([
            ("aFlag".to_owned(), JsonValue::Bool(true)),
            ("aNumber".to_owned(), JsonValue::Int(42)),
            (
                "aList".to_owned(),
                JsonValue::Array(vec!["x".into(), "y".into()]),
            ),
            (
                "nested".to_owned(),
                JsonValue::object([("deep", JsonValue::object([("deeper", "value")]))]),
            ),
            ("aString".to_owned(), "plain".into()),
        ]),
        ..base("structured")
    })
    .expect("a fixed example is valid")
}

/// Golden file name, and the intent that must reproduce it byte for byte.
pub fn corpus() -> Vec<(&'static str, Drv)> {
    vec![
        (
            "sb07z720914wba188q8vzq7jnx4596xp-dependent.drv",
            dependent(),
        ),
        ("3k9aahbip0dn0kb9m6i20sr2mjfmzsij-aaa.drv", aaa()),
        ("6hjg3xda34qvj2vpw27girg51gpdyd19-fixed.drv", fixed()),
        ("76w21n1f03fs5kw8fnffphx7qrqffw6r-hello.drv", hello()),
        ("7v25018h9x5nc7sc0sv57ghaq2qa0j9n-zzz.drv", zzz()),
        ("5x04ng0y0kgnkp3kyah1ziwlyj107q8m-many.drv", many()),
        ("k1lc1y192xiajlyy4zvsdnfprnjx32i3-dep-a.drv", dep_a()),
        ("mfdcxzh0v906c5hngb3x0b7sjl130hpk-ordering.drv", ordering()),
        (
            "sqgix69fbs6hjh5kmf2pb1zvfmi5d0am-structured.drv",
            structured(),
        ),
        ("v27a425rg4n7prwzpyyw0y1fw2ssc46f-multi.drv", multi()),
        ("vk8wqbqg3k8w4134kwa0392kbc1953aq-mmm.drv", mmm()),
    ]
}

// The DIFFERENTIAL probe, described through the eDSL.
//
// `scripts/probe.nix` is instantiated by the pinned Nix on every run, and until
// now only our PATH COMPUTATION was checked against the result: parse what Nix
// emitted, recompute the paths, compare. The eDSL itself was checked only
// against the golden files, which are checked in and therefore frozen.
//
// Describing the same five derivations here makes `make differential` a LIVE
// oracle for the eDSL too: our bytes against bytes a real nix-instantiate
// produced moments earlier, rather than against a file someone committed. A
// frozen golden cannot notice the ORACLE moving; this can.

/// The characters that defeat naive pattern matching, exactly as the probe
/// writes them.
///
/// No trailing newline: the probe writes this as a ONE-LINE indented string,
/// and one that does not end in a newline does not gain one. Adding it was the
/// first thing the live oracle caught.
const NASTY: &str = "a \"quoted\" \\ backslash, a ],[ sequence, and a tab:\tdone";

fn probe_dep(name: &str, word: &str) -> Drv {
    echo(name, word)
}

/// Fixed-output, FLAT ingestion: the `fixed:out:` fingerprint scheme.
pub fn probe_fetched() -> Drv {
    derivation(Build {
        args: vec!["-c".into(), "echo hi > $out".into()],
        fixed_output: Some(FixedOutput::new("0".repeat(64), HashAlgo::Sha256)),
        ..base("fetched")
    })
    .expect("a fixed example is valid")
}

/// Fixed-output, RECURSIVE ingestion: the `source` kind.
///
/// The declared hash is used DIRECTLY as the inner hash rather than wrapped in
/// a fingerprint. Missing this costs exactly one path in a real closure, which
/// is how it survived a hand-written corpus.
pub fn probe_fetched_rec() -> Drv {
    let mut fixed = FixedOutput::new("1".repeat(64), HashAlgo::Sha256);
    fixed.mode = HashMode::Recursive;
    derivation(Build {
        args: vec!["-c".into(), "mkdir $out".into()],
        fixed_output: Some(fixed),
        ..base("fetched-rec")
    })
    .expect("a fixed example is valid")
}

/// Four input edges covering every scheme above, plus the awkward cases.
pub fn probe() -> Drv {
    let (dep, dep2) = (probe_dep("dep-a", "a"), probe_dep("dep-b", "b"));
    let (fetched, fetched_rec) = (probe_fetched(), probe_fetched_rec());
    let cat = format!(
        "cat {} {} {} {} > $out",
        dep.output("out").expect("out"),
        dep2.output("out").expect("out"),
        fetched.output("out").expect("out"),
        fetched_rec.output("out").expect("out"),
    );
    derivation(Build {
        args: vec!["-c".into(), cat],
        input_drvs: vec![
            dep.needs(&[]).expect("out"),
            dep2.needs(&[]).expect("out"),
            fetched.needs(&[]).expect("out"),
            fetched_rec.needs(&[]).expect("out"),
        ],
        outputs: Some(vec![
            OutputName::new("out"),
            OutputName::new("dev"),
            OutputName::new("lib"),
        ]),
        env: BTreeMap::from([
            ("zzz".to_owned(), "last".into()),
            ("aaa".to_owned(), "first".into()),
            ("mmm".to_owned(), "middle".into()),
            ("nasty".to_owned(), NASTY.into()),
        ]),
        ..base("probe")
    })
    .expect("a fixed example is valid")
}

/// Every derivation the probe closure contains.
pub fn probe_corpus() -> Vec<Drv> {
    vec![
        probe_dep("dep-a", "a"),
        probe_dep("dep-b", "b"),
        probe_fetched(),
        probe_fetched_rec(),
        probe(),
    ]
}

/// A derivation with a non-empty `inputSrcs`.
///
/// The one half of the `.drv` references rule nothing else exercises: a
/// derivation's own store path lists `inputDrvs` UNION `inputSrcs`, and every
/// derivation the project could previously build had an empty `inputSrcs`, so
/// that half was verified only by reading real files.
pub fn with_src(src: &str) -> Drv {
    derivation(Build {
        args: vec!["-c".into(), format!("cat {src} > $out")],
        input_srcs: vec![StorePath::new(src)],
        ..base("with-src")
    })
    .expect("a fixed example is valid")
}
