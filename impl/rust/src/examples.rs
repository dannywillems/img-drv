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

use crate::derivation::OutputName;
use crate::edsl::{Build, Drv, FixedOutput, HashAlgo, derivation};

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
            ("zzz".to_owned(), "last-declared-first".to_owned()),
            ("aaa".to_owned(), "first".to_owned()),
            ("mmm".to_owned(), "middle".to_owned()),
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

/// Golden file name, and the intent that must reproduce it byte for byte.
pub fn corpus() -> Vec<(&'static str, Drv)> {
    vec![
        (
            "34h63y306vjiqi9974m0abrkp8aplgjq-dependent.drv",
            dependent(),
        ),
        ("3k9aahbip0dn0kb9m6i20sr2mjfmzsij-aaa.drv", aaa()),
        ("6hjg3xda34qvj2vpw27girg51gpdyd19-fixed.drv", fixed()),
        ("76w21n1f03fs5kw8fnffphx7qrqffw6r-hello.drv", hello()),
        ("7v25018h9x5nc7sc0sv57ghaq2qa0j9n-zzz.drv", zzz()),
        ("h3ik45ycljylpdzjssckqi3vvslsbxpn-many.drv", many()),
        ("k1lc1y192xiajlyy4zvsdnfprnjx32i3-dep-a.drv", dep_a()),
        ("mfdcxzh0v906c5hngb3x0b7sjl130hpk-ordering.drv", ordering()),
        ("v27a425rg4n7prwzpyyw0y1fw2ssc46f-multi.drv", multi()),
        ("vk8wqbqg3k8w4134kwa0392kbc1953aq-mmm.drv", mmm()),
    ]
}
