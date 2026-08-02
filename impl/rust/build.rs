//! Generate the Nix parser from `src/nix/grammar.lalrpop`.
//!
//! LALRPOP runs at BUILD time and emits ordinary Rust, so the published crate
//! carries the generated parser and not the generator. Contrast Python, where
//! PLY builds its tables at import time and is therefore a runtime dependency.

fn main() {
    lalrpop::process_root().expect("lalrpop");
}
