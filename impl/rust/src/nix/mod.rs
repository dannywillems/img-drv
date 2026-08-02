//! The Nix EXPRESSION layer: write Nix in Rust, print `.nix`.
//!
//! This is the second of the two term algebras in `docs/architecture.md`. The
//! rest of the crate is the FIRST-ORDER one (derivations, ATerm, store paths);
//! this module is the SECOND-ORDER one, because Nix expressions have binders
//! and derivations do not.
//!
//! It depends on the rest of the crate and the rest never depends on it, which
//! is the rule that keeps a bug in the expression layer from being able to
//! change a store path.
//!
//! Nothing here needs a parser. The transpiler is only the arrow `EXPR ->
//! .nix`, so it is [`ast`], [`emit`] and [`surface`] alone; LALRPOP arrives
//! with the arrow the other way and is not a dependency of this module.

pub mod ast;
pub mod emit;
pub mod surface;
pub mod transpile_examples;

pub use ast::Expr;
pub use emit::to_nix;
