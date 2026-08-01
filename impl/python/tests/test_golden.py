"""The regression gate: real derivations, produced by real Nix.

Examples written by hand test the cases you already thought of, which is
precisely the set that is already right. Every time hand-written examples and
real derivations have disagreed in this repository, the hand-written ones were
wrong.

These files came from a pinned Nix and are checked in. `make corpus` does the
same thing against a fresh random sample of nixpkgs, which is where new cases
come from.
"""

from __future__ import annotations

import pathlib

import pytest

from img_drv import Corpus, StorePath, name_from_path, parse, unparse

GOLDEN = (
    pathlib.Path(__file__).resolve().parents[3] / "docs" / "spec" / "examples"
)
DRVS = sorted(GOLDEN.glob("*.drv"))


def test_the_examples_are_present() -> None:
    """A corpus that silently vanished would make everything below pass."""
    assert len(DRVS) >= 10


@pytest.mark.parametrize("path", DRVS, ids=lambda p: p.name)
def test_round_trips_byte_identically(path: pathlib.Path) -> None:
    """unparse . parse = id on canonical text.

    Byte equality, not structural equality: the bytes ARE the artifact, since
    the derivation's own store path is their hash.
    """
    text = path.read_text().rstrip("\n")
    assert unparse(parse(text)) == text


def test_every_output_path_recomputes() -> None:
    """The whole specification, end to end, on vectors nobody wrote by hand."""
    corpus = Corpus.from_directory(GOLDEN)
    checked, mismatches = corpus.verify()
    assert checked >= 12
    assert not mismatches, "\n".join(str(m) for m in mismatches)


def test_input_hashing_is_memoized_and_stable() -> None:
    """Same question, same answer: hashing is a function, not a process."""
    corpus = Corpus.from_directory(GOLDEN)
    path = next(iter(sorted(corpus.drvs)))
    assert corpus.input_hash(path) == corpus.input_hash(path)


def test_name_comes_from_the_store_path_prefix() -> None:
    assert (
        name_from_path(StorePath("/nix/store/" + "a" * 32 + "-hello.drv"))
        == "hello"
    )
    # Not a store path: falls back rather than returning nonsense.
    assert name_from_path(StorePath("./whatever.drv")) == "whatever"
