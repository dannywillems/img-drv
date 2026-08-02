//! What [`super::emit`] forgets, named precisely.
//!
//! `emit` and `parse` are the two arrows between EXPR and source text. Their
//! law is a RETRACTION, `parse(emit(e)) == e`, but it does not hold on the
//! nose, and the three things it holds only up to are worth naming rather than
//! hiding, because each one says something about Nix.
//!
//! # Literal CHUNKING carries no meaning
//!
//! Nix's lexer splits a string into chunks at boundaries that depend on which
//! ESCAPES were used, not on the value: an escaped dollar between two words
//! gives three parts, and the same characters written plainly give one.
//! `nix-instantiate --parse` shows that difference, printing
//! `("a" + "$" + "b")` for the first and `"a$b"` for the second, and Nix
//! EVALUATES both identically.
//!
//! So the debug form our differential oracle compares against is FINER than
//! semantic equality. That is what we want for testing a parser, since it pins
//! more; it means the round-trip law has to be stated in the quotient, because
//! `emit` writes the characters and cannot write the chunking.
//!
//! # An indented string stops existing at parse time
//!
//! Nix has no indented-string node: `''a''` is an `ExprString` once the dedent
//! has run, and the indentation is gone for good. [`Expr::IndStr`] is our
//! invention and holds nothing that could write the original back.
//!
//! # A URI literal is a string
//!
//! `x:x` is a URI to the LEXER, which is why it is not a lambda, and `--parse`
//! prints it as `"x:x"`. Nix keeps no URI node either.
//!
//! All three quotients are semantic no-ops, and each names a node WE invented
//! that Nix does not keep. Normalising by them is the honest statement of the
//! law, not a way of making a failing test pass; that all three are our own
//! inventions is itself the finding.

use super::ast::{Attr, AttrPath, Binding, Expr, Part, Pattern};

fn parts(input: &[Part]) -> Vec<Part> {
    let mut out: Vec<Part> = Vec::with_capacity(input.len());
    for p in input {
        match p {
            Part::Anti(e) => out.push(Part::Anti(expr(e))),
            Part::Lit(s) => match out.last_mut() {
                Some(Part::Lit(prev)) => prev.push_str(s),
                _ => out.push(Part::Lit(s.clone())),
            },
        }
    }
    out
}

fn attr(a: &Attr) -> Attr {
    match a {
        Attr::Id(x) => Attr::Id(x.clone()),
        Attr::Str(ps) => Attr::Str(parts(ps)),
        Attr::Dyn(e) => Attr::Dyn(expr(e)),
    }
}

fn path(p: &AttrPath) -> AttrPath {
    p.iter().map(attr).collect()
}

fn binding(b: &Binding) -> Binding {
    match b {
        Binding::Bind(p, v) => Binding::Bind(path(p), expr(v)),
        Binding::Inherit(from, attrs) => {
            Binding::Inherit(from.as_ref().map(expr), attrs.iter().map(attr).collect())
        }
    }
}

fn pattern(p: &Pattern) -> Pattern {
    match p {
        Pattern::Var(x) => Pattern::Var(x.clone()),
        Pattern::Set {
            formals,
            ellipsis,
            alias,
        } => Pattern::Set {
            formals: formals
                .iter()
                .map(|(n, d)| (n.clone(), d.as_ref().map(expr)))
                .collect(),
            ellipsis: *ellipsis,
            alias: alias.clone(),
        },
    }
}

/// The normal form: literals joined, indented strings and URIs folded.
pub fn expr(e: &Expr) -> Expr {
    match e {
        Expr::Str(ps) => Expr::Str(parts(ps)),
        // Nix keeps no indented-string node past parsing, so neither does the
        // normal form.
        Expr::IndStr(ps) => Expr::Str(parts(ps)),
        Expr::PathInterp(ps) => Expr::PathInterp(parts(ps)),
        // Nix keeps no URI node either: `x:x` parses to a string.
        Expr::Uri(u) => Expr::Str(vec![Part::Lit(u.clone())]),
        Expr::Int(_) | Expr::Float(_) | Expr::Path(_) | Expr::SearchPath(_) | Expr::Var(_) => {
            e.clone()
        }
        Expr::Lambda(p, body) => Expr::Lambda(pattern(p), Box::new(expr(body))),
        Expr::Apply(f, a) => Expr::Apply(Box::new(expr(f)), Box::new(expr(a))),
        Expr::Select(e, p, d) => Expr::Select(
            Box::new(expr(e)),
            path(p),
            d.as_ref().map(|d| Box::new(expr(d))),
        ),
        Expr::HasAttr(e, p) => Expr::HasAttr(Box::new(expr(e)), path(p)),
        Expr::List(items) => Expr::List(items.iter().map(expr).collect()),
        Expr::AttrSet { recursive, binds } => Expr::AttrSet {
            recursive: *recursive,
            binds: binds.iter().map(binding).collect(),
        },
        Expr::Let(binds, body) => {
            Expr::Let(binds.iter().map(binding).collect(), Box::new(expr(body)))
        }
        Expr::With(s, body) => Expr::With(Box::new(expr(s)), Box::new(expr(body))),
        Expr::Assert(c, body) => Expr::Assert(Box::new(expr(c)), Box::new(expr(body))),
        Expr::If(c, t, f) => Expr::If(Box::new(expr(c)), Box::new(expr(t)), Box::new(expr(f))),
        Expr::Op(o, a, b) => Expr::Op(*o, Box::new(expr(a)), Box::new(expr(b))),
        Expr::Not(e) => Expr::Not(Box::new(expr(e))),
        Expr::Neg(e) => Expr::Neg(Box::new(expr(e))),
    }
}
