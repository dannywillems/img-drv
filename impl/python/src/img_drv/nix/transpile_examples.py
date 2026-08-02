"""The eleven conformance intents, written as Nix EXPRESSIONS in Python.

The same intents as :mod:`img_drv.examples`, expressed through the other arrow.
There they are built directly as IR and serialized to ``.drv``; here they are
built as Nix syntax and printed as ``.nix``, for real Nix to instantiate.

That is the COMMUTING SQUARE of ``docs/architecture.md``: both routes must end
at the same bytes, and the bytes are already known to be right because
``make conformance`` pins them for four implementations.

Note what a reader does NOT have to write: no store paths, no hashes, and for
the dependent cases no explicit edge. Interpolating one derivation into
another's arguments is what creates the dependency, via the string context
described in ``docs/nix-internals.md``. That is the mechanism the eDSLs
deliberately do without, and having it back is the point of transpiling.
"""

from __future__ import annotations

from collections.abc import Callable

from .ast import Expr
from .surface import (
    apply,
    attrs,
    boolean,
    int_,
    istr,
    let_in,
    listing,
    reset,
    str_,
    var,
)

__all__ = ["CORPUS", "corpus"]

SYSTEM = str_("x86_64-linux")
SH = str_("/bin/sh")


def drv(pairs: dict[str, Expr]) -> Expr:
    return apply(var("derivation"), [attrs(pairs)])


def echo(name: str, word: str) -> Expr:
    return drv(
        {
            "name": str_(name),
            "system": SYSTEM,
            "builder": SH,
            "args": listing([str_("-c"), str_(f"echo {word} > $out")]),
        }
    )


def hello() -> Expr:
    return echo("hello", "hi")


def aaa() -> Expr:
    return echo("aaa", "aaa")


def mmm() -> Expr:
    return echo("mmm", "mmm")


def zzz() -> Expr:
    return echo("zzz", "zzz")


def dep_a() -> Expr:
    return echo("dep-a", "a")


def dependent() -> Expr:
    """The edge is IMPLICIT.

    ``${a}`` carries a's drv path in its string context, so Nix adds the
    inputDrvs entry itself. Compare the eDSL, where the caller passes the
    dependency explicitly.
    """
    return let_in(
        dep_a(),
        lambda a: drv(
            {
                "name": str_("dependent"),
                "system": SYSTEM,
                "builder": SH,
                "args": listing([str_("-c"), istr(["cat ", a, " > $out"])]),
            }
        ),
        name="a",
    )


def many() -> Expr:
    return let_in(
        aaa(),
        lambda a: let_in(
            mmm(),
            lambda m: let_in(
                zzz(),
                lambda z: drv(
                    {
                        "name": str_("many"),
                        "system": SYSTEM,
                        "builder": SH,
                        "args": listing(
                            [
                                str_("-c"),
                                istr(["cat ", z, " ", a, " ", m, " > $out"]),
                            ]
                        ),
                    }
                ),
                name="z",
            ),
            name="m",
        ),
        name="a",
    )


def ordering() -> Expr:
    return drv(
        {
            "name": str_("ordering"),
            "system": SYSTEM,
            "builder": SH,
            "zzz": str_("last-declared-first"),
            "aaa": str_("first"),
            "mmm": str_("middle"),
        }
    )


def multi() -> Expr:
    return drv(
        {
            "name": str_("multi"),
            "system": SYSTEM,
            "builder": SH,
            "outputs": listing([str_("out"), str_("dev"), str_("lib")]),
        }
    )


def fixed() -> Expr:
    return drv(
        {
            "name": str_("fixed"),
            "system": SYSTEM,
            "builder": SH,
            "outputHash": str_("0" * 52),
            "outputHashAlgo": str_("sha256"),
            "outputHashMode": str_("flat"),
        }
    )


def structured() -> Expr:
    return drv(
        {
            "name": str_("structured"),
            "system": SYSTEM,
            "builder": SH,
            "args": listing([str_("-c"), str_("echo hi > $out")]),
            "__structuredAttrs": boolean(True),
            "outputs": listing([str_("out"), str_("dev")]),
            "aFlag": boolean(True),
            "aNumber": int_(42),
            "aList": listing([str_("x"), str_("y")]),
            "nested": attrs({"deep": attrs({"deeper": str_("value")})}),
            "aString": str_("plain"),
        }
    )


#: Golden file name, and the builder of the expression that must produce it
#: through real Nix.
CORPUS: dict[str, Callable[[], Expr]] = {
    "sb07z720914wba188q8vzq7jnx4596xp-dependent.drv": dependent,
    "3k9aahbip0dn0kb9m6i20sr2mjfmzsij-aaa.drv": aaa,
    "6hjg3xda34qvj2vpw27girg51gpdyd19-fixed.drv": fixed,
    "76w21n1f03fs5kw8fnffphx7qrqffw6r-hello.drv": hello,
    "7v25018h9x5nc7sc0sv57ghaq2qa0j9n-zzz.drv": zzz,
    "5x04ng0y0kgnkp3kyah1ziwlyj107q8m-many.drv": many,
    "k1lc1y192xiajlyy4zvsdnfprnjx32i3-dep-a.drv": dep_a,
    "mfdcxzh0v906c5hngb3x0b7sjl130hpk-ordering.drv": ordering,
    "sqgix69fbs6hjh5kmf2pb1zvfmi5d0am-structured.drv": structured,
    "v27a425rg4n7prwzpyyw0y1fw2ssc46f-multi.drv": multi,
    "vk8wqbqg3k8w4134kwa0392kbc1953aq-mmm.drv": mmm,
}


def corpus() -> list[tuple[str, Expr]]:
    """Build every intent, from a reset name supply so output is stable."""
    reset()
    return [(name, build()) for name, build in CORPUS.items()]
