//! The eDSL, checked against derivations real Nix actually emitted.
//!
//! The test that matters is not "does it build a plausible record". It is:
//! DESCRIBE the same intent that produced a golden file, and demand the same
//! bytes, including the derivation's own store path. Anything less would pass
//! for an implementation with the right shape and the wrong identity.
//!
//! These are the SAME ten intents as `impl/python/tests/test_edsl.py`. That is
//! the point: two languages, one set of bytes.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use img_drv::{
    Build, FixedOutput, HashAlgo, HashMode, InvalidDerivation, OutputName, base32, canonical,
    derivation, valid_name,
};

const SYSTEM: &str = "x86_64-linux";
const SH: &str = "/bin/sh";

fn golden(name: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../docs/spec/examples")
        .join(name);
    std::fs::read_to_string(path)
        .unwrap_or_else(|e| panic!("{name}: {e}"))
        .trim_end_matches('\n')
        .to_owned()
}

fn base(name: &str) -> Build {
    Build {
        name: name.into(),
        system: SYSTEM.into(),
        builder: SH.into(),
        ..Default::default()
    }
}

// The intents live in the library, not here: `make conformance` and the
// `examples` CLI command consume the same ten, so a corpus only the tests
// could see would not be the conformance corpus.
use img_drv::examples::{corpus as intents, dep_a, dependent, hello, multi};

#[test]
fn every_golden_file_has_an_intent() {
    // A golden nobody describes is a rule nobody is testing.
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docs/spec/examples");
    let mut on_disk: Vec<String> = std::fs::read_dir(dir)
        .expect("golden directory")
        .filter_map(Result::ok)
        .map(|e| PathBuf::from(e.file_name()))
        .filter(|p| p.extension().is_some_and(|e| e == "drv"))
        .map(|p| p.to_string_lossy().into_owned())
        .collect();
    on_disk.sort();
    let mut described: Vec<String> = intents().iter().map(|(n, _)| (*n).to_owned()).collect();
    described.sort();
    assert_eq!(on_disk, described);
}

#[test]
fn describing_the_intent_reproduces_nix_byte_for_byte() {
    // The exit test of Phase 1, in miniature. Structural equality would not do:
    // the bytes are hashed to produce the derivation's own store path.
    for (name, drv) in intents() {
        assert_eq!(drv.aterm(), golden(name), "{name}");
    }
}

#[test]
fn the_derivation_lands_at_its_own_store_path() {
    // Reproducing the CONTENT while computing the wrong path would mean the
    // text-kind store path rule is wrong, which nothing else here would catch.
    for (name, drv) in intents() {
        let base = drv.path().as_str().rsplit('/').next().expect("basename");
        assert_eq!(base, name);
    }
}

#[test]
fn output_paths_are_known_before_anything_is_built() {
    assert_eq!(
        hello().output("out").expect("out").as_str(),
        "/nix/store/mjs27ix6ig2bkbi3s3sm470vrv4lf7ic-hello"
    );
    assert!(
        multi()
            .output("dev")
            .expect("dev")
            .as_str()
            .ends_with("-multi-dev")
    );
    assert!(
        multi()
            .output("out")
            .expect("out")
            .as_str()
            .ends_with("-multi")
    );
}

#[test]
fn a_dependent_agrees_with_what_it_depends_on() {
    let a = dep_a();
    let d = dependent();
    let edges: Vec<_> = d.derivation().input_drvs.iter().map(|i| &i.path).collect();
    assert_eq!(edges, vec![a.path()]);
    assert!(d.derivation().args[1].contains(a.output("out").expect("out").as_str()));
}

// --------------------------------------------------------------------------
// outputs is an OPTION, and both cases occur in real nixpkgs
// --------------------------------------------------------------------------

#[test]
fn declaring_outputs_is_observable_in_the_bytes() {
    // A bare `derivation { ... }` emits no `outputs` env variable; a package
    // that writes `outputs = [ "out" ]` emits `("outputs","out")`. 96 of the
    // corpus's single-output derivations do the first and 605 do the second.
    let implicit = derivation(base("x")).expect("valid");
    let explicit = derivation(Build {
        outputs: Some(vec![OutputName::new("out")]),
        ..base("x")
    })
    .expect("valid");
    assert!(!implicit.aterm().contains("(\"outputs\""));
    assert!(explicit.aterm().contains("(\"outputs\",\"out\")"));
    assert_ne!(implicit.path(), explicit.path());
    assert_ne!(
        implicit.output("out").expect("out"),
        explicit.output("out").expect("out")
    );
}

#[test]
fn the_outputs_variable_keeps_declaration_order() {
    // The outputs LIST is sorted by name; the `outputs` env VARIABLE is in
    // declaration order. They differ in 575 of the 1197 real derivations that
    // declare outputs.
    let drv = multi();
    let names: Vec<&str> = drv
        .derivation()
        .outputs
        .iter()
        .map(|o| o.name.as_str())
        .collect();
    assert_eq!(names, vec!["dev", "lib", "out"]);
    let env: BTreeMap<&str, &str> = drv
        .derivation()
        .env
        .iter()
        .map(|(k, v)| (k.as_str(), v.as_str()))
        .collect();
    assert_eq!(env["outputs"], "out dev lib");
}

// --------------------------------------------------------------------------
// fixed-output derivations
// --------------------------------------------------------------------------

#[test]
fn a_hash_is_accepted_in_every_representation_nix_writes() {
    let digest: Vec<u8> = (0u8..32).collect();
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    let forms = [
        FixedOutput::new(hex.clone(), HashAlgo::Sha256),
        FixedOutput::new(base32(&digest), HashAlgo::Sha256),
        FixedOutput::sri(sri(&digest)),
    ];
    for f in &forms {
        assert_eq!(f.hash_field().expect("decodes"), hex);
    }
}

#[test]
fn the_output_path_does_not_depend_on_how_the_hash_was_written() {
    // Why every fetchurl in nixpkgs can share one cache entry: two
    // fixed-output derivations declaring the same BYTES are interchangeable
    // however differently they are expressed. The .drv path is not, because
    // the env keeps the hash verbatim.
    let digest: Vec<u8> = (0u8..32).collect();
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    let as_hex = derivation(Build {
        fixed_output: Some(FixedOutput::new(hex, HashAlgo::Sha256)),
        ..base("fetched")
    })
    .expect("valid");
    let as_sri = derivation(Build {
        fixed_output: Some(FixedOutput::sri(sri(&digest))),
        ..base("fetched")
    })
    .expect("valid");
    assert_eq!(
        as_hex.output("out").expect("out"),
        as_sri.output("out").expect("out")
    );
    assert_ne!(as_hex.path(), as_sri.path());
}

#[test]
fn recursive_ingestion_takes_a_different_path_scheme() {
    // `r:sha256` is the `source` kind with the declared hash used directly.
    // Exactly one derivation in a 226-derivation closure exercised this.
    let digest: Vec<u8> = (0u8..32).collect();
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    let flat = derivation(Build {
        fixed_output: Some(FixedOutput::new(hex.clone(), HashAlgo::Sha256)),
        ..base("f")
    })
    .expect("valid");
    let rec = derivation(Build {
        fixed_output: Some(FixedOutput::new(hex, HashAlgo::Sha256).recursive()),
        ..base("f")
    })
    .expect("valid");
    assert!(rec.aterm().contains("\"r:sha256\""));
    assert!(rec.aterm().contains("(\"outputHashMode\",\"recursive\")"));
    assert_ne!(
        flat.output("out").expect("out"),
        rec.output("out").expect("out")
    );
}

#[test]
fn an_sri_hash_emits_no_output_hash_algo() {
    // 11 of the 93 real fixed-output derivations omit it; matching matters.
    let drv = derivation(Build {
        fixed_output: Some(FixedOutput::sri(sri(&[0u8; 32]))),
        ..base("f")
    })
    .expect("valid");
    assert!(!drv.aterm().contains("outputHashAlgo"));
}

#[test]
fn the_hash_mode_is_a_type_not_a_string() {
    // Where Python needs a runtime check because `Literal` is erased, the enum
    // makes the wrong value unrepresentable. Recorded in the typing table.
    assert_eq!(HashMode::default(), HashMode::Flat);
    assert_eq!(HashAlgo::Sha256.digest_bytes(), 32);
}

// --------------------------------------------------------------------------
// invariants from spec/signature.md, enforced at construction
// --------------------------------------------------------------------------

#[test]
fn invalid_descriptions_are_rejected_at_construction() {
    let outs = |names: &[&str]| {
        Some(
            names
                .iter()
                .map(|n| OutputName::new(*n))
                .collect::<Vec<_>>(),
        )
    };

    assert_eq!(
        derivation(Build {
            outputs: Some(vec![]),
            ..base("x")
        }),
        Err(InvalidDerivation::EmptyOutputs)
    );
    assert!(matches!(
        derivation(Build {
            outputs: outs(&["out", "out"]),
            ..base("x")
        }),
        Err(InvalidDerivation::DuplicateOutputs(_))
    ));
    assert!(matches!(
        derivation(Build {
            outputs: outs(&["out", "dev"]),
            fixed_output: Some(FixedOutput::new("0".repeat(64), HashAlgo::Sha256)),
            ..base("x")
        }),
        Err(InvalidDerivation::FixedNeedsOneOutput(_))
    ));
    for key in ["name", "out", "outputHash", "system", "builder", "outputs"] {
        assert!(
            matches!(
                derivation(Build {
                    env: BTreeMap::from([(key.to_owned(), "x".to_owned())]),
                    ..base("x")
                }),
                Err(InvalidDerivation::ReservedEnvKeys(_))
            ),
            "{key} should be reserved"
        );
    }
}

#[test]
fn invalid_names_are_rejected() {
    for bad in ["", ".", "..", ".hidden", "a b", "a/b", &"x".repeat(212)] {
        assert!(!valid_name(bad), "{bad:?}");
        assert!(matches!(
            derivation(base(bad)),
            Err(InvalidDerivation::Name(_))
        ));
    }
}

#[test]
fn names_real_packages_use_are_accepted() {
    for good in [
        "hello",
        "hello-1.0",
        "a+b",
        "x_y",
        "q?",
        "n=1",
        &"x".repeat(211),
    ] {
        assert!(valid_name(good), "{good:?}");
    }
}

#[test]
fn asking_for_an_output_that_does_not_exist_fails() {
    assert!(matches!(
        hello().output("dev"),
        Err(InvalidDerivation::NoSuchOutput { .. })
    ));
    assert!(matches!(
        hello().needs(&["dev"]),
        Err(InvalidDerivation::NoSuchOutput { .. })
    ));
}

#[test]
fn bad_hashes_are_rejected() {
    // The enum already rules out an unknown ALGORITHM, which Python has to
    // check at runtime. What is left to check is the hash itself.
    assert!(
        FixedOutput::new("0".repeat(63), HashAlgo::Sha256)
            .resolved()
            .is_err()
    );
    assert!(FixedOutput::sri("0".repeat(64)).resolved().is_err());
    assert!(
        FixedOutput::sri(format!("sha512-{}", b64(&[0u8; 32])))
            .resolved()
            .is_err()
    );
    assert!(FixedOutput::sri("sha3-AAAA").resolved().is_err());
}

#[test]
fn one_edge_per_dependency_however_often_it_is_named() {
    let m = multi();
    let drv = derivation(Build {
        input_drvs: vec![
            m.needs(&["dev"]).expect("dev"),
            m.needs(&["lib"]).expect("lib"),
            m.needs(&["dev"]).expect("dev"),
        ],
        ..base("user")
    })
    .expect("valid");
    assert_eq!(drv.derivation().input_drvs.len(), 1);
    let names: Vec<&str> = drv.derivation().input_drvs[0]
        .outputs
        .iter()
        .map(|n| n.as_str())
        .collect();
    assert_eq!(names, vec!["dev", "lib"]);
}

#[test]
fn what_the_edsl_builds_is_canonical() {
    for (name, drv) in intents() {
        assert_eq!(canonical(drv.derivation()), *drv.derivation(), "{name}");
    }
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

fn sri(digest: &[u8]) -> String {
    format!("sha256-{}", b64(digest))
}
