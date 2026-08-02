"""The parser, against the vectors real Nix produced.

Two gates, and they measure different things.

``docs/spec/nix-parse/vectors.tsv`` is 59 cases someone thought of, and it pins
the DESUGARINGS precisely: which operators become builtin calls, which do not,
how a comparison is rewritten, how a float formats. Those are easy to get
subtly wrong and hard to notice on real input, because real files rarely
exercise `>=` at the top level of an expression.

``make nixpkgs-parse`` is thousands of real files, and it pins everything the
vectors do not: attribute order, quoting, string chunking, path resolution.
The OCaml parser passed all 59 vectors and then scored 0 of 40 on real files;
see ``docs/abstractions.md`` entry 13.

Both run. Neither is redundant.
"""

from __future__ import annotations

import pathlib

import pytest

from img_drv.nix import ast
from img_drv.nix.parser import parse, parse_and_print

VECTORS = (
    pathlib.Path(__file__).resolve().parents[3]
    / "docs"
    / "spec"
    / "nix-parse"
    / "vectors.tsv"
)


def _cases() -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    for line in VECTORS.read_text().splitlines():
        if not line.strip():
            continue
        source, _, expected = line.partition("\t")
        out.append((source, expected))
    return out


CASES = _cases()


def test_vector_file_is_present() -> None:
    assert len(CASES) >= 20


@pytest.mark.parametrize(("source", "expected"), CASES, ids=range(len(CASES)))
def test_matches_nix_instantiate_parse(source: str, expected: str) -> None:
    """Our printed tree must equal what the pinned Nix printed."""
    assert parse_and_print(source) == expected


def test_dynamic_attribute_forms_are_distinct() -> None:
    """``a.${k}`` and ``a."${k}"`` are DIFFERENT nodes.

    Nix keeps them apart and prints them differently; the extra parentheses in
    the second are the string wrapper showing through. Conflating them was a
    real bug, so it gets a test of its own rather than relying on one vector.
    """
    direct = parse('let a = {}; k = "b"; in a.${k}')
    wrapped = parse('let a = {}; k = "b"; in a."${k}"')
    assert direct != wrapped

    assert parse_and_print('let a={b=1;}; k="b"; in a.${k}').endswith(
        '(a)."${k}")'
    )
    assert parse_and_print('let k = "z"; in { "${k}" = 1; }').endswith(
        '{ "${(k)}" = 1; })'
    )


def test_interpolated_path_is_a_concatenation() -> None:
    """``./x/${v}.nix`` is a path CONCATENATION, not a string.

    The leading segment stays a path and keeps its trailing separator, which is
    what makes the pieces join into a location rather than glue together.
    """
    e = parse('let v = "1"; in ./x/${v}.nix', base="/abs")
    printed = parse_and_print('let v = "1"; in ./x/${v}.nix', base="/abs")
    assert isinstance(e, ast.Let)
    assert printed.endswith('(/abs/x/ + v + ".nix"))')


def test_paths_resolve_at_parse_time() -> None:
    """Nix resolves a relative path against the file it is written in."""
    assert parse_and_print("./common/x11.nix", base="/w/nixos/tests") == (
        "/w/nixos/tests/common/x11.nix"
    )
    assert parse_and_print("~/x.nix", home="/root") == "/root/x.nix"


def test_attribute_sets_print_sorted() -> None:
    """Nix stores an attribute set as a sorted map, so order is by name."""
    assert parse_and_print("{ b = 1; a = 2; }") == "{ a = 2; b = 1; }"
    assert parse_and_print("({ b, a }: a)") == "({ a, b }: a)"


def test_keywords_and_non_identifiers_are_quoted() -> None:
    """A bare keyword would not parse back, so Nix quotes it. Except ``or``."""
    assert parse_and_print('{ "inherit" = 1; }') == '{ "inherit" = 1; }'
    assert parse_and_print('{ "0.92" = 1; }') == '{ "0.92" = 1; }'
    assert parse_and_print('{ "a-b" = 1; }') == "{ a-b = 1; }"
    assert parse_and_print('{ "or" = 1; }') == "{ or = 1; }"


def test_string_parts_are_not_merged() -> None:
    """The lexer's maximal run draws the boundary; nothing merges afterwards.

    ``"a$b"`` is ONE chunk because Nix's run rule absorbs a dollar that does
    not open an interpolation. An escaped dollar in an indented string is its
    own chunk and stays separate, which is the case a merge pass gets wrong.
    """
    assert parse_and_print('"a$b"') == '"a$b"'
    assert parse_and_print("''a''$b''") == '("a" + "$" + "b")'
