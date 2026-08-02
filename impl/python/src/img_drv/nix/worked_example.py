"""A real package, through a real overlay, against real nixpkgs.

The eleven conformance intents are derivations nobody would write: no
dependencies, no stdenv, no composition. They pin the SERIALIZATION. This pins
the SURFACE, which is where the project claim actually lives and which had the
least evidence behind it.

What it exercises that the intents do not: stdenv.mkDerivation, a dependency
taken from nixpkgs, a value that arrived through an overlay and is interpolated
into a build phase, and a fixed point tying the overlay knot. Every one of
those is something a user would write on their first day and none appears in
the corpus.

The check is scripts/worked-example.sh: this term and the hand-written
docs/spec/examples/worked-example.nix must instantiate to the SAME store path.
Textual similarity is neither expected nor meaningful; the .drv is the normal
form, for the same reason the round-trip law lives there.
"""

from __future__ import annotations

from .ast import Expr
from .surface import (
    apply,
    attrs,
    boolean,
    fix,
    istr,
    let_in,
    listing,
    reset,
    select,
    spath,
    str_,
    var,
)

__all__ = ["term"]

BASE = attrs({"greeting": str_("hello"), "version": str_("1.0")})


def bump(final: Expr, prev: Expr) -> Expr:
    """Bump the version, and derive a value from `final`.

    Reading `final` is what forces the knot to be tied: an overlay that only
    ever looked at `prev` would evaluate under a plain `//` and would not
    test `fix` at all.
    """
    return attrs(
        {
            "version": str_("2.0"),
            "banner": istr(
                [select(prev, ["greeting"]), " v", select(final, ["version"])]
            ),
        }
    )


def term() -> Expr:
    """The worked example, from a reset name supply so output is stable."""
    reset()
    return let_in(
        apply(var("import"), [spath("nixpkgs"), attrs({})]),
        lambda pkgs: let_in(
            fix(BASE, bump),
            lambda final: apply(
                select(pkgs, ["stdenv", "mkDerivation"]),
                [
                    attrs(
                        {
                            "pname": str_("img-drv-worked-example"),
                            "version": select(final, ["version"]),
                            "dontUnpack": boolean(True),
                            "nativeBuildInputs": listing(
                                [select(pkgs, ["hello"])]
                            ),
                            "buildPhase": istr(
                                [
                                    "echo ",
                                    select(final, ["banner"]),
                                    " > out.txt",
                                ]
                            ),
                            "installPhase": str_(
                                "mkdir -p $out/share && cp out.txt $out/share/"
                            ),
                        }
                    )
                ],
            ),
            name="final",
        ),
        name="pkgs",
    )
