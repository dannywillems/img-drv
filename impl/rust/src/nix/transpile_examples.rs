//! The eleven conformance intents, written as Nix EXPRESSIONS in Rust.
//!
//! The same intents as [`crate::examples`], expressed through the other arrow.
//! There they are built directly as IR and serialized to `.drv`; here they are
//! built as Nix syntax and printed as `.nix`, for real Nix to instantiate.
//!
//! That is the COMMUTING SQUARE of `docs/architecture.md`: both routes must end
//! at the same bytes, and the bytes are already known to be right because
//! `make conformance` pins them for four implementations.
//!
//! Note what a reader does NOT have to write: no store paths, no hashes, and
//! for the dependent cases no explicit edge. Interpolating one derivation into
//! another's arguments is what creates the dependency, via the string context
//! described in `docs/nix-internals.md`. That is the mechanism the eDSLs
//! deliberately do without, and having it back is the point of transpiling.

use super::ast::Expr;
use super::surface::{
    Piece::{E, S},
    apply, attrs, boolean, int, istr, let_in, list, reset, str_, var,
};

fn system() -> Expr {
    str_("x86_64-linux")
}

fn sh() -> Expr {
    str_("/bin/sh")
}

fn drv(pairs: Vec<(&str, Expr)>) -> Expr {
    apply(var("derivation"), vec![attrs(pairs)])
}

fn echo(name: &str, word: &str) -> Expr {
    drv(vec![
        ("name", str_(name)),
        ("system", system()),
        ("builder", sh()),
        (
            "args",
            list(vec![str_("-c"), str_(&format!("echo {word} > $out"))]),
        ),
    ])
}

fn hello() -> Expr {
    echo("hello", "hi")
}

fn aaa() -> Expr {
    echo("aaa", "aaa")
}

fn mmm() -> Expr {
    echo("mmm", "mmm")
}

fn zzz() -> Expr {
    echo("zzz", "zzz")
}

fn dep_a() -> Expr {
    echo("dep-a", "a")
}

/// The edge is IMPLICIT.
///
/// `${a}` carries a's drv path in its string context, so Nix adds the
/// `inputDrvs` entry itself. Compare the eDSL, where the caller passes the
/// dependency explicitly.
fn dependent() -> Expr {
    let_in("a", dep_a(), |a| {
        drv(vec![
            ("name", str_("dependent")),
            ("system", system()),
            ("builder", sh()),
            (
                "args",
                list(vec![str_("-c"), istr(vec![S("cat "), E(a), S(" > $out")])]),
            ),
        ])
    })
}

fn many() -> Expr {
    let_in("a", aaa(), |a| {
        let_in("m", mmm(), |m| {
            let_in("z", zzz(), |z| {
                drv(vec![
                    ("name", str_("many")),
                    ("system", system()),
                    ("builder", sh()),
                    (
                        "args",
                        list(vec![
                            str_("-c"),
                            istr(vec![
                                S("cat "),
                                E(z),
                                S(" "),
                                E(a),
                                S(" "),
                                E(m),
                                S(" > $out"),
                            ]),
                        ]),
                    ),
                ])
            })
        })
    })
}

fn ordering() -> Expr {
    drv(vec![
        ("name", str_("ordering")),
        ("system", system()),
        ("builder", sh()),
        ("zzz", str_("last-declared-first")),
        ("aaa", str_("first")),
        ("mmm", str_("middle")),
    ])
}

fn multi() -> Expr {
    drv(vec![
        ("name", str_("multi")),
        ("system", system()),
        ("builder", sh()),
        ("outputs", list(vec![str_("out"), str_("dev"), str_("lib")])),
    ])
}

fn fixed() -> Expr {
    drv(vec![
        ("name", str_("fixed")),
        ("system", system()),
        ("builder", sh()),
        ("outputHash", str_(&"0".repeat(52))),
        ("outputHashAlgo", str_("sha256")),
        ("outputHashMode", str_("flat")),
    ])
}

fn structured() -> Expr {
    drv(vec![
        ("name", str_("structured")),
        ("system", system()),
        ("builder", sh()),
        ("args", list(vec![str_("-c"), str_("echo hi > $out")])),
        ("__structuredAttrs", boolean(true)),
        ("outputs", list(vec![str_("out"), str_("dev")])),
        ("aFlag", boolean(true)),
        ("aNumber", int(42)),
        ("aList", list(vec![str_("x"), str_("y")])),
        (
            "nested",
            attrs(vec![("deep", attrs(vec![("deeper", str_("value"))]))]),
        ),
        ("aString", str_("plain")),
    ])
}

/// Golden file name, and the expression that must produce it through real Nix.
///
/// Built from a reset name supply so the output is stable across runs.
pub fn corpus() -> Vec<(&'static str, Expr)> {
    reset();
    vec![
        (
            "sb07z720914wba188q8vzq7jnx4596xp-dependent.drv",
            dependent(),
        ),
        ("3k9aahbip0dn0kb9m6i20sr2mjfmzsij-aaa.drv", aaa()),
        ("6hjg3xda34qvj2vpw27girg51gpdyd19-fixed.drv", fixed()),
        ("76w21n1f03fs5kw8fnffphx7qrqffw6r-hello.drv", hello()),
        ("7v25018h9x5nc7sc0sv57ghaq2qa0j9n-zzz.drv", zzz()),
        ("5x04ng0y0kgnkp3kyah1ziwlyj107q8m-many.drv", many()),
        ("k1lc1y192xiajlyy4zvsdnfprnjx32i3-dep-a.drv", dep_a()),
        ("mfdcxzh0v906c5hngb3x0b7sjl130hpk-ordering.drv", ordering()),
        (
            "sqgix69fbs6hjh5kmf2pb1zvfmi5d0am-structured.drv",
            structured(),
        ),
        ("v27a425rg4n7prwzpyyw0y1fw2ssc46f-multi.drv", multi()),
        ("vk8wqbqg3k8w4134kwa0392kbc1953aq-mmm.drv", mmm()),
    ]
}
