//! Command line entry points, so CI and a laptop run the same code.
//!
//! ```text
//! img-drv verify <dir>      recompute every store path
//! img-drv roundtrip <dir>   parse then re-serialize, byte for byte
//! img-drv canonical <dir>   canonicalizing must change nothing
//! img-drv examples <dir>    emit the conformance corpus
//! ```
//!
//! All exit non-zero on any failure, which is what makes them usable as CI
//! gates. The subcommands and their output match the Python implementation's,
//! so the same Makefile target can drive either.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use img_drv::{Corpus, canonical, examples::corpus, parse, unparse};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [command, directory] = args.as_slice() else {
        eprintln!("usage: img-drv [verify|roundtrip|canonical|examples] <directory>");
        return ExitCode::from(2);
    };
    let directory = PathBuf::from(directory);
    if command != "examples" && !directory.is_dir() {
        eprintln!("not a directory: {}", directory.display());
        return ExitCode::from(2);
    }
    let code = match command.as_str() {
        "verify" => verify(&directory),
        "roundtrip" => roundtrip(&directory),
        "canonical" => canonical_check(&directory),
        "examples" => emit_examples(&directory),
        other => {
            eprintln!("unknown command: {other}");
            return ExitCode::from(2);
        }
    };
    match code {
        Ok(0) => ExitCode::SUCCESS,
        Ok(_) => ExitCode::FAILURE,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::from(2)
        }
    }
}

type Outcome = Result<u8, Box<dyn std::error::Error>>;

fn verify(directory: &Path) -> Outcome {
    let corpus = Corpus::from_directory(directory)?;
    let (checked, bad) = corpus.verify();
    for m in &bad {
        println!("FAIL {m}");
    }
    println!(
        "{}/{} output paths reproduced from {} derivations",
        checked - bad.len(),
        checked,
        corpus.len()
    );
    Ok(u8::from(!bad.is_empty()))
}

fn roundtrip(directory: &Path) -> Outcome {
    let (mut ok, mut bad) = (0usize, 0usize);
    for path in drv_files(directory)? {
        let name = file_name(&path);
        let text = std::fs::read_to_string(&path)?;
        let text = text.trim_end_matches('\n');
        match parse(text) {
            Ok(drv) if unparse(&drv) == text => ok += 1,
            Ok(_) => {
                bad += 1;
                println!("ROUND-TRIP DIFFERS: {name}");
            }
            Err(e) => {
                bad += 1;
                println!("PARSE ERROR {name}: {e}");
            }
        }
    }
    println!("{ok}/{} round-tripped byte-identically", ok + bad);
    Ok(u8::from(bad > 0))
}

fn canonical_check(directory: &Path) -> Outcome {
    let (mut ok, mut bad) = (0usize, 0usize);
    for path in drv_files(directory)? {
        let text = std::fs::read_to_string(&path)?;
        let drv = parse(&text)?;
        if canonical(&drv) == drv {
            ok += 1;
        } else {
            bad += 1;
            println!("NOT CANONICAL: {}", file_name(&path));
        }
    }
    println!("{ok}/{} real derivations are already canonical", ok + bad);
    Ok(u8::from(bad > 0))
}

/// Emit every intent in the conformance corpus, named as in the store.
///
/// The FILENAME is the derivation's own computed store path, so a wrong hash
/// shows up as a differently named file rather than as differing content, and
/// `make conformance` catches both.
fn emit_examples(directory: &Path) -> Outcome {
    std::fs::create_dir_all(directory)?;
    let corpus = corpus();
    for (_, drv) in &corpus {
        drv.write(directory)?;
    }
    println!(
        "{} derivations written to {}",
        corpus.len(),
        directory.display()
    );
    Ok(0)
}

fn drv_files(directory: &Path) -> Result<Vec<PathBuf>, std::io::Error> {
    let mut out: Vec<PathBuf> = std::fs::read_dir(directory)?
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "drv"))
        .collect();
    out.sort();
    Ok(out)
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}
