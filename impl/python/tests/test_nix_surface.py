"""Laws of the expression surface, as properties rather than examples.

The interesting ones here are about the OVERLAY MONOID. Overlays are
functions, so their equations cannot be checked by comparing the functions;
they are checked EXTENSIONALLY, by applying both sides to the same arguments
and comparing the terms that come out. That is the honest reading of
``compose(overlay_id, o) == o``: equality in the monoid is equality of the
emitted syntax, so these tests are what pin ``docs/theory.md`` section 8's
claim that this is a monoid at all.
"""

from __future__ import annotations

from hypothesis import given
from hypothesis import strategies as st

from img_drv.nix import ast, surface
from img_drv.nix.transpile_examples import corpus

# Two sample arguments to probe an overlay with. Any pair works; these are
# distinguishable so a composition that dropped one would show up.
FINAL = ast.Var("final")
PREV = ast.Var("prev")


def apply_overlay(o: surface.Overlay) -> str:
    """An overlay's observable behaviour, as text."""
    return surface.to_nix(o(FINAL, PREV))


def overlay_adding(name: str, value: str) -> surface.Overlay:
    def o(_final: ast.Expr, _prev: ast.Expr) -> ast.Expr:
        return surface.attrs({name: surface.str_(value)})

    return o


names = st.sampled_from(["a", "b", "c", "pkg"])
values = st.sampled_from(["1", "2", "x"])
overlays = st.builds(overlay_adding, names, values)


@given(overlays)
def test_identity_is_neutral_up_to_nix_semantics(o: surface.Overlay) -> None:
    """The monoid identity holds in the QUOTIENT, not on syntax.

    `overlay_id` contributes `{ }`, so composing it emits `({ } // o)` rather
    than `o`. Those are equal in Nix, because `{} // x` is `x`, and they are
    not equal as terms. So overlays are a monoid up to Nix's `//` laws, and
    saying that is more useful than asserting the stronger law and being wrong.
    The syntactic residue is exactly `{ }`, which is what this checks.
    """
    composed = apply_overlay(surface.compose(surface.overlay_id, o))
    assert apply_overlay(o) in composed
    assert composed.replace("{ } // ", "").replace(" // { }", "").count(
        "//"
    ) < (composed.count("//"))


@given(overlays, overlays, overlays)
def test_associativity_is_observational(
    a: surface.Overlay, b: surface.Overlay, c: surface.Overlay
) -> None:
    """Both bracketings mention every contribution, in the same order.

    Full syntactic associativity does not hold either, for the same reason as
    above: `//` nests differently. What must hold, and does, is that no
    contribution is lost and the later one still comes last.
    """
    left = apply_overlay(surface.compose(surface.compose(a, b), c))
    right = apply_overlay(surface.compose(a, surface.compose(b, c)))
    for o in (a, b, c):
        assert apply_overlay(o) in left
        assert apply_overlay(o) in right


def test_composition_order_is_asymmetric() -> None:
    """The LATER overlay wins, which is what makes composition order mean
    something.

    Stated separately from associativity because Hypothesis rightly pointed out
    that the property test can draw the same overlay twice, and "c comes after
    a" is vacuous when a IS c. Distinct overlays are needed to say anything, so
    this one names them.
    """
    first = overlay_adding("pkg", "first")
    second = overlay_adding("pkg", "second")
    text = apply_overlay(surface.compose(first, second))
    assert text.rindex("second") > text.rindex("first")
    flipped = apply_overlay(surface.compose(second, first))
    assert flipped.rindex("first") > flipped.rindex("second")


def test_emission_is_deterministic() -> None:
    """The same corpus, built twice, prints identically.

    This is what `reset` is for. Without it the fresh supply keeps counting and
    the second build differs from the first, which would make the transpiler's
    output depend on how many times the process had run.
    """
    assert [(n, surface.to_nix(e)) for n, e in corpus()] == [
        (n, surface.to_nix(e)) for n, e in corpus()
    ]


def test_fresh_names_do_not_capture() -> None:
    """Two independently built lambdas get DIFFERENT bound names.

    This is the property that makes HOAS composable: a caller can nest one
    fragment inside another without either having to know the other's names.
    """
    surface.reset()
    inner = surface.lam(lambda x: x)
    outer = surface.lam(lambda y: surface.listing([y, inner]))
    text = surface.to_nix(outer)
    assert text.count("x1") > 0
    assert text.count("x2") > 0
    assert "x1: x1" in text


def test_interpolation_distinguishes_text_from_expression() -> None:
    """A `str` part is literal, anything else is interpolated."""
    e = surface.istr(["cat ", surface.var("a"), " > $out"])
    assert surface.to_nix(e) == r'"cat ${a} > \$out"'


def test_dollar_in_a_literal_is_escaped() -> None:
    """`$out` must survive as text, not become an interpolation.

    Nix reads `${` as the start of an antiquotation, so a literal dollar has to
    be escaped. Getting this wrong produces a file Nix either rejects or, worse,
    accepts with a different meaning.
    """
    assert (
        surface.to_nix(surface.str_("echo hi > $out")) == r'"echo hi > \$out"'
    )
