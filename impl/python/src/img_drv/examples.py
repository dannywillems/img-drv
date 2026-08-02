"""The conformance corpus: intents, and the bytes real Nix produced for them.

This is the language-independent set `PLAN.md` phase 2 asks for. Each entry is
an INTENT expressed through the eDSL, paired with the name of the golden file
in ``docs/spec/examples/`` that real Nix emitted for the same intent.

It lives in the library rather than in the tests because three different things
consume it: the test suite, the ``examples`` CLI command, and `make
conformance`, which diffs what Python emits against what Rust emits against
what Nix emitted. A corpus that only the tests could see could not do the
last two.

Every implementation in every language carries the same ten intents. That is
what makes "byte-identical across four languages" a claim that can fail.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping

from .edsl import Drv, FixedOutput, derivation

#: The characters that defeat naive pattern matching, exactly as the probe
#: writes them.
NASTY = 'a "quoted" \\ backslash, a ],[ sequence, and a tab:\tdone'

__all__ = ["CORPUS", "SH", "SYSTEM"]

#: Every example targets one system, so the corpus is comparable across
#: machines: a derivation's store path depends on its system.
SYSTEM = "x86_64-linux"
SH = "/bin/sh"


def _echo(name: str, word: str) -> Drv:
    """The shape shared by most of the golden examples."""
    return derivation(
        name=name,
        system=SYSTEM,
        builder=SH,
        args=["-c", f"echo {word} > $out"],
    )


def hello() -> Drv:
    """The smallest real derivation: one output, no dependencies."""
    return _echo("hello", "hi")


def aaa() -> Drv:
    """One of three leaves used to exercise multi-entry `inputDrvs`."""
    return _echo("aaa", "aaa")


def mmm() -> Drv:
    """One of three leaves used to exercise multi-entry `inputDrvs`."""
    return _echo("mmm", "mmm")


def zzz() -> Drv:
    """One of three leaves used to exercise multi-entry `inputDrvs`."""
    return _echo("zzz", "zzz")


def dep_a() -> Drv:
    """The dependency of `dependent`, and a reconstruction target itself."""
    return _echo("dep-a", "a")


def dependent() -> Drv:
    """One edge, which is what pins the mask/do-not-mask asymmetry."""
    a = dep_a()
    return derivation(
        name="dependent",
        system=SYSTEM,
        builder=SH,
        args=["-c", f"cat {a.output()} > $out"],
        input_drvs=[a],
    )


def many() -> Drv:
    """Three edges, named in an order that is NOT their store-path order.

    That is what makes this example evidence: `inputDrvs` has to come out
    sorted by path regardless of the order the caller used them in.
    """
    a, m, z = aaa(), mmm(), zzz()
    return derivation(
        name="many",
        system=SYSTEM,
        builder=SH,
        args=["-c", f"cat {z.output()} {a.output()} {m.output()} > $out"],
        input_drvs=[z, a, m],
    )


def ordering() -> Drv:
    """Env declared out of order, to pin that env is sorted by key."""
    return derivation(
        name="ordering",
        system=SYSTEM,
        builder=SH,
        env={"zzz": "last-declared-first", "aaa": "first", "mmm": "middle"},
    )


def multi() -> Drv:
    """Three outputs, which carries TWO orderings of the same list."""
    return derivation(
        name="multi",
        system=SYSTEM,
        builder=SH,
        outputs=["out", "dev", "lib"],
    )


def fixed() -> Drv:
    """A fixed-output derivation, with the hash written in base-32.

    The outputs tuple must carry it re-encoded as hex while the env keeps it
    exactly as written, which is the rule an implementation is most likely to
    get wrong.
    """
    return derivation(
        name="fixed",
        system=SYSTEM,
        builder=SH,
        fixed_output=FixedOutput(hash="0" * 52, algo="sha256"),
    )


def structured() -> Drv:
    """`__structuredAttrs`: attributes as JSON, with their types preserved.

    The flat encoding can only carry strings, so a boolean, an integer, a list
    or a nested attribute set has to be flattened and re-parsed by the builder.
    This one keeps them. 1223 of 2516 real derivations use it.

    It also exercises the same two-orderings rule as `multi`: the outputs tuple
    comes out sorted (`dev`, `out`) while `outputs` inside the JSON keeps
    declaration order (`out`, `dev`).
    """
    return derivation(
        name="structured",
        system=SYSTEM,
        builder=SH,
        args=["-c", "echo hi > $out"],
        outputs=["out", "dev"],
        structured_attrs=True,
        env={
            "aFlag": True,
            "aNumber": 42,
            "aList": ["x", "y"],
            "nested": {"deep": {"deeper": "value"}},
            "aString": "plain",
        },
    )


#: Golden file name -> the intent that must reproduce it byte for byte.
CORPUS: Mapping[str, Callable[[], Drv]] = {
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


# The DIFFERENTIAL probe, described through the eDSL.
#
# `scripts/probe.nix` is instantiated by the pinned Nix on every run, and until
# now only our PATH COMPUTATION was checked against the result: parse what Nix
# emitted, recompute the paths, compare. The eDSL itself was checked only
# against the golden files, which are checked in and therefore frozen.
#
# Describing the same five derivations here makes `make differential` a LIVE
# oracle for the eDSL too: our bytes against bytes a real nix-instantiate
# produced moments earlier, rather than against a file someone committed. A
# frozen golden cannot notice the ORACLE moving; this can.


def probe_dep(name: str, word: str) -> Drv:
    return derivation(
        name=name, system=SYSTEM, builder=SH, args=["-c", f"echo {word} > $out"]
    )


def probe_fetched() -> Drv:
    """Fixed-output, FLAT ingestion: the ``fixed:out:`` fingerprint scheme."""
    return derivation(
        name="fetched",
        system=SYSTEM,
        builder=SH,
        args=["-c", "echo hi > $out"],
        fixed_output=FixedOutput(hash="0" * 64, algo="sha256"),
    )


def probe_fetched_rec() -> Drv:
    """Fixed-output, RECURSIVE ingestion: the ``source`` kind.

    The declared hash is used DIRECTLY as the inner hash rather than wrapped in
    a fingerprint. Missing this costs exactly one path in a real closure, which
    is how it survived a hand-written corpus.
    """
    return derivation(
        name="fetched-rec",
        system=SYSTEM,
        builder=SH,
        args=["-c", "mkdir $out"],
        fixed_output=FixedOutput(
            hash="1" * 64, algo="sha256", mode="recursive"
        ),
    )


def probe() -> Drv:
    """Four input edges covering every scheme above, plus the awkward cases."""
    dep, dep2 = probe_dep("dep-a", "a"), probe_dep("dep-b", "b")
    fetched, fetched_rec = probe_fetched(), probe_fetched_rec()
    cat = " ".join(d.output() for d in (dep, dep2, fetched, fetched_rec))
    return derivation(
        name="probe",
        system=SYSTEM,
        builder=SH,
        args=["-c", f"cat {cat} > $out"],
        input_drvs=[dep, dep2, fetched, fetched_rec],
        outputs=["out", "dev", "lib"],
        env={
            "zzz": "last",
            "aaa": "first",
            "mmm": "middle",
            # No trailing newline: the probe writes this as a ONE-LINE indented
            # string, and one that does not end in a newline does not gain one.
            # Adding it was the first thing the live oracle caught.
            "nasty": NASTY,
        },
    )


def probe_corpus() -> list[Drv]:
    """Every derivation the probe closure contains."""
    return [
        probe_dep("dep-a", "a"),
        probe_dep("dep-b", "b"),
        probe_fetched(),
        probe_fetched_rec(),
        probe(),
    ]
