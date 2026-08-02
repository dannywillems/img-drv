//! A real package, through a real overlay, against real nixpkgs.
//!
//! The eleven conformance intents are derivations nobody would write: no
//! dependencies, no stdenv, no composition. They pin the SERIALIZATION. This
//! pins the SURFACE, which is where the project's claim actually lives and
//! which had the least evidence behind it.
//!
//! What it exercises that the intents do not: `stdenv.mkDerivation`, a
//! dependency taken from nixpkgs, a value that arrived through an overlay and
//! is interpolated into a build phase, and a fixed point tying the overlay's
//! knot. Every one of those is something a user would write on their first day
//! and none appears in the corpus.
//!
//! The check is `scripts/worked-example.sh`: this term and the hand-written
//! `docs/spec/examples/worked-example.nix` must instantiate to the SAME store
//! path. Textual similarity is neither expected nor meaningful; the `.drv` is
//! the normal form, for the same reason the round-trip law lives there.

use super::ast::Expr;
use super::surface::{
    Overlay,
    Piece::{E, S},
    apply, attrs, boolean, fix, istr, let_in, list, reset, select, spath, str_, var,
};

fn base() -> Expr {
    attrs(vec![("greeting", str_("hello")), ("version", str_("1.0"))])
}

/// Bump the version, and derive a value from `final`.
///
/// Reading `final` is what forces the knot to be tied: an overlay that only
/// ever looked at `prev` would evaluate under a plain `//` and would not test
/// `fix` at all.
fn bump() -> Overlay {
    Box::new(|final_, prev| {
        attrs(vec![
            ("version", str_("2.0")),
            (
                "banner",
                istr(vec![
                    E(select(prev.clone(), &["greeting"])),
                    S(" v"),
                    E(select(final_.clone(), &["version"])),
                ]),
            ),
        ])
    })
}

/// The worked example, from a reset name supply so the output is stable.
pub fn term() -> Expr {
    reset();
    let_in(
        "pkgs",
        apply(var("import"), vec![spath("nixpkgs"), attrs(vec![])]),
        |pkgs| {
            let_in("final", fix(base(), &bump()), move |final_| {
                apply(
                    select(pkgs.clone(), &["stdenv", "mkDerivation"]),
                    vec![attrs(vec![
                        ("pname", str_("img-drv-worked-example")),
                        ("version", select(final_.clone(), &["version"])),
                        ("dontUnpack", boolean(true)),
                        ("nativeBuildInputs", list(vec![select(pkgs, &["hello"])])),
                        (
                            "buildPhase",
                            istr(vec![
                                S("echo "),
                                E(select(final_, &["banner"])),
                                S(" > out.txt"),
                            ]),
                        ),
                        (
                            "installPhase",
                            str_("mkdir -p $out/share && cp out.txt $out/share/"),
                        ),
                    ])],
                )
            })
        },
    )
}
