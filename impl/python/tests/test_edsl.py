"""The eDSL, checked against derivations real Nix actually emitted.

The tests that matter here are not "does it build a plausible record". They
are: DESCRIBE the same intent that produced a golden file, and demand the same
bytes, including the derivation's own store path. Anything less would pass for
an implementation with the right shape and the wrong identity, which is the
failure mode this whole repository is organised around.
"""

from __future__ import annotations

import base64
import pathlib

import pytest

from img_drv import (
    Drv,
    FixedOutput,
    InvalidDerivationError,
    base32,
    canonical,
    derivation,
    parse,
    valid_name,
)
from img_drv.examples import (
    CORPUS,
    SH,
    SYSTEM,
    dep_a,
    dependent,
    hello,
    multi,
)

GOLDEN = (
    pathlib.Path(__file__).resolve().parents[3] / "docs" / "spec" / "examples"
)


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode()


# The intents live in the library, not here: `make conformance` and the
# `examples` CLI command consume the same ten, so a corpus only the tests
# could see would not be the conformance corpus.
INTENTS = CORPUS


def test_every_golden_file_has_an_intent() -> None:
    """A golden nobody describes is a rule nobody is testing."""
    assert {p.name for p in GOLDEN.glob("*.drv")} == set(INTENTS)


@pytest.mark.parametrize("filename", sorted(INTENTS))
def test_describing_the_intent_reproduces_nix_byte_for_byte(
    filename: str,
) -> None:
    """The exit test of Phase 1, in miniature.

    Byte equality with a file real Nix wrote. Structural equality would not do:
    the bytes are hashed to produce the derivation's own store path, so an
    implementation that agrees structurally and differs in one separator
    produces a derivation nothing in any cache can satisfy.
    """
    drv = INTENTS[filename]()
    assert drv.aterm() == (GOLDEN / filename).read_text().rstrip("\n")


@pytest.mark.parametrize("filename", sorted(INTENTS))
def test_the_derivation_lands_at_its_own_store_path(filename: str) -> None:
    """The .drv path is the hash of the bytes above, so this is the real check.

    Reproducing the CONTENT while computing the wrong path would mean the
    text-kind store path rule is wrong, which nothing else here would catch.
    """
    assert INTENTS[filename]().path.split("/")[-1] == filename


def test_output_paths_are_known_before_anything_is_built() -> None:
    """Input addressing, which is the property everything else rests on."""
    assert (
        hello().output() == "/nix/store/mjs27ix6ig2bkbi3s3sm470vrv4lf7ic-hello"
    )
    assert multi().output("dev").endswith("-multi-dev")
    assert multi().output("out").endswith("-multi")


def test_a_dependent_agrees_with_what_it_depends_on() -> None:
    """The edge in inputDrvs points at the dependency's own .drv path."""
    a = dep_a()
    d = dependent()
    assert [i.path for i in d.derivation.input_drvs] == [a.path]
    assert a.output() in d.derivation.args[1]


# --------------------------------------------------------------------------
# outputs is an OPTION, and both cases occur in real nixpkgs
# --------------------------------------------------------------------------


def test_declaring_outputs_is_observable_in_the_bytes() -> None:
    """`None` and `["out"]` are DIFFERENT derivations.

    A bare `derivation { ... }` emits no `outputs` env variable; a package that
    writes `outputs = [ "out" ]` emits `("outputs","out")`. 96 of the corpus's
    single-output derivations do the first and 605 do the second, so an
    implementation that models this as a list with a default cannot express
    one of the two.
    """
    implicit = derivation(name="x", system=SYSTEM, builder=SH)
    explicit = derivation(name="x", system=SYSTEM, builder=SH, outputs=["out"])
    assert '("outputs"' not in implicit.aterm()
    assert '("outputs","out")' in explicit.aterm()
    assert implicit.path != explicit.path
    assert implicit.output() != explicit.output()


def test_the_outputs_variable_keeps_declaration_order() -> None:
    """One file, two orderings of the same list.

    The outputs LIST is sorted by name; the `outputs` env VARIABLE is in
    declaration order. They differ in 575 of the 1197 real derivations that
    declare outputs, so this is routine rather than exotic.
    """
    drv = multi()
    assert [o.name for o in drv.derivation.outputs] == ["dev", "lib", "out"]
    assert dict(drv.derivation.env)["outputs"] == "out dev lib"


# --------------------------------------------------------------------------
# fixed-output derivations
# --------------------------------------------------------------------------


def test_a_hash_is_accepted_in_every_representation_nix_writes() -> None:
    """hex, Nix base-32, base-64 and SRI all denote the same digest."""
    digest = bytes(range(32))
    forms = [
        FixedOutput(hash=digest.hex(), algo="sha256"),
        FixedOutput(hash=base32(digest), algo="sha256"),
        FixedOutput(hash="sha256-" + _b64(digest)),
    ]
    assert {f.hash_field for f in forms} == {digest.hex()}


def test_the_output_path_does_not_depend_on_how_the_hash_was_written() -> None:
    """Why every fetchurl in nixpkgs can share one cache entry.

    Two fixed-output derivations that declare the same BYTES are
    interchangeable however differently they are expressed, so the output path
    is a function of the digest alone. The .drv path is not: the env keeps the
    hash verbatim, so the derivations remain distinguishable as files.
    """
    digest = bytes(range(32))

    def with_hash(h: str, algo: str | None) -> Drv:
        return derivation(
            name="fetched",
            system=SYSTEM,
            builder=SH,
            fixed_output=FixedOutput(
                hash=h,
                algo="sha256" if algo else None,
            ),
        )

    as_hex = with_hash(digest.hex(), "sha256")
    as_sri = with_hash("sha256-" + _b64(digest), None)
    assert as_hex.output() == as_sri.output()
    assert as_hex.path != as_sri.path


def test_recursive_ingestion_takes_a_different_path_scheme() -> None:
    """`r:sha256` is the `source` kind with the declared hash used directly.

    Exactly one derivation in a 226-derivation closure exercised this, which is
    how it survived a hand-written corpus.
    """
    digest = bytes(range(32))
    flat = derivation(
        name="f",
        system=SYSTEM,
        builder=SH,
        fixed_output=FixedOutput(hash=digest.hex(), algo="sha256"),
    )
    rec = derivation(
        name="f",
        system=SYSTEM,
        builder=SH,
        fixed_output=FixedOutput(
            hash=digest.hex(), algo="sha256", mode="recursive"
        ),
    )
    assert '"r:sha256"' in rec.aterm()
    assert '("outputHashMode","recursive")' in rec.aterm()
    assert flat.output() != rec.output()


def test_an_sri_hash_emits_no_outputHashAlgo() -> None:  # noqa: N802
    """11 of the 93 real fixed-output derivations omit it; matching matters."""
    drv = derivation(
        name="f",
        system=SYSTEM,
        builder=SH,
        fixed_output=FixedOutput(hash="sha256-" + _b64(bytes(32))),
    )
    assert "outputHashAlgo" not in dict(drv.derivation.env)


# --------------------------------------------------------------------------
# invariants from spec/signature.md, enforced at construction
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("why", "kwargs"),
    [
        ("empty outputs", {"outputs": []}),
        ("duplicate outputs", {"outputs": ["out", "out"]}),
        ("fixed with several outputs", {"outputs": ["out", "dev"]}),
        ("reserved env key", {"env": {"name": "other"}}),
        ("reserved output key", {"env": {"out": "/nix/store/x"}}),
        ("reserved hash key", {"env": {"outputHash": "00"}}),
    ],
)
def test_invalid_descriptions_are_rejected_at_construction(
    why: str, kwargs: dict[str, object]
) -> None:
    """Constructing a wrong derivation must fail LOUDLY.

    The alternative is a file that serializes perfectly and denotes something
    else, which no downstream check can distinguish from intent.
    """
    fixed_output = (
        FixedOutput(hash="0" * 64, algo="sha256") if "fixed" in why else None
    )
    with pytest.raises(InvalidDerivationError):
        derivation(
            name="x",
            system=SYSTEM,
            builder=SH,
            fixed_output=fixed_output,
            **kwargs,  # type: ignore[arg-type]
        )


@pytest.mark.parametrize(
    "bad", ["", ".", "..", ".hidden", "a b", "a/b", "x" * 212]
)
def test_invalid_names_are_rejected(bad: str) -> None:
    assert not valid_name(bad)
    with pytest.raises(InvalidDerivationError):
        derivation(name=bad, system=SYSTEM, builder=SH)


@pytest.mark.parametrize(
    "good", ["hello", "hello-1.0", "a+b", "x_y", "q?", "n=1", "x" * 211]
)
def test_names_real_packages_use_are_accepted(good: str) -> None:
    assert valid_name(good)


def test_asking_for_an_output_that_does_not_exist_fails() -> None:
    with pytest.raises(InvalidDerivationError):
        hello().output("dev")
    with pytest.raises(InvalidDerivationError):
        hello().ref("dev")


def test_bad_hashes_are_rejected_when_the_value_is_built() -> None:
    with pytest.raises(InvalidDerivationError):
        FixedOutput(hash="0" * 63, algo="sha256")  # not a digest length
    with pytest.raises(InvalidDerivationError):
        FixedOutput(hash="0" * 64, algo="sha3")  # type: ignore[arg-type]
    with pytest.raises(InvalidDerivationError):
        FixedOutput(hash="0" * 64)  # no algo, and not SRI
    with pytest.raises(InvalidDerivationError):
        FixedOutput(hash="sha512-" + _b64(bytes(32)))  # wrong digest length


# --------------------------------------------------------------------------
# laws
# --------------------------------------------------------------------------


def test_one_edge_per_dependency_however_often_it_is_named() -> None:
    """Nix emits unique paths in inputDrvs: 1293 of 1293 real derivations."""
    m = multi()
    drv = derivation(
        name="user",
        system=SYSTEM,
        builder=SH,
        input_drvs=[m.ref("dev"), m.ref("lib"), m.ref("dev")],
    )
    (edge,) = drv.derivation.input_drvs
    assert edge.outputs == ("dev", "lib")


@pytest.mark.parametrize("filename", sorted(INTENTS))
def test_real_derivations_are_already_canonical(filename: str) -> None:
    """The form is Nix's, not ours.

    If canonicalizing a real derivation changed it, our ordering rules would
    merely be self-consistent, and every claim about byte-identity across
    languages would be about our own convention rather than about Nix's.
    """
    drv = parse((GOLDEN / filename).read_text())
    assert canonical(drv) == drv
