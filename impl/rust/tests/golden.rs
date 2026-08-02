//! The regression gate: real derivations, produced by real Nix.
//!
//! Examples written by hand test the cases you already thought of, which is
//! precisely the set that is already right. Every time hand-written examples
//! and real derivations have disagreed in this repository, the hand-written
//! ones were wrong.

use std::path::{Path, PathBuf};

use img_drv::{Corpus, StorePath, canonical, name_from_path, parse, unparse};

fn golden_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docs/spec/examples")
}

fn golden_files() -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = std::fs::read_dir(golden_dir())
        .expect("golden directory")
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "drv"))
        .collect();
    out.sort();
    out
}

#[test]
fn the_examples_are_present() {
    // A corpus that silently vanished would make everything below pass.
    assert!(golden_files().len() >= 10);
}

#[test]
fn round_trips_byte_identically() {
    // Byte equality, not structural equality: the bytes ARE the artifact,
    // since the derivation's own store path is their hash.
    for path in golden_files() {
        let text = std::fs::read_to_string(&path).expect("readable");
        let text = text.trim_end_matches('\n');
        let drv = parse(text).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        assert_eq!(unparse(&drv), text, "{}", path.display());
    }
}

#[test]
fn every_output_path_recomputes() {
    // The whole specification, end to end, on vectors nobody wrote by hand.
    let corpus = Corpus::from_directory(&golden_dir()).expect("loadable");
    let (checked, mismatches) = corpus.verify();
    assert!(checked >= 12, "checked {checked}");
    assert!(
        mismatches.is_empty(),
        "{}",
        mismatches
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join("\n")
    );
}

#[test]
fn real_derivations_are_already_canonical() {
    // If canonicalizing a real derivation changed it, our ordering rules would
    // merely be self-consistent, and every claim about byte-identity across
    // languages would be about our own convention rather than about Nix's.
    for path in golden_files() {
        let text = std::fs::read_to_string(&path).expect("readable");
        let drv = parse(&text).expect("parses");
        assert_eq!(canonical(&drv), drv, "{}", path.display());
    }
}

#[test]
fn input_hashing_is_memoized_and_stable() {
    // Same question, same answer: hashing is a function, not a process.
    let corpus = Corpus::from_directory(&golden_dir()).expect("loadable");
    let path = corpus.drvs.keys().next().expect("non-empty").clone();
    assert_eq!(corpus.input_hash(&path), corpus.input_hash(&path));
}

#[test]
fn name_comes_from_the_store_path_prefix() {
    let path = StorePath::new(format!("/nix/store/{}-hello.drv", "a".repeat(32)));
    assert_eq!(name_from_path(&path, None), "hello");
    // Not a store path: falls back rather than returning nonsense.
    assert_eq!(
        name_from_path(&StorePath::new("./whatever.drv"), None),
        "whatever"
    );
}
