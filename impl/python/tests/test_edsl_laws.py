"""The eDSL's laws, as property tests over generated intents.

Examples test the cases someone already thought of. These encode the
SPECIFICATION instead: each one is a law any conforming implementation in any
language must satisfy, so they port to Rust, Go and OCaml as the conformance
suite rather than being rewritten there.

The laws divide into three groups:

* **Well-definedness.** Serialization is a function of the INTENT, not of how
  the intent was written down. Permuting a mapping that has no order, or
  listing dependencies in a different order, must not move a byte. This is the
  quotient in ``docs/theory.md`` section 4, and it is what makes "the same
  build in four languages" a meaningful claim: the four will not agree on
  incidental ordering, so the ordering must not matter.
* **Canonicality.** What the eDSL builds is a fixed point of
  :func:`~img_drv.canonical`, which is separately shown to be the identity on
  real Nix output.
* **Coherence between the two halves of the library.** Anything the eDSL
  DESCRIBES must survive being parsed back and re-verified by the same code
  that checks real nixpkgs closures.
"""

from __future__ import annotations

import base64
import pathlib
import random
import string
import tempfile
from dataclasses import dataclass, replace

from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from img_drv import (
    Corpus,
    Dep,
    Derivation,
    Drv,
    FixedOutput,
    HashMode,
    base32,
    base32_decode,
    canonical,
    derivation,
    drv_path,
    parse,
    sha256_hex,
    unparse,
    valid_name,
)
from img_drv.edsl import _ALWAYS_RESERVED

SYSTEM = "x86_64-linux"
SH = "/bin/sh"


def fst(pair: tuple[str, str]) -> str:
    return pair[0]


def sri(digest: bytes) -> str:
    return "sha256-" + base64.b64encode(digest).decode()


def edge(drv: Drv) -> Dep:
    """Depend on an output the target actually has.

    The bare-``Drv`` shorthand means "I need ``out``", which most derivations
    have and a generated one need not: outputs are named freely, and asking
    for a missing one is refused rather than guessed at.
    """
    return drv.ref(sorted(drv.outputs)[0])


# --------------------------------------------------------------------------
# strategies
# --------------------------------------------------------------------------

#: Store names, valid by CONSTRUCTION rather than by filtering: a leading
#: letter, then only characters Nix accepts in a store path name.
store_names = st.builds(
    lambda head, tail: head + tail,
    st.sampled_from(string.ascii_lowercase),
    st.text(string.ascii_lowercase + string.digits + "+-._?=", max_size=12),
)

#: Deliberately nasty values: the five escaped characters, a control character
#: that must NOT be escaped, and the `],[` sequence that defeats pattern
#: matching. Serialization has to survive all of it unchanged.
values = st.text(
    st.characters(codec="utf-8", include_characters='"\\\n\r\t\x07],[/'),
    max_size=24,
)

digests = st.binary(min_size=32, max_size=32)

# Annotated so the strategy carries the Literal through, rather than widening
# to str and needing a cast at every use.
_MODES: list[HashMode] = ["flat", "recursive"]
modes = st.sampled_from(_MODES)


@st.composite
def fixed_outputs(draw: st.DrawFn) -> FixedOutput:
    """A declared hash, written the way real derivations write them."""
    digest = draw(digests)
    written = draw(st.sampled_from([digest.hex(), base32(digest), sri(digest)]))
    return FixedOutput(
        hash=written,
        algo=None if written.startswith("sha256-") else "sha256",
        mode=draw(modes),
    )


@dataclass(frozen=True)
class Intent:
    """A build description, held apart from the call that realises it.

    Keeping the intent as a value is what lets a law say "these two ways of
    writing the same thing must serialize identically": the permutation is
    applied to the INTENT, and the bytes are compared afterwards.
    """

    name: str
    system: str
    builder: str
    args: tuple[str, ...]
    env: tuple[tuple[str, str], ...]
    outputs: tuple[str, ...] | None
    fixed: FixedOutput | None

    def build(self, deps: tuple[Dep, ...] = ()) -> Drv:
        return derivation(
            name=self.name,
            system=self.system,
            builder=self.builder,
            args=self.args,
            env=dict(self.env),
            outputs=list(self.outputs) if self.outputs is not None else None,
            input_drvs=list(deps),
            fixed_output=self.fixed,
        )


@st.composite
def intents(draw: st.DrawFn) -> Intent:
    outputs = draw(
        st.one_of(
            st.none(),
            st.lists(store_names, min_size=1, max_size=3, unique=True).map(
                tuple
            ),
        )
    )
    names = outputs if outputs is not None else ("out",)
    fixed = (
        draw(st.one_of(st.none(), fixed_outputs())) if len(names) == 1 else None
    )

    # Reserved keys are rejected at construction by design, so a collision is
    # DROPPED here rather than filtered for: filtering on a rare event only
    # makes the strategy slow and flaky.
    reserved = _ALWAYS_RESERVED | set(names)
    env = draw(
        st.lists(st.tuples(store_names, values), max_size=5, unique_by=fst)
    )
    return Intent(
        name=draw(store_names),
        system=draw(values),
        builder=draw(values),
        args=tuple(draw(st.lists(values, max_size=3))),
        env=tuple((k, v) for k, v in env if k not in reserved),
        outputs=outputs,
        fixed=fixed,
    )


# --------------------------------------------------------------------------
# well-definedness: the bytes depend on the intent, not on how it was written
# --------------------------------------------------------------------------


@given(intents())
def test_describing_the_same_intent_twice_gives_the_same_bytes(
    intent: Intent,
) -> None:
    """Serialization is a FUNCTION, not a process.

    Trivial-looking, and the first thing to break if anything reachable from
    here ever depends on iteration order, object identity, or a clock.
    """
    a, b = intent.build(), intent.build()
    assert a.aterm() == b.aterm()
    assert a.path == b.path
    assert a.input_hash == b.input_hash


@given(intents(), st.randoms(use_true_random=False))
def test_env_insertion_order_is_not_observable(
    intent: Intent, rng: random.Random
) -> None:
    """env is a MAP, so permuting it must not move a byte.

    This is the law that makes `env` safe to model as a host-language mapping
    (``spec/signature.md``): Python, Go and OCaml will not agree on iteration
    order, so if order leaked into the bytes the four implementations could
    never be byte-identical.
    """
    shuffled = list(intent.env)
    rng.shuffle(shuffled)
    permuted = replace(intent, env=tuple(shuffled))
    assert intent.build().aterm() == permuted.build().aterm()


@given(intents(), intents(), intents())
def test_dependency_order_is_not_observable(
    a: Intent, b: Intent, c: Intent
) -> None:
    """inputDrvs is a SET of edges; the .drv sorts it by store path.

    Listing dependencies in a different order is the same description. The
    serialized order is recovered by canonicalization, which is why a caller
    never has to think about it.
    """
    deps = (edge(a.build()), edge(b.build()))
    one, other = c.build(deps), c.build(deps[::-1])
    assert one.aterm() == other.aterm()
    assert one.path == other.path


@given(intents())
def test_naming_a_dependency_twice_is_naming_it_once(intent: Intent) -> None:
    """Edges merge: store paths are unique in inputDrvs in 1293 of 1293 real
    derivations, so a repeated reference cannot become a repeated entry."""
    dep = intent.build()
    once = intent.build((edge(dep),))
    twice = derivation(
        name=intent.name,
        system=intent.system,
        builder=intent.builder,
        args=intent.args,
        env=dict(intent.env),
        outputs=list(intent.outputs) if intent.outputs is not None else None,
        input_drvs=[edge(dep), edge(dep), edge(dep)],
        fixed_output=intent.fixed,
    )
    assert once.aterm() == twice.aterm()


# --------------------------------------------------------------------------
# canonicality
# --------------------------------------------------------------------------


@given(intents())
def test_what_the_edsl_builds_is_canonical(intent: Intent) -> None:
    """A fixed point of the same normalizer real Nix output is a fixed point of.

    Paired with ``test_real_derivations_are_already_canonical``, this is what
    makes the claim "our bytes are Nix's" rather than "our bytes are
    self-consistent".
    """
    drv = intent.build().derivation
    assert canonical(drv) == drv


@given(intents())
def test_canonical_is_idempotent(intent: Intent) -> None:
    """A normal form applied twice is applied once."""
    drv: Derivation = intent.build().derivation
    assert canonical(canonical(drv)) == canonical(drv)


@given(intents())
def test_the_path_is_the_hash_of_the_bytes(intent: Intent) -> None:
    """The store path is not metadata: it is a function of the file content."""
    drv = intent.build()
    assert drv.path == drv_path(drv.aterm(), intent.name)


@given(intents())
def test_what_the_edsl_writes_the_parser_reads(intent: Intent) -> None:
    """The two halves of the library are inverse on the eDSL's image.

    ``parse . unparse = id`` holds everywhere; ``unparse . parse = id`` holds
    only on CANONICAL text, which is exactly what the eDSL emits. Having both
    directions is a stronger statement than either alone.
    """
    drv = intent.build()
    assert parse(drv.aterm()) == drv.derivation
    assert unparse(parse(drv.aterm())) == drv.aterm()


@given(intents())
def test_declaring_outputs_is_observable(intent: Intent) -> None:
    """`None` and `["out"]` are different derivations, for every intent.

    Both forms occur in real nixpkgs, so an implementation that conflates them
    cannot reproduce one of them. Stated as a law rather than as one example
    because it has to hold whatever else the derivation contains.
    """
    implicit = replace(intent, outputs=None).build()
    explicit = replace(intent, outputs=("out",)).build()
    assert implicit.aterm() != explicit.aterm()
    assert implicit.path != explicit.path


@given(intents())
def test_every_output_is_an_env_variable_holding_its_own_path(
    intent: Intent,
) -> None:
    """Invariant 6 of spec/signature.md, for every intent rather than one."""
    drv = intent.build()
    env = dict(drv.derivation.env)
    for name, path in drv.outputs.items():
        assert env[name] == path


@given(intents())
def test_the_input_hash_is_not_the_self_hash(intent: Intent) -> None:
    """The asymmetry that cost this repository 145 downstream failures.

    A derivation's own path is computed from a form with its outputs MASKED;
    the hash by which it is known as someone's INPUT is not. Collapsing the two
    leaves every fixed-output derivation's own path correct and everything
    downstream of it wrong, which is invisible without a dependency on a fetch.
    """
    drv = intent.build()
    self_hash = sha256_hex(unparse(drv.derivation, mask_outputs=True))
    assert drv.input_hash != self_hash


# --------------------------------------------------------------------------
# coherence with the verifier that checks real nixpkgs closures
# --------------------------------------------------------------------------


@settings(
    max_examples=40,
    suppress_health_check=[HealthCheck.data_too_large, HealthCheck.too_slow],
)
@given(st.lists(intents(), min_size=1, max_size=5))
def test_a_described_closure_verifies_like_a_real_one(
    plan: list[Intent],
) -> None:
    """Describe a DAG, write it out, and check it the way nixpkgs is checked.

    The strongest law available without invoking Nix: the eDSL's output is
    handed to the same recursive path computation that reproduces 1259 of 1259
    real output paths, reached by a different route (parse the files back,
    rebuild the memo table, re-derive every path). A derivation whose declared
    outputs disagreed with its own hash is caught here even though the eDSL
    computed both.
    """
    built: list[Drv] = []
    for i, intent in enumerate(plan):
        # A chain, so inputDrvs carries real edges and the recursive
        # input-hash substitution has somewhere to recurse.
        built.append(
            intent.build(tuple(edge(d) for d in built[max(0, i - 2) : i]))
        )

    with tempfile.TemporaryDirectory() as tmp:
        directory = pathlib.Path(tmp)
        for drv in built:
            drv.write(directory)
        checked, mismatches = Corpus.from_directory(directory).verify()

    assert not mismatches, "\n".join(str(m) for m in mismatches)
    assert checked >= 1


# --------------------------------------------------------------------------
# encodings
# --------------------------------------------------------------------------


@given(st.binary(min_size=1, max_size=64))
def test_base32_decode_inverts_base32(data: bytes) -> None:
    """An inverse, not an approximation of one."""
    assert base32_decode(base32(data), len(data)) == data


@given(digests, modes)
def test_a_digest_means_the_same_however_it_is_written(
    digest: bytes, mode: HashMode
) -> None:
    """Representation-independence, which is why fetchers share cache entries.

    Two fixed-output derivations declaring the same BYTES agree on the output
    path however differently the hash was spelled, while remaining
    distinguishable as files, because the env keeps the spelling verbatim.
    """
    spellings = [
        FixedOutput(hash=digest.hex(), algo="sha256", mode=mode),
        FixedOutput(hash=base32(digest), algo="sha256", mode=mode),
        FixedOutput(hash=sri(digest), mode=mode),
    ]
    drvs = [
        derivation(name="f", system=SYSTEM, builder=SH, fixed_output=f)
        for f in spellings
    ]
    assert len({d.output() for d in drvs}) == 1
    assert len({d.path for d in drvs}) == len(drvs)


@given(store_names)
def test_generated_names_are_valid(name: str) -> None:
    """The generator builds valid names rather than filtering for them."""
    assert valid_name(name)
