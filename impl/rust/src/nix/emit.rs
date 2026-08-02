//! Print an AST as valid Nix SOURCE. This is the transpiler.
//!
//! The arrow `EXPR -> .nix` of `docs/architecture.md`.
//!
//! Fully parenthesised, on purpose. Extra parentheses cannot change a parse, so
//! the emitted file is correct BY CONSTRUCTION rather than correct if the
//! precedence table was transcribed properly. `docs/nix-internals.md` records
//! two levels that surprise everyone (`!` binds looser than `+`, `//` tighter
//! than the comparisons); a minimal-parenthesis printer has to get both right
//! and this one cannot get them wrong.
//!
//! Making the output pretty is a separate, later job with its own test: emit,
//! re-parse, compare the ASTs.

use std::fmt::Write as _;

use super::ast::{Attr, AttrPath, Binding, Expr, Part, Pattern};

/// Escape a string's contents for a double-quoted Nix literal.
fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            // `${` in a literal must be escaped or Nix reads an interpolation.
            '$' => out.push_str("\\$"),
            c => out.push(c),
        }
    }
    out
}

fn parts(out: &mut String, parts: &[Part]) {
    out.push('"');
    for p in parts {
        match p {
            Part::Lit(s) => out.push_str(&escape(s)),
            Part::Anti(e) => {
                out.push_str("${");
                expr(out, e);
                out.push('}');
            }
        }
    }
    out.push('"');
}

fn attr(out: &mut String, a: &Attr) {
    match a {
        Attr::Id(name) => out.push_str(name),
        Attr::Str(ps) => match ps.as_slice() {
            [Part::Lit(s)] => {
                let _ = write!(out, "\"{}\"", escape(s));
            }
            _ => {
                out.push_str("${");
                parts(out, ps);
                out.push('}');
            }
        },
    }
}

fn attrpath(out: &mut String, path: &AttrPath) {
    for (i, a) in path.iter().enumerate() {
        if i > 0 {
            out.push('.');
        }
        attr(out, a);
    }
}

fn binding(out: &mut String, b: &Binding) {
    match b {
        Binding::Bind(path, value) => {
            attrpath(out, path);
            out.push_str(" = ");
            expr(out, value);
            out.push_str("; ");
        }
        Binding::Inherit(source, attrs) => {
            out.push_str("inherit");
            if let Some(e) = source {
                out.push_str(" (");
                expr(out, e);
                out.push(')');
            }
            for a in attrs {
                out.push(' ');
                attr(out, a);
            }
            out.push_str("; ");
        }
    }
}

fn pattern(out: &mut String, p: &Pattern) {
    match p {
        Pattern::Var(name) => out.push_str(name),
        Pattern::Set {
            formals,
            ellipsis,
            alias,
        } => {
            out.push_str("{ ");
            for (i, (name, default)) in formals.iter().enumerate() {
                if i > 0 {
                    out.push_str(", ");
                }
                out.push_str(name);
                if let Some(d) = default {
                    out.push_str(" ? ");
                    expr(out, d);
                }
            }
            if *ellipsis {
                out.push_str(if formals.is_empty() { "..." } else { ", ..." });
            }
            out.push_str(" }");
            if let Some(a) = alias {
                let _ = write!(out, " @ {a}");
            }
        }
    }
}

fn expr(out: &mut String, e: &Expr) {
    match e {
        Expr::Int(n) => {
            let _ = write!(out, "{n}");
        }
        Expr::Float(f) => {
            let _ = write!(out, "{f}");
        }
        Expr::Var(x) => out.push_str(x),
        Expr::Path(p) => out.push_str(p),
        Expr::SearchPath(p) => {
            let _ = write!(out, "<{p}>");
        }
        Expr::Uri(u) => {
            let _ = write!(out, "\"{}\"", escape(u));
        }
        Expr::Str(ps) | Expr::IndStr(ps) => parts(out, ps),
        Expr::Not(e) => {
            out.push_str("(!");
            expr(out, e);
            out.push(')');
        }
        Expr::Neg(e) => {
            out.push_str("(-");
            expr(out, e);
            out.push(')');
        }
        Expr::Op(op, a, b) => {
            out.push('(');
            expr(out, a);
            let _ = write!(out, " {} ", op.text());
            expr(out, b);
            out.push(')');
        }
        Expr::HasAttr(e, path) => {
            out.push('(');
            expr(out, e);
            out.push_str(" ? ");
            attrpath(out, path);
            out.push(')');
        }
        Expr::Apply(f, a) => {
            out.push('(');
            expr(out, f);
            out.push(' ');
            expr(out, a);
            out.push(')');
        }
        Expr::Select(e, path, default) => {
            out.push('(');
            expr(out, e);
            out.push('.');
            attrpath(out, path);
            if let Some(d) = default {
                out.push_str(" or ");
                expr(out, d);
            }
            out.push(')');
        }
        Expr::Lambda(p, body) => {
            out.push('(');
            pattern(out, p);
            out.push_str(": ");
            expr(out, body);
            out.push(')');
        }
        Expr::List(items) => {
            out.push_str("[ ");
            for i in items {
                expr(out, i);
                out.push(' ');
            }
            out.push(']');
        }
        Expr::AttrSet { recursive, binds } => {
            if *recursive {
                out.push_str("rec ");
            }
            out.push_str("{ ");
            for b in binds {
                binding(out, b);
            }
            out.push('}');
        }
        Expr::Let(binds, body) => {
            out.push_str("(let ");
            for b in binds {
                binding(out, b);
            }
            out.push_str("in ");
            expr(out, body);
            out.push(')');
        }
        Expr::With(scope, body) => {
            out.push_str("(with ");
            expr(out, scope);
            out.push_str("; ");
            expr(out, body);
            out.push(')');
        }
        Expr::Assert(c, body) => {
            out.push_str("(assert ");
            expr(out, c);
            out.push_str("; ");
            expr(out, body);
            out.push(')');
        }
        Expr::If(c, t, f) => {
            out.push_str("(if ");
            expr(out, c);
            out.push_str(" then ");
            expr(out, t);
            out.push_str(" else ");
            expr(out, f);
            out.push(')');
        }
    }
}

/// The AST as Nix source.
pub fn to_nix(e: &Expr) -> String {
    let mut out = String::with_capacity(512);
    expr(&mut out, e);
    out
}
