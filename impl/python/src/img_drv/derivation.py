"""The derivation types.

These are the carrier of the whole library: everything else parses into them,
serializes out of them, or hashes them. They are frozen and slotted, so a
derivation is a value rather than a mutable record, which is what lets it be
used as the key of a memo table and compared by equality.

The `NewType` aliases carry no runtime cost and are not decoration. A store
path, a hex digest and an output name are all `str` at runtime, and confusing
them is exactly the class of bug this repository has already paid for once: a
derivation's own path and the hash by which it is known as an input are both
64-character strings, and swapping them produces a plausible wrong answer
rather than an error.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import NewType

__all__ = [
    "Derivation",
    "InputDrv",
    "Output",
    "OutputName",
    "Sha256Hex",
    "StorePath",
]

#: An absolute path in the store, e.g. ``/nix/store/<32 chars>-hello``.
StorePath = NewType("StorePath", str)

#: A sha256 digest as 64 lowercase hex characters.
Sha256Hex = NewType("Sha256Hex", str)

#: The name of one output of a derivation: ``out``, ``dev``, ``lib``, ...
OutputName = NewType("OutputName", str)


@dataclass(frozen=True, slots=True)
class Output:
    """One output of a derivation.

    ``hash_algo`` and ``hash`` are empty for an ordinary derivation. When they
    are set the derivation is FIXED-OUTPUT: it declares its result in advance,
    so its identity comes from the declared hash rather than from how it is
    built. That is the escape hatch that lets a build fetch from the network
    while staying reproducible.
    """

    name: OutputName
    path: StorePath
    hash_algo: str = ""
    hash: str = ""

    @property
    def fixed(self) -> bool:
        """Whether this output declares its content hash in advance."""
        return bool(self.hash_algo)


@dataclass(frozen=True, slots=True)
class InputDrv:
    """A dependency on specific outputs of another derivation.

    Depending on ``dev`` alone is a real and common case, so the set of needed
    output names is part of the edge rather than a property of the target.
    """

    path: StorePath
    outputs: tuple[OutputName, ...]


@dataclass(frozen=True, slots=True)
class Derivation:
    """A build description: the seven fields of the ``Derive(...)`` form.

    Field order is the serialization order and is load-bearing. See
    ``docs/spec/canonical.md``.
    """

    outputs: tuple[Output, ...] = ()
    input_drvs: tuple[InputDrv, ...] = ()
    input_srcs: tuple[StorePath, ...] = ()
    system: str = ""
    builder: str = ""
    args: tuple[str, ...] = ()
    env: tuple[tuple[str, str], ...] = ()

    @property
    def output_names(self) -> frozenset[OutputName]:
        """The names of this derivation's own outputs.

        Used when masking: an env entry is blanked when its KEY is one of
        these, never when an output path merely appears inside some value.
        """
        return frozenset(o.name for o in self.outputs)

    @property
    def fixed_output(self) -> Output | None:
        """The fixed output, if this is a fixed-output derivation."""
        for o in self.outputs:
            if o.fixed:
                return o
        return None

    @property
    def name(self) -> str:
        """The derivation name, from the ``name`` environment variable.

        Every derivation carries one, and it is what output store names are
        built from.
        """
        for key, value in self.env:
            if key == "name":
                return value
        return ""
