//! The surface: build Nix expressions in Rust.
//!
//! This is what a developer writes instead of learning the Nix language. It
//! hands back [`Expr`] values, the inspectable core, so everything downstream
//! works on data rather than on host closures.
//!
//! # Binders are HOAS here and named underneath
//!
//! A lambda is written with a Rust closure:
//!
//! ```
//! use img_drv::nix::surface::{attrs, lam, to_nix};
//!
//! let f = lam("x", |x| attrs(vec![("name", x)]));
//! assert_eq!(to_nix(&f), "(x1: { name = x1; })");
//! ```
//!
//! which is what makes it composable and frees the caller from inventing
//! names. [`lam`] lowers that to a NAMED binder immediately, with a fresh
//! supply, because the printer needs a name to print. That two-layer split is
//! the recommendation in `docs/theory.md` section 8, and this module is the
//! only place in the crate that ever sees a host closure.
//!
//! # The fresh supply, and what Rust makes explicit
//!
//! The other three implementations keep the counter as ambient module state.
//! Rust will not: a mutable `static` needs `unsafe`, so the supply is a
//! [`Cell`] in thread-local storage. That is the safe idiom rather than a
//! workaround, and it makes visible what the other three leave implicit, which
//! is that the surface is stateful and that two threads building terms
//! concurrently must not share a counter.

use std::cell::Cell;

use super::ast::{Attr, Binding, Expr, Op, Part, Pattern};
use super::emit;

thread_local! {
    static COUNTER: Cell<u64> = const { Cell::new(0) };
}

/// Restart the fresh-name supply, so a term prints identically twice.
pub fn reset() {
    COUNTER.with(|c| c.set(0));
}

fn fresh(base: &str) -> String {
    COUNTER.with(|c| {
        c.set(c.get() + 1);
        format!("{base}{}", c.get())
    })
}

/// The AST as Nix source.
pub fn to_nix(e: &Expr) -> String {
    emit::to_nix(e)
}

// Literals

/// An integer literal.
pub fn int(n: i64) -> Expr {
    Expr::Int(n)
}

/// A float literal.
pub fn float(f: f64) -> Expr {
    Expr::Float(f)
}

/// A plain string literal.
pub fn str_(s: &str) -> Expr {
    Expr::Str(vec![Part::Lit(s.to_string())])
}

/// A path literal.
pub fn path(p: &str) -> Expr {
    Expr::Path(p.to_string())
}

/// `<nixpkgs>`, a search-path lookup.
///
/// Impure: it reads NIX_PATH when evaluated, which is why a reproducible caller
/// pins it.
pub fn spath(p: &str) -> Expr {
    Expr::SearchPath(p.to_string())
}

/// A variable reference.
pub fn var(x: &str) -> Expr {
    Expr::Var(x.to_string())
}

/// `true` or `false`, which are ordinary variables in Nix.
pub fn boolean(b: bool) -> Expr {
    Expr::Var(if b { "true" } else { "false" }.to_string())
}

/// `null`, likewise an ordinary variable.
pub fn null() -> Expr {
    Expr::Var("null".to_string())
}

/// One piece of an interpolated string.
pub enum Piece<'a> {
    /// Literal text.
    S(&'a str),
    /// An interpolated expression.
    E(Expr),
}

/// An interpolated string: `istr(vec![S("a"), E(e), S("c")])` is `"a${e}c"`.
pub fn istr(pieces: Vec<Piece<'_>>) -> Expr {
    Expr::Str(
        pieces
            .into_iter()
            .map(|p| match p {
                Piece::S(s) => Part::Lit(s.to_string()),
                Piece::E(e) => Part::Anti(e),
            })
            .collect(),
    )
}

// Structure

/// A list literal.
pub fn list(items: Vec<Expr>) -> Expr {
    Expr::List(items)
}

fn binds(pairs: Vec<(&str, Expr)>) -> Vec<Binding> {
    pairs
        .into_iter()
        .map(|(k, v)| Binding::Bind(vec![Attr::Id(k.to_string())], v))
        .collect()
}

/// An attribute set. Declaration order is preserved, as Nix source is.
pub fn attrs(pairs: Vec<(&str, Expr)>) -> Expr {
    Expr::AttrSet {
        recursive: false,
        binds: binds(pairs),
    }
}

/// A recursive attribute set: bindings can refer to each other by name.
pub fn rec_attrs(pairs: Vec<(&str, Expr)>) -> Expr {
    Expr::AttrSet {
        recursive: true,
        binds: binds(pairs),
    }
}

/// `e.a.b`
pub fn select(e: Expr, names: &[&str]) -> Expr {
    Expr::Select(
        Box::new(e),
        names.iter().map(|n| Attr::Id(n.to_string())).collect(),
        None,
    )
}

/// `e.a.b or default`
pub fn select_or(e: Expr, names: &[&str], default: Expr) -> Expr {
    Expr::Select(
        Box::new(e),
        names.iter().map(|n| Attr::Id(n.to_string())).collect(),
        Some(Box::new(default)),
    )
}

/// Curried application: `apply(f, vec![a, b])` is `((f a) b)`.
pub fn apply(f: Expr, args: Vec<Expr>) -> Expr {
    args.into_iter()
        .fold(f, |acc, a| Expr::Apply(Box::new(acc), Box::new(a)))
}

// Binders

/// A lambda, written with a Rust closure.
///
/// The bound variable is materialised as a fresh NAME, so the result is
/// ordinary inspectable syntax rather than a closure.
pub fn lam(name: &str, f: impl FnOnce(Expr) -> Expr) -> Expr {
    let n = fresh(name);
    let body = f(Expr::Var(n.clone()));
    Expr::Lambda(Pattern::Var(n), Box::new(body))
}

/// A lambda taking an attribute set, `{ a, b ? d }: body`.
///
/// The body receives a LOOKUP function rather than a struct, because the
/// formals are named by the caller at runtime and no host type can give them
/// back as fields.
pub fn lam_attrs(
    formals: Vec<(String, Option<Expr>)>,
    ellipsis: bool,
    f: impl FnOnce(&dyn Fn(&str) -> Expr) -> Expr,
) -> Expr {
    let body = f(&|name: &str| Expr::Var(name.to_string()));
    Expr::Lambda(
        Pattern::Set {
            formals,
            ellipsis,
            alias: None,
        },
        Box::new(body),
    )
}

/// `let a = ...; in body`, with the bindings in scope in each other.
pub fn let_(pairs: Vec<(&str, Expr)>, body: Expr) -> Expr {
    Expr::Let(binds(pairs), Box::new(body))
}

/// Bind one value and use it, without naming it.
///
/// The composable form: the caller never sees the generated name, so two
/// independently written fragments cannot capture each other's variables.
pub fn let_in(name: &str, value: Expr, f: impl FnOnce(Expr) -> Expr) -> Expr {
    let n = fresh(name);
    let body = f(Expr::Var(n.clone()));
    Expr::Let(
        vec![Binding::Bind(vec![Attr::Id(n)], value)],
        Box::new(body),
    )
}

// Operators

/// `a + b`
pub fn plus(a: Expr, b: Expr) -> Expr {
    Expr::Op(Op::Add, Box::new(a), Box::new(b))
}

/// `a // b`: b wins on a clash.
pub fn update(a: Expr, b: Expr) -> Expr {
    Expr::Op(Op::Update, Box::new(a), Box::new(b))
}

/// `a ++ b`
pub fn concat(a: Expr, b: Expr) -> Expr {
    Expr::Op(Op::Concat, Box::new(a), Box::new(b))
}

/// `a == b`
pub fn eq(a: Expr, b: Expr) -> Expr {
    Expr::Op(Op::Eq, Box::new(a), Box::new(b))
}

/// `if c then t else f`
pub fn if_(c: Expr, t: Expr, f: Expr) -> Expr {
    Expr::If(Box::new(c), Box::new(t), Box::new(f))
}

// Composability: overlays as mixins

/// An overlay: `final: prev: { ... }`.
///
/// Cook and Palsberg's wrapper over a generator (`docs/theory.md` section 8),
/// and [`fix`] is the map out of it.
///
/// Overlays form a MONOID under [`compose`], but only UP TO NIX SEMANTICS, not
/// up to syntax. `compose(overlay_id, o)` emits `({ } // o)` rather than `o`,
/// and the two bracketings of `compose` nest `//` differently; those terms are
/// equal when Nix evaluates them and are not equal as syntax. See
/// `docs/abstractions.md` entry 11.
pub type Overlay = Box<dyn Fn(&Expr, &Expr) -> Expr>;

/// The identity overlay: adds nothing.
pub fn overlay_id() -> Overlay {
    Box::new(|_final, _prev| attrs(vec![]))
}

/// Apply `a` first, then `b` on top, so `b` wins on a clash.
///
/// That matches how a later overlay in a list overrides an earlier one.
pub fn compose(a: Overlay, b: Overlay) -> Overlay {
    Box::new(move |final_, prev| {
        let after_a = a(final_, prev);
        let seen = update(prev.clone(), after_a.clone());
        update(after_a, b(final_, &seen))
    })
}

/// Fold a list of overlays into one.
pub fn compose_all(overlays: Vec<Overlay>) -> Overlay {
    overlays.into_iter().fold(overlay_id(), compose)
}

/// Close an overlay into a package set with the knot tied.
///
/// Emits `(let base = ...; final = base // (overlay final base); in final)`:
/// the fixed point is written OUT in Nix rather than computed here, because the
/// point of a transpiler is that the output does the work.
///
/// `base` is BOUND, not inlined. `fix` passes it to the overlay as `prev` as
/// well as using it on the left of `//`, so inlining it would duplicate the
/// whole expression into the output, once per mention. The hand-written Nix a
/// reader would compare against binds it too.
pub fn fix(base: Expr, o: &Overlay) -> Expr {
    let b = fresh("base");
    let n = fresh("final");
    let added = o(&Expr::Var(n.clone()), &Expr::Var(b.clone()));
    Expr::Let(
        vec![
            Binding::Bind(vec![Attr::Id(b.clone())], base),
            Binding::Bind(vec![Attr::Id(n.clone())], update(Expr::Var(b), added)),
        ],
        Box::new(Expr::Var(n)),
    )
}
