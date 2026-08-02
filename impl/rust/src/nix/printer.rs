//! Print an AST the way `nix-instantiate --parse` does.
//!
//! This exists to be DIFFERENTIALLY TESTED. Nix re-prints the tree it parsed,
//! fully parenthesised and partly desugared, so matching its output byte for
//! byte over real files proves our tree has the same SHAPE as Nix's, which is
//! far stronger than "it parsed".
//!
//! Not to be confused with [`super::emit`], which writes `.nix` source a human
//! reads and Nix evaluates. This one writes Nix's debug form.
//!
//! The desugarings are Nix's, not ours: `a * b` prints as `(__mul a b)`,
//! `a - b` as `(__sub a b)` while `a + b` keeps its `+`, unary minus as
//! `(__sub 0 a)`, an interpolated string as a `+` chain, and a constant dynamic
//! attribute `${"c"}` folds to a plain `c`.
//!
//! Everything about ORDER and QUOTING was established by probing the pinned
//! Nix, never from memory; `docs/abstractions.md` entry 13 lists the eight
//! rules and how each was found.

use std::fmt::Write as _;

use super::ast::{Attr, AttrPath, Binding, Expr, Op, Part, Pattern};

const KEYWORDS: [&str; 9] = [
    "if", "then", "else", "assert", "with", "let", "in", "rec", "inherit",
];

/// Escape a string literal the way Nix prints one.
///
/// Five ordinary escapes plus a sixth that only fires in context: a `$` is
/// escaped ONLY when it begins an interpolation, so `"a$b"` prints unescaped
/// and a literal `${` prints as `\${`. Escaping every dollar would be valid Nix
/// and would not be what `--parse` emits.
fn escape(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len() + 2);
    for (i, c) in chars.iter().enumerate() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '$' if chars.get(i + 1) == Some(&'{') => out.push_str("\\$"),
            c => out.push(*c),
        }
    }
    out
}

fn is_identifier(s: &str) -> bool {
    let mut chars = s.chars();
    match chars.next() {
        None => false,
        Some(c) if c.is_ascii_alphabetic() || c == '_' => {
            chars.all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '\'' || c == '-')
        }
        Some(_) => false,
    }
}

/// An attribute name: bare when it is an identifier, quoted otherwise.
///
/// A keyword is quoted even though it looks like an identifier, because a bare
/// one would not parse back. `or` is the exception: Nix's grammar admits it as
/// an attribute name and prints it bare.
fn name(s: &str) -> String {
    if is_identifier(s) && !KEYWORDS.contains(&s) {
        s.to_string()
    } else {
        format!("\"{}\"", escape(s))
    }
}

/// One entry of a bind tree.
///
/// `dynamic` matters because Nix keeps static and dynamic attributes in two
/// different containers, a sorted map and a source-order vector, and prints the
/// map first.
#[derive(Debug, Clone)]
enum Item {
    Attr {
        key: String,
        dynamic: bool,
        entry: Entry,
    },
    Inherit(Option<Expr>, Vec<Attr>),
}

#[derive(Debug, Clone)]
enum Entry {
    Value(Expr),
    Nested(Vec<Item>),
}

/// The RAW name, because Nix merges and sorts by SYMBOL.
///
/// Sorting by the printed form puts every quoted name before every bare one,
/// since a quote sorts below a letter. Quoting is applied at print time.
fn key_of(a: &Attr) -> String {
    match a {
        Attr::Id(x) => x.clone(),
        Attr::Str(parts) => match parts.as_slice() {
            [Part::Lit(s)] => s.clone(),
            _ => attr(a),
        },
        Attr::Dyn(Expr::Str(parts)) => match parts.as_slice() {
            [Part::Lit(s)] => s.clone(),
            _ => attr(a),
        },
        _ => attr(a),
    }
}

fn is_dynamic(a: &Attr) -> bool {
    match a {
        Attr::Id(_) => false,
        Attr::Str(parts) => parts.iter().any(|p| matches!(p, Part::Anti(_))),
        Attr::Dyn(Expr::Str(parts)) => !matches!(parts.as_slice(), [Part::Lit(_)]),
        Attr::Dyn(_) => true,
    }
}

/// The bindings of an attribute-set value, for the merge cases.
///
/// The recursive flag is accepted and dropped, which is what Nix does:
/// `{ a = { b = 1; }; a = rec { c = 2; }; }` prints as one NON-recursive set.
fn set_binds(e: &Expr) -> Option<&[Binding]> {
    match e {
        Expr::AttrSet { binds, .. } => Some(binds),
        _ => None,
    }
}

fn group_binds(binds: &[Binding]) -> Vec<Item> {
    add_binds(Vec::new(), binds)
}

fn add_binds(mut items: Vec<Item>, binds: &[Binding]) -> Vec<Item> {
    for b in binds {
        match b {
            Binding::Bind(path, value) => items = insert(items, path, value),
            Binding::Inherit(from, attrs) => {
                items.push(Item::Inherit(from.clone(), attrs.clone()));
            }
        }
    }
    items
}

/// Expand a dotted binding into nested sets and merge shared prefixes.
///
/// `{ a.b.c = 1; }` becomes `{ a = { b = { c = 1; }; }; }` and
/// `{ a.b = 1; a.c = 2; }` becomes `{ a = { b = 1; c = 2; }; }`, because Nix
/// does that at parse time.
fn insert(mut items: Vec<Item>, path: &AttrPath, value: &Expr) -> Vec<Item> {
    let Some(head) = path.first() else {
        return items;
    };
    let key = key_of(head);
    let dynamic = is_dynamic(head);

    if path.len() == 1 {
        // A leaf whose value is a set MERGES into an entry the dotted bindings
        // already opened, and TWO set-valued bindings with the same name merge
        // too. Nix rejects a duplicate scalar and quietly joins duplicate sets,
        // which real modules rely on.
        for item in &mut items {
            if let Item::Attr {
                key: k,
                entry,
                dynamic: _,
            } = item
            {
                if *k != key {
                    continue;
                }
                let Some(new) = set_binds(value) else { break };
                match entry {
                    Entry::Nested(sub) => {
                        let merged = add_binds(std::mem::take(sub), new);
                        *entry = Entry::Nested(merged);
                        return items;
                    }
                    Entry::Value(old) => {
                        if let Some(old_binds) = set_binds(old) {
                            let base = group_binds(old_binds);
                            *entry = Entry::Nested(add_binds(base, new));
                            return items;
                        }
                        break;
                    }
                }
            }
        }
        items.push(Item::Attr {
            key,
            dynamic,
            entry: Entry::Value(value.clone()),
        });
        return items;
    }

    let rest: AttrPath = path[1..].to_vec();
    for item in &mut items {
        if let Item::Attr {
            key: k,
            entry,
            dynamic: _,
        } = item
        {
            if *k != key {
                continue;
            }
            match entry {
                Entry::Nested(sub) => {
                    let merged = insert(std::mem::take(sub), &rest, value);
                    *entry = Entry::Nested(merged);
                    return items;
                }
                // A leaf already holding a set is REOPENED rather than
                // shadowed, so a later dotted binding lands inside it.
                Entry::Value(old) => {
                    if let Some(old_binds) = set_binds(old) {
                        let base = group_binds(old_binds);
                        *entry = Entry::Nested(insert(base, &rest, value));
                        return items;
                    }
                    break;
                }
            }
        }
    }
    items.push(Item::Attr {
        key,
        dynamic,
        entry: Entry::Nested(insert(Vec::new(), &rest, value)),
    });
    items
}

/// Nix's print order for an attribute set or a `let`.
///
/// An attribute set is a SORTED map keyed by symbol, so bindings print in name
/// order rather than source order. Every PLAIN inherit merges into one
/// statement with its names sorted and comes FIRST; each `inherit (e)` group
/// keeps its identity and its source position; ordinary bindings follow,
/// sorted; dynamic names come last in SOURCE order, because they are a separate
/// container in Nix and not part of the sorted map.
fn order(items: &[Item]) -> Vec<&Item> {
    // Plain inherits are NOT here: they are merged into one statement and
    // rendered first by the caller, because they do not each keep an identity.
    let mut out: Vec<&Item> = Vec::with_capacity(items.len());
    let mut statics: Vec<&Item> = items
        .iter()
        .filter(|i| matches!(i, Item::Attr { dynamic: false, .. }))
        .collect();
    statics.sort_by(|a, b| match (a, b) {
        (Item::Attr { key: x, .. }, Item::Attr { key: y, .. }) => x.cmp(y),
        _ => std::cmp::Ordering::Equal,
    });
    out.extend(
        items
            .iter()
            .filter(|i| matches!(i, Item::Inherit(Some(_), _))),
    );
    out.extend(statics);
    out.extend(
        items
            .iter()
            .filter(|i| matches!(i, Item::Attr { dynamic: true, .. })),
    );
    out
}

fn render_items(items: &[Item]) -> String {
    let mut out = String::new();
    let mut plain: Vec<Attr> = Vec::new();
    for item in items {
        if let Item::Inherit(None, attrs) = item {
            plain.extend(attrs.iter().cloned());
        }
    }
    if !plain.is_empty() {
        plain.sort_by_key(key_of);
        let names: String = plain.iter().map(|a| format!(" {}", attr(a))).collect();
        let _ = write!(out, "inherit{names}; ");
    }
    for item in order(items) {
        match item {
            Item::Inherit(from, attrs) => {
                let mut sorted = attrs.clone();
                sorted.sort_by_key(key_of);
                let source = from
                    .as_ref()
                    .map(|e| format!(" ({})", expr(e)))
                    .unwrap_or_default();
                let names: String = sorted.iter().map(|a| format!(" {}", attr(a))).collect();
                let _ = write!(out, "inherit{source}{names}; ");
            }
            Item::Attr {
                key,
                dynamic,
                entry,
            } => {
                // The key held here is the RAW name, so quoting happens now: a
                // dynamic key is already printed syntax and goes out verbatim.
                let shown = if *dynamic { key.clone() } else { name(key) };
                match entry {
                    Entry::Value(e) => {
                        let _ = write!(out, "{shown} = {}; ", expr(e));
                    }
                    Entry::Nested(sub) => {
                        let _ = write!(out, "{shown} = {{ {}}}; ", render_items(sub));
                    }
                }
            }
        }
    }
    out
}

fn attr(a: &Attr) -> String {
    match a {
        Attr::Id(x) => name(x),
        Attr::Str(parts) => match parts.as_slice() {
            [Part::Lit(s)] => name(s),
            // A dynamic attribute becomes ONE interpolation wrapping the whole
            // string expression: `{ "a${m}b" = 1; }` prints as
            // `{ "${("a" + m + "b")}" = 1; }`.
            _ => format!("\"${{{}}}\"", string_parts(parts)),
        },
        // `a.${"c"}`: a constant string folds to a plain name, as `a."c"` does.
        Attr::Dyn(Expr::Str(parts)) if matches!(parts.as_slice(), [Part::Lit(_)]) => {
            match parts.as_slice() {
                [Part::Lit(s)] => name(s),
                _ => unreachable!(),
            }
        }
        // `a.${k}`: the expression IS the name, so a bare variable stays bare.
        Attr::Dyn(e) => format!("\"${{{}}}\"", expr(e)),
    }
}

fn attrpath(path: &AttrPath) -> String {
    path.iter().map(attr).collect::<Vec<_>>().join(".")
}

fn string_parts(parts: &[Part]) -> String {
    match parts {
        [] => "\"\"".to_string(),
        [Part::Lit(s)] => format!("\"{}\"", escape(s)),
        // An interpolated string is a `+` chain. No parentheses of our own: the
        // interpolated expression supplies its own.
        _ => {
            let pieces: Vec<String> = parts
                .iter()
                .map(|p| match p {
                    Part::Lit(s) => format!("\"{}\"", escape(s)),
                    Part::Anti(e) => expr(e),
                })
                .collect();
            format!("({})", pieces.join(" + "))
        }
    }
}

fn pattern(p: &Pattern) -> String {
    match p {
        Pattern::Var(x) => x.clone(),
        Pattern::Set {
            formals,
            ellipsis,
            alias,
        } => {
            // Formals are a sorted map too.
            let mut sorted = formals.clone();
            sorted.sort_by(|a, b| a.0.cmp(&b.0));
            let mut body: String = sorted
                .iter()
                .map(|(n, d)| match d {
                    None => n.clone(),
                    Some(e) => format!("{n} ? {}", expr(e)),
                })
                .collect::<Vec<_>>()
                .join(", ");
            if *ellipsis {
                body = if sorted.is_empty() {
                    "...".to_string()
                } else {
                    format!("{body}, ...")
                };
            }
            let tail = alias
                .as_ref()
                .map(|a| format!(" @ {a}"))
                .unwrap_or_default();
            format!("{{ {body} }}{tail}")
        }
    }
}

/// Application prints FLATTENED: `f 1 2` is one pair of parentheses.
fn apply(e: &Expr) -> String {
    match e {
        Expr::Apply(f, a) => format!("{} {}", apply(f), expr(a)),
        e => expr(e),
    }
}

fn expr(e: &Expr) -> String {
    match e {
        Expr::Int(n) => n.to_string(),
        // C's `%g`, which is what Nix uses: `3.0` prints as `3`.
        Expr::Float(f) => format_g(*f),
        Expr::Var(x) => x.clone(),
        Expr::Path(p) => p.clone(),
        Expr::PathInterp(parts) => string_parts(parts),
        // `<nixpkgs>` desugars to a search-path lookup, which is why a search
        // path is impure: it reads NIX_PATH at evaluation time.
        Expr::SearchPath(p) => {
            format!("(__findFile __nixPath \"{}\")", escape(p))
        }
        Expr::Uri(u) => format!("\"{}\"", escape(u)),
        Expr::Str(parts) | Expr::IndStr(parts) => string_parts(parts),
        Expr::Not(e) => format!("(! {})", expr(e)),
        Expr::Neg(e) => format!("(__sub 0 {})", expr(e)),
        Expr::Op(op, a, b) => match op {
            Op::Lt => format!("(__lessThan {} {})", expr(a), expr(b)),
            Op::Gt => format!("(__lessThan {} {})", expr(b), expr(a)),
            Op::Ge => format!("(! (__lessThan {} {}))", expr(a), expr(b)),
            Op::Le => format!("(! (__lessThan {} {}))", expr(b), expr(a)),
            Op::Sub => format!("(__sub {} {})", expr(a), expr(b)),
            Op::Mul => format!("(__mul {} {})", expr(a), expr(b)),
            Op::Div => format!("(__div {} {})", expr(a), expr(b)),
            op => format!("({} {} {})", expr(a), op.text(), expr(b)),
        },
        Expr::HasAttr(e, path) => {
            format!("(({}) ? {})", expr(e), attrpath(path))
        }
        Expr::Apply(f, a) => format!("({} {})", apply(f), expr(a)),
        Expr::Select(e, path, default) => {
            let head = format!("({}).{}", expr(e), attrpath(path));
            match default {
                None => head,
                Some(d) => format!("{head} or ({})", expr(d)),
            }
        }
        Expr::Lambda(p, body) => format!("({}: {})", pattern(p), expr(body)),
        Expr::List(items) => {
            let body: String = items.iter().map(|i| format!("({}) ", expr(i))).collect();
            format!("[ {body}]")
        }
        Expr::AttrSet { recursive, binds } => {
            let rec = if *recursive { "rec " } else { "" };
            format!("{rec}{{ {}}}", render_items(&group_binds(binds)))
        }
        Expr::Let(binds, body) => {
            format!(
                "(let {}in {})",
                render_items(&group_binds(binds)),
                expr(body)
            )
        }
        Expr::With(scope, body) => {
            format!("(with {}; {})", expr(scope), expr(body))
        }
        // Nix prints assert WITHOUT wrapping parentheses.
        Expr::Assert(c, body) => format!("assert {}; {}", expr(c), expr(body)),
        Expr::If(c, t, f) => {
            format!("(if {} then {} else {})", expr(c), expr(t), expr(f))
        }
    }
}

/// C's `%g`, which is what Nix's printer uses.
///
/// Rust has no `%g`, so it is reproduced: six significant digits, trailing
/// zeros removed, and an exponent when the magnitude leaves the fixed range.
fn format_g(f: f64) -> String {
    if f == 0.0 {
        return "0".to_string();
    }
    let exp = f.abs().log10().floor() as i32;
    if !(-4..6).contains(&exp) {
        let mantissa = f / 10f64.powi(exp);
        let m = trim_zeros(&format!("{mantissa:.5}"));
        let sign = if exp < 0 { '-' } else { '+' };
        format!("{m}e{sign}{:02}", exp.abs())
    } else {
        let decimals = (5 - exp).max(0) as usize;
        trim_zeros(&format!("{f:.decimals$}"))
    }
}

fn trim_zeros(s: &str) -> String {
    if s.contains('.') {
        s.trim_end_matches('0').trim_end_matches('.').to_string()
    } else {
        s.to_string()
    }
}

/// The AST, printed the way `nix-instantiate --parse` prints it.
pub fn to_parse_form(e: &Expr) -> String {
    expr(e)
}
