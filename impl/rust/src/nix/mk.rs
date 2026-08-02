//! Small constructors the grammar actions call.
//!
//! They live here rather than in `grammar.lalrpop` because a LALRPOP file holds
//! grammar declarations and a `use` prelude only, with no room for ordinary
//! Rust items. Keeping them out also lets the actions read as grammar instead
//! of as code.

use super::ast::{Expr, Op, Pattern};

/// A binary operator application, boxing both sides.
pub fn bin(op: Op, a: Expr, b: Expr) -> Expr {
    Expr::Op(op, Box::new(a), Box::new(b))
}

/// Cons, for the right-recursive list rules.
pub fn prepend<T>(head: T, mut rest: Vec<T>) -> Vec<T> {
    rest.insert(0, head);
    rest
}

/// The pattern `{}` denotes before a `:`.
pub fn empty_set(alias: Option<String>) -> Pattern {
    Pattern::Set {
        formals: vec![],
        ellipsis: false,
        alias,
    }
}

/// Attach an `@ name` alias to a set pattern.
pub fn alias(p: Pattern, name: String) -> Pattern {
    match p {
        Pattern::Set {
            formals, ellipsis, ..
        } => Pattern::Set {
            formals,
            ellipsis,
            alias: Some(name),
        },
        other => other,
    }
}
