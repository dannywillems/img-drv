"""The surface: build Nix expressions in Python.

This is what a developer writes instead of learning the Nix language. It hands
back :mod:`img_drv.nix.ast` values, the inspectable core, so everything
downstream works on data rather than on host closures.

Binders are HOAS here and named underneath
--------------------------------------------

A lambda is written with a Python function::

    lam(lambda x: attrs({"name": x}))

which is what makes it composable and frees the caller from inventing names.
:func:`lam` lowers that to a NAMED binder immediately, with a fresh supply,
because the printer needs a name to print. That two-layer split is the
recommendation in ``docs/theory.md`` section 8, and this module is the only
place in the package that ever sees a host closure.
"""

from __future__ import annotations

from collections.abc import Callable, Iterable, Mapping, Sequence

from . import ast
from .emit import to_nix

__all__ = [
    "apply",
    "attrs",
    "boolean",
    "compose",
    "compose_all",
    "concat",
    "eq",
    "fix",
    "if_",
    "int_",
    "istr",
    "lam",
    "lam_attrs",
    "let_",
    "let_in",
    "listing",
    "null",
    "overlay_id",
    "path",
    "plus",
    "rec_attrs",
    "reset",
    "select",
    "str_",
    "to_nix",
    "update",
    "var",
]

# A fresh-name supply. Names are prefixed so they cannot collide with anything
# a caller wrote, and the counter is resettable rather than global-forever so
# the same term prints the same way twice, which the round-trip law needs.
_counter = [0]


def reset() -> None:
    """Restart the fresh-name supply, so a term prints identically twice."""
    _counter[0] = 0


def _fresh(base: str) -> str:
    _counter[0] += 1
    return f"{base}{_counter[0]}"


# Literals


def int_(n: int) -> ast.Expr:
    return ast.Int(n)


def float_(f: float) -> ast.Expr:
    return ast.Float(f)


def str_(s: str) -> ast.Expr:
    return ast.Str((ast.Lit(s),))


def path(p: str) -> ast.Expr:
    return ast.Path(p)


def var(x: str) -> ast.Expr:
    return ast.Var(x)


def boolean(b: bool) -> ast.Expr:
    return ast.Var("true" if b else "false")


null: ast.Expr = ast.Var("null")


def istr(parts: Iterable[str | ast.Expr]) -> ast.Expr:
    """An interpolated string.

    A ``str`` part is literal text and anything else is interpolated, so
    ``istr(["cat ", a, " > $out"])`` is ``"cat ${a} > $out"``. Distinguishing
    the two by TYPE rather than by a tag is the one place this surface reads
    better than the OCaml one, which needs an explicit `` `S``/`` `E``.
    """
    return ast.Str(
        tuple(ast.Lit(p) if isinstance(p, str) else ast.Anti(p) for p in parts)
    )


# Structure


def listing(items: Iterable[ast.Expr]) -> ast.Expr:
    return ast.List(tuple(items))


def attrs(pairs: Mapping[str, ast.Expr]) -> ast.Expr:
    """An attribute set. Insertion order is preserved, as Nix source is."""
    return ast.AttrSet(
        tuple(ast.Bind((ast.Id(k),), v) for k, v in pairs.items())
    )


def rec_attrs(pairs: Mapping[str, ast.Expr]) -> ast.Expr:
    """A recursive attribute set: bindings can refer to each other by name."""
    return ast.AttrSet(
        tuple(ast.Bind((ast.Id(k),), v) for k, v in pairs.items()),
        recursive=True,
    )


def select(
    e: ast.Expr, names: Sequence[str], default: ast.Expr | None = None
) -> ast.Expr:
    return ast.Select(e, tuple(ast.Id(n) for n in names), default)


def apply(f: ast.Expr, args: Iterable[ast.Expr]) -> ast.Expr:
    """Curried application: ``apply(f, [a, b])`` is ``((f a) b)``."""
    out = f
    for a in args:
        out = ast.Apply(out, a)
    return out


# Binders


def lam(f: Callable[[ast.Expr], ast.Expr], name: str = "x") -> ast.Expr:
    """A lambda, written with a Python function.

    The bound variable is materialised as a fresh NAME, so the result is
    ordinary inspectable syntax rather than a closure.
    """
    n = _fresh(name)
    return ast.Lambda(ast.Pvar(n), f(ast.Var(n)))


def lam_attrs(
    formals: Sequence[tuple[str, ast.Expr | None]],
    f: Callable[[Callable[[str], ast.Expr]], ast.Expr],
    ellipsis: bool = False,
) -> ast.Expr:
    """A lambda taking an attribute set, ``{ a, b ? d }: body``.

    The body receives a LOOKUP function rather than a record, because the
    formals are named by the caller at runtime and no host type can give them
    back as fields.
    """
    body = f(ast.Var)
    return ast.Lambda(ast.Pset(tuple(formals), ellipsis, None), body)


def let_(pairs: Mapping[str, ast.Expr], body: ast.Expr) -> ast.Expr:
    """``let a = ...; in body``, with the bindings in scope in each other."""
    return ast.Let(
        tuple(ast.Bind((ast.Id(k),), v) for k, v in pairs.items()), body
    )


def let_in(
    value: ast.Expr, f: Callable[[ast.Expr], ast.Expr], name: str = "v"
) -> ast.Expr:
    """Bind one value and use it, without naming it.

    The composable form: the caller never sees the generated name, so two
    independently written fragments cannot capture each other's variables.
    """
    n = _fresh(name)
    return ast.Let((ast.Bind((ast.Id(n),), value),), f(ast.Var(n)))


# Operators


def plus(a: ast.Expr, b: ast.Expr) -> ast.Expr:
    return ast.Op(ast.Operator.ADD, a, b)


def update(a: ast.Expr, b: ast.Expr) -> ast.Expr:
    """``a // b``: b wins on a clash."""
    return ast.Op(ast.Operator.UPDATE, a, b)


def concat(a: ast.Expr, b: ast.Expr) -> ast.Expr:
    return ast.Op(ast.Operator.CONCAT, a, b)


def eq(a: ast.Expr, b: ast.Expr) -> ast.Expr:
    return ast.Op(ast.Operator.EQ, a, b)


def if_(c: ast.Expr, t: ast.Expr, f: ast.Expr) -> ast.Expr:
    return ast.If(c, t, f)


# Composability: overlays as mixins
#
# An overlay is `final: prev: { ... }`, which is Cook and Palsberg's wrapper
# over a generator (docs/theory.md section 8). Composition is asymmetric and
# associative with an identity, so overlays form a MONOID, and `fix` is the map
# out of it.

#: final, previous, additions
Overlay = Callable[[ast.Expr, ast.Expr], ast.Expr]


def overlay_id(_final: ast.Expr, _prev: ast.Expr) -> ast.Expr:
    """The identity overlay: adds nothing."""
    return attrs({})


def compose(a: Overlay, b: Overlay) -> Overlay:
    """Apply ``a`` first, then ``b`` on top, so ``b`` wins on a clash.

    That matches how a later overlay in a list overrides an earlier one.
    """

    def composed(final: ast.Expr, prev: ast.Expr) -> ast.Expr:
        after_a = a(final, prev)
        return update(after_a, b(final, update(prev, after_a)))

    return composed


def compose_all(overlays: Iterable[Overlay]) -> Overlay:
    out: Overlay = overlay_id
    for o in overlays:
        out = compose(out, o)
    return out


def fix(base: ast.Expr, o: Overlay) -> ast.Expr:
    """Close an overlay into a package set with the knot tied.

    Emits ``(let final = base // (overlay final base); in final)``: the fixed
    point is written OUT in Nix rather than computed here, because the point of
    a transpiler is that the output does the work.
    """
    n = _fresh("final")
    return ast.Let(
        (ast.Bind((ast.Id(n),), update(base, o(ast.Var(n), base))),), ast.Var(n)
    )
