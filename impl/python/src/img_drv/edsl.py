"""The eDSL surface: DESCRIBE a build, and get a derivation back.

Everything else in this library reads derivations. This module is the other
direction, and it is the half of the thesis that can actually fail: if the
first-order signature in ``docs/spec/signature.md`` is enough, then a build is
described by a single application of :func:`derivation`, and the host language
supplies everything else.

    >>> from img_drv import derivation
    >>> hello = derivation(
    ...     name="hello",
    ...     system="x86_64-linux",
    ...     builder="/bin/sh",
    ...     args=["-c", "echo hi > $out"],
    ... )
    >>> hello.output()
    '/nix/store/mjs27ix6ig2bkbi3s3sm470vrv4lf7ic-hello'

That path is Nix's, byte for byte, and it is known BEFORE anything is built.
Depending on a derivation means naming the outputs you need:

    >>> dependent = derivation(
    ...     name="dependent",
    ...     system="x86_64-linux",
    ...     builder="/bin/sh",
    ...     args=["-c", f"cat {hello.output()} > $out"],
    ...     input_drvs=[hello],
    ... )

Note that the reference in ``args`` and the edge in ``input_drvs`` are written
separately. Nix couples them through string contexts, which is a feature of its
EVALUATOR; the signature deliberately has no computation in it, so the coupling
is the caller's to make. That is the cost of the design, and stating it is more
honest than hiding it behind an interpolation helper.

What this module adds over the raw :class:`~img_drv.derivation.Derivation`
record is exactly two things: the CANONICAL form (which orderings are
load-bearing), and the KNOT (output paths are the hash of the derivation that
contains them). Both are the sort of thing that produces a plausible wrong
answer rather than an error, which is why both are checked against real Nix
output rather than against examples.
"""

from __future__ import annotations

import base64
import binascii
import json
import pathlib
import string
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, replace
from typing import Final, Literal, TypeAlias, cast

from .aterm import unparse
from .derivation import (
    Derivation,
    InputDrv,
    Output,
    OutputName,
    Sha256Hex,
    StorePath,
)
from .store import (
    base32_decode,
    base32_length,
    drv_path,
    fixed_output_input_hash,
    output_paths,
    sha256_hex,
)

__all__ = [
    "Dep",
    "Drv",
    "FixedOutput",
    "HashAlgo",
    "HashMode",
    "InvalidDerivationError",
    "JsonValue",
    "canonical",
    "derivation",
    "json_env",
    "valid_name",
]

#: A JSON value, as `__structuredAttrs` carries it.
#:
#: This is the first RECURSIVE type in the signature. Everything else is a
#: product of primitives and lists of them, which is what `docs/theory.md`
#: section 1 restricts the signature to; a JSON value is an inductive datatype,
#: a fixed point of a polynomial functor. Still first-order and still
#: algebraic, so the Lawvere argument survives, but it is a genuine extension
#: and it is where a language without sum types has to work hardest.
#: Written as a `TypeAlias` with forward references rather than the 3.12
#: `type` statement, because the supported floor is 3.11.
JsonValue: TypeAlias = (
    str
    | int
    | float
    | bool
    | Sequence["JsonValue"]
    | Mapping[str, "JsonValue"]
    | None
)

#: The hash algorithms Nix accepts for a fixed-output derivation.
HashAlgo = Literal["md5", "sha1", "sha256", "sha512"]

#: How the output is ingested: a single file, or a NAR of a directory tree.
#: ``recursive`` is what puts the ``r:`` prefix on the serialized algorithm,
#: and ``r:sha256`` selects an entirely different store-path scheme.
HashMode = Literal["flat", "recursive"]

_DIGEST_BYTES: Final[Mapping[str, int]] = {
    "md5": 16,
    "sha1": 20,
    "sha256": 32,
    "sha512": 64,
}

#: Nix's store-name character set, and its length cap.
_NAME_CHARS: Final[frozenset[str]] = frozenset(
    string.ascii_letters + string.digits + "+-._?="
)
_NAME_MAX: Final = 211

#: Env keys this module derives from the other arguments. Passing one directly
#: would let the env disagree with the field it mirrors, which is a derivation
#: Nix would never emit.
_HASH_KEYS: Final[frozenset[str]] = frozenset(
    ("outputHash", "outputHashAlgo", "outputHashMode")
)
_ALWAYS_RESERVED: Final[frozenset[str]] = (
    frozenset(
        ("name", "system", "builder", "outputs", "__json", "__structuredAttrs")
    )
    | _HASH_KEYS
)

_DEFAULT_OUTPUT: Final = OutputName("out")


class InvalidDerivationError(ValueError):
    """A description that violates an invariant in ``spec/signature.md``.

    Raised at CONSTRUCTION time. The alternative is a derivation that
    serializes perfectly and means something else, which this project has
    already paid for once.
    """


def valid_name(name: str) -> bool:
    """Whether ``name`` is usable as a store path name.

    Accepts every name in the real corpus. That shows the predicate is not too
    strict; it does not show it is not too permissive, which is why
    ``spec/signature.md`` still lists the exact rules as open.
    """
    return (
        0 < len(name) <= _NAME_MAX
        and name not in (".", "..")
        and not name.startswith(".")
        and not set(name) - _NAME_CHARS
    )


def _as_algo(text: str) -> HashAlgo:
    if text not in _DIGEST_BYTES:
        raise InvalidDerivationError(
            f"unknown hash algorithm {text!r}; "
            f"expected one of {sorted(_DIGEST_BYTES)}"
        )
    return cast(HashAlgo, text)


@dataclass(frozen=True, slots=True)
class FixedOutput:
    """A declared result: the derivation's identity comes from this hash.

    ``hash`` is kept EXACTLY as written, because that is what reaches the env,
    while the outputs tuple carries it re-encoded as hex. Both forms are in
    ``examples/fixed.drv``, and the rule is verified on all 93 fixed-output
    derivations in the real corpus.

    ``algo`` may be omitted when ``hash`` is SRI (``sha256-<base64>``), which
    already names its algorithm. Real derivations do exactly that: 11 of the 93
    carry no ``outputHashAlgo`` at all.
    """

    hash: str
    algo: HashAlgo | None = None
    mode: HashMode = "flat"

    def __post_init__(self) -> None:
        if self.mode not in ("flat", "recursive"):
            raise InvalidDerivationError(f"unknown hash mode {self.mode!r}")
        self.resolved()  # decode eagerly, so a bad hash fails here

    def resolved(self) -> tuple[HashAlgo, str]:
        """``(algorithm, hex digest)``, decoded from whatever was written.

        Accepts hex, Nix base-32, base-64 and SRI. The corpus contains SRI and
        base-32 and no hex at all, so an implementation that accepts only hex
        parses nothing real.
        """
        text = self.hash
        if "-" in text:
            prefix, _, body = text.partition("-")
            algo = _as_algo(prefix)
            if self.algo is not None and self.algo != algo:
                raise InvalidDerivationError(
                    f"algo={self.algo!r} contradicts the SRI prefix {prefix!r}"
                )
            raw = _b64(body)
        else:
            if self.algo is None:
                raise InvalidDerivationError(
                    "algo is required unless the hash is SRI (sha256-...)"
                )
            # Checked rather than trusted: Literal is erased at runtime, so a
            # caller who is not type-checked can still hand over "sha3".
            algo = _as_algo(self.algo)
            size = _DIGEST_BYTES[algo]
            if len(text) == size * 2:
                try:
                    raw = bytes.fromhex(text)
                except ValueError as e:
                    raise InvalidDerivationError(f"not hex: {text!r}") from e
            elif len(text) == base32_length(size):
                try:
                    raw = base32_decode(text, size)
                except ValueError as e:
                    raise InvalidDerivationError(str(e)) from e
            else:
                raw = _b64(text)
        if len(raw) != _DIGEST_BYTES[algo]:
            raise InvalidDerivationError(
                f"{algo} needs {_DIGEST_BYTES[algo]} bytes, got {len(raw)}"
            )
        return algo, raw.hex()

    @property
    def hash_algo_field(self) -> str:
        """The serialized algorithm, with the ``r:`` prefix when recursive."""
        algo, _ = self.resolved()
        return f"r:{algo}" if self.mode == "recursive" else algo

    @property
    def hash_field(self) -> str:
        """The serialized hash: always lowercase hex."""
        return self.resolved()[1]

    def env(self) -> dict[str, str]:
        """The env entries Nix synthesizes for a fixed-output derivation.

        ``outputHashAlgo`` is omitted for an SRI hash, matching what real Nix
        emits; writing it anyway would change the bytes.
        """
        out = {"outputHash": self.hash, "outputHashMode": self.mode}
        if self.algo is not None:
            out["outputHashAlgo"] = self.algo
        return out


def json_env(attrs: Mapping[str, JsonValue]) -> str:
    """Serialize attributes the way `__structuredAttrs` does.

    Canonical, and the form is measured rather than chosen: object keys sorted
    ascending, compact separators, and non-ASCII emitted raw rather than
    ``\\uXXXX`` escaped. All three hold on 456 of 456 structured derivations
    in a real closure. See ``spec/canonical.md`` section 1.8.
    """
    return json.dumps(
        attrs, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    )


def _b64(text: str) -> bytes:
    try:
        return base64.b64decode(text, validate=True)
    except (binascii.Error, ValueError) as e:
        raise InvalidDerivationError(f"not base-64: {text!r}") from e


@dataclass(frozen=True, slots=True)
class Dep:
    """An edge: a derivation, and the outputs of it actually needed.

    The outputs belong to the EDGE rather than to the target, because two
    dependents of one package routinely need different outputs of it, and
    depending on ``dev`` alone is the common case in nixpkgs.
    """

    drv: Drv
    outputs: tuple[OutputName, ...] = (_DEFAULT_OUTPUT,)


@dataclass(frozen=True, slots=True)
class Drv:
    """A described derivation, and everything derivable from it.

    ``input_hash`` is the hash by which this derivation is known when it is
    someone ELSE's input, which is not the hash used to compute its own output
    paths. Keeping both on the value is what lets a dependent be built without
    re-walking the graph, and keeping them NAMED apart is what stops them being
    swapped, which is a bug this repository has already paid for.
    """

    derivation: Derivation
    path: StorePath
    input_hash: Sha256Hex

    @property
    def name(self) -> str:
        """The derivation name, as it appears in store path suffixes."""
        return self.derivation.name

    @property
    def outputs(self) -> Mapping[OutputName, StorePath]:
        """Every output name mapped to the path it will occupy."""
        return {o.name: o.path for o in self.derivation.outputs}

    def output(self, name: str = "out") -> StorePath:
        """The path of one output, known before anything is built."""
        try:
            return self.outputs[OutputName(name)]
        except KeyError:
            raise InvalidDerivationError(
                f"{self.name!r} has no output {name!r}; "
                f"it has {sorted(self.outputs)}"
            ) from None

    def ref(self, *outputs: str) -> Dep:
        """An edge to this derivation, needing ``outputs`` (default ``out``)."""
        names = tuple(OutputName(o) for o in outputs) or (_DEFAULT_OUTPUT,)
        for n in names:
            self.output(n)  # fail here rather than at build time
        return Dep(self, tuple(sorted(set(names))))

    def aterm(self) -> str:
        """The canonical bytes.

        These ARE the artifact: ``path`` is their hash, so a difference of
        one separator is a different derivation.
        """
        return unparse(self.derivation)

    def write(self, directory: pathlib.Path) -> pathlib.Path:
        """Write the ``.drv`` under ``directory``, named as in the store.

        No trailing newline: the store object does not have one, and adding one
        would change the hash of anything that reads it back.
        """
        target = directory / self.path.split("/")[-1]
        target.write_text(self.aterm())
        return target


def canonical(drv: Derivation) -> Derivation:
    """Put a derivation into canonical form.

    The orderings, all of which are load-bearing (``spec/canonical.md``):
    outputs by name, env by key, ``inputDrvs`` by store path with each inner
    name list sorted, ``inputSrcs`` ascending. ``args`` keeps its order,
    because there it is the meaning.

    This is idempotent, and it is the IDENTITY on every derivation real Nix
    emits, which is the sense in which the form is canonical rather than merely
    ours. Both are property-tested.
    """
    return Derivation(
        outputs=tuple(sorted(drv.outputs, key=lambda o: o.name)),
        input_drvs=tuple(
            sorted(
                (
                    InputDrv(i.path, tuple(sorted(set(i.outputs))))
                    for i in drv.input_drvs
                ),
                key=lambda i: i.path,
            )
        ),
        input_srcs=tuple(sorted(set(drv.input_srcs))),
        system=drv.system,
        builder=drv.builder,
        args=drv.args,
        env=tuple(sorted(drv.env)),
    )


def _edges(refs: Sequence[Dep | Drv]) -> tuple[Dep, ...]:
    """Coerce bare derivations to ``out`` edges, and merge duplicate targets.

    Two references to the same derivation are one entry with the union of the
    outputs needed, which is what Nix emits: store paths are unique within
    ``inputDrvs`` in 1293 of 1293 real derivations.
    """
    merged: dict[StorePath, tuple[Drv, set[OutputName]]] = {}
    for r in refs:
        dep = r.ref() if isinstance(r, Drv) else r
        _, names = merged.setdefault(dep.drv.path, (dep.drv, set()))
        names.update(dep.outputs)
    return tuple(
        Dep(drv, tuple(sorted(names))) for drv, names in merged.values()
    )


def derivation(
    *,
    name: str,
    system: str,
    builder: str,
    args: Sequence[str] = (),
    env: Mapping[str, JsonValue] | None = None,
    outputs: Sequence[str] | None = None,
    structured_attrs: bool = False,
    input_drvs: Sequence[Dep | Drv] = (),
    input_srcs: Sequence[str] = (),
    fixed_output: FixedOutput | None = None,
) -> Drv:
    """Describe a build. This is the whole eDSL.

    Keyword-only on purpose: nine positional arguments of mostly strings is a
    transposition waiting to happen, and ``system`` and ``builder`` are both
    strings that would silently swap.

    ``structured_attrs`` selects the SECOND env encoding (see
    ``spec/canonical.md`` section 1.8): attributes are carried as one
    ``__json`` entry with their types preserved, rather than one
    string-valued variable each. 1223 of 2516 real derivations use it, and it
    is the only way to hand a builder a list, a boolean or a nested attribute
    set without flattening it to a string. With it off, every ``env`` value
    must be a ``str``.

    ``outputs`` is an OPTION rather than a list defaulting to ``["out"]``, and
    the difference is observable in the bytes: passing ``None`` produces no
    ``outputs`` env variable (as a bare ``derivation { ... }`` does), while
    passing ``["out"]`` produces ``("outputs","out")``, as every nixpkgs
    package does. They are different derivations with different store paths.
    See ``spec/canonical.md`` section 1.7.

    Raises:
        InvalidDerivationError: if any invariant in ``spec/signature.md`` fails.
    """
    if not valid_name(name):
        raise InvalidDerivationError(
            f"{name!r} is not a valid store path name (see spec/signature.md)"
        )

    declared = outputs is not None
    names = (
        tuple(OutputName(o) for o in outputs)
        if outputs is not None
        else (_DEFAULT_OUTPUT,)
    )
    if not names:
        raise InvalidDerivationError("outputs must not be empty")
    if len(set(names)) != len(names):
        raise InvalidDerivationError(f"duplicate output names in {list(names)}")
    for n in names:
        if not valid_name(n):
            raise InvalidDerivationError(f"{n!r} is not a valid output name")
    if fixed_output is not None and len(names) != 1:
        raise InvalidDerivationError(
            "a fixed-output derivation has exactly one output, "
            f"got {list(names)}"
        )

    supplied = dict(env or {})
    reserved = _ALWAYS_RESERVED | set(names)
    clashes = sorted(reserved & supplied.keys())
    if clashes:
        raise InvalidDerivationError(
            f"env keys {clashes} are derived from the other arguments; "
            "set them through name/system/builder/outputs/fixed_output"
        )
    if not structured_attrs:
        untyped = sorted(
            k for k, v in supplied.items() if not isinstance(v, str)
        )
        if untyped:
            raise InvalidDerivationError(
                f"env values {untyped} are not strings; the flat encoding can "
                "only carry strings, so pass structured_attrs=True"
            )

    # Placeholders for the output paths. The real ones are the hash of the
    # derivation that contains them, so they cannot be known until after the
    # next step, and the masked form used to compute them blanks these anyway.
    placeholders = {str(n): "" for n in names}
    synthesized: dict[str, str]
    if structured_attrs:
        # One __json entry carrying every attribute WITH ITS TYPE, plus one
        # entry per output. The output paths stay outside the JSON, which is
        # why masking needs no special case. See spec/canonical.md 1.8.
        attrs: dict[str, JsonValue] = {
            **supplied,
            "name": name,
            "system": system,
            "builder": builder,
        }
        if declared:
            attrs["outputs"] = list(names)
        if fixed_output is not None:
            attrs.update(fixed_output.env())
        supplied = {}
        synthesized = {"__json": json_env(attrs), **placeholders}
    else:
        synthesized = {
            "name": name,
            "system": system,
            "builder": builder,
            **placeholders,
        }
        if declared:
            synthesized["outputs"] = " ".join(names)
        if fixed_output is not None:
            synthesized.update(fixed_output.env())

    algo = fixed_output.hash_algo_field if fixed_output else ""
    digest = fixed_output.hash_field if fixed_output else ""

    edges = _edges(input_drvs)
    draft = canonical(
        Derivation(
            outputs=tuple(
                Output(name=n, path=StorePath(""), hash_algo=algo, hash=digest)
                for n in names
            ),
            input_drvs=tuple(InputDrv(d.drv.path, d.outputs) for d in edges),
            input_srcs=tuple(StorePath(s) for s in input_srcs),
            system=system,
            builder=builder,
            args=tuple(args),
            env=tuple(
                {**cast("dict[str, str]", supplied), **synthesized}.items()
            ),
        )
    )

    input_hashes: dict[StorePath, str] = {
        d.drv.path: d.drv.input_hash for d in edges
    }
    paths = output_paths(draft, name, input_hashes)

    final = replace(
        draft,
        outputs=tuple(replace(o, path=paths[o.name]) for o in draft.outputs),
        env=tuple(
            (k, str(paths[OutputName(k)]) if OutputName(k) in paths else v)
            for k, v in draft.env
        ),
    )

    aterm = unparse(final)
    fixed = final.fixed_output
    return Drv(
        derivation=final,
        path=drv_path(aterm, name),
        input_hash=(
            fixed_output_input_hash(fixed)
            if fixed is not None
            else sha256_hex(unparse(final, input_hashes=input_hashes))
        ),
    )
