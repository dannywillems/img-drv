"""A closure of derivations, and the recursive hashing over it.

A real closure is a DAG with heavy sharing: a 226-derivation closure hashes
the same bootstrap tools hundreds of times. The memo table is what makes
verification linear in the number of edges rather than exponential in depth,
and it is correct because a derivation is immutable and its hash depends only
on its transitive inputs.

Structurally this is a fold over a DAG. :meth:`Corpus.input_hash` is defined by
WELL-FOUNDED recursion: the graph is finite and acyclic, so the recursion
terminates and picks out exactly one function, which is why every conforming
implementation in any language must produce the same digests.

(An earlier version of this docstring called it a homomorphism into "the monoid
of digests". That was an over-claim: digests carry no associative operation for
it to be a homomorphism of. See ``docs/abstractions.md`` entry 2.)
"""

from __future__ import annotations

import pathlib
from dataclasses import dataclass, field

from .aterm import parse, unparse
from .derivation import Derivation, OutputName, Sha256Hex, StorePath
from .store import (
    BASE32_ALPHABET,
    STORE,
    fixed_output_input_hash,
    output_paths,
    sha256_hex,
)

__all__ = ["Corpus", "Mismatch", "name_from_path"]

#: A store path basename is ``<32 base-32 chars>-<name>``.
_HASH_LEN = 32


def name_from_path(path: StorePath, drv: Derivation | None = None) -> str:
    """The derivation name that output paths are suffixed with.

    A real store path is ``<32 chars>-<name>.drv``, so the hash prefix is
    stripped. When the file is not named that way, fall back to the ``name``
    environment variable, which every derivation carries.
    """
    base = path.split("/")[-1].removesuffix(".drv")
    head, sep, tail = base.partition("-")
    if sep and len(head) == _HASH_LEN and not set(head) - set(BASE32_ALPHABET):
        return tail
    if drv is not None and drv.name:
        return drv.name
    return base


@dataclass(frozen=True, slots=True)
class Mismatch:
    """One output whose recomputed path differs from the recorded one."""

    drv_name: str
    output: OutputName
    expected: StorePath
    got: StorePath | None

    def __str__(self) -> str:
        return (
            f"{self.drv_name}:{self.output}\n"
            f"  expected {self.expected}\n"
            f"  got      {self.got}"
        )


@dataclass(slots=True)
class Corpus:
    """A set of derivations indexed by store path.

    Not every input is necessarily present: a closure exported from a store
    is complete, but a hand-assembled directory need not be. Inputs that are
    absent are left as paths, which is the only honest thing to do and is why
    an incomplete corpus produces mismatches rather than silence.
    """

    drvs: dict[StorePath, Derivation] = field(default_factory=dict)
    _memo: dict[StorePath, Sha256Hex] = field(default_factory=dict, repr=False)

    @classmethod
    def from_directory(cls, directory: pathlib.Path) -> Corpus:
        """Load every ``*.drv`` in a directory, keyed by its store path."""
        return cls(
            drvs={
                StorePath(f"{STORE}/{f.name}"): parse(f.read_text())
                for f in sorted(directory.glob("*.drv"))
            }
        )

    def __len__(self) -> int:
        return len(self.drvs)

    def input_hash(self, path: StorePath) -> Sha256Hex:
        """The hash by which a derivation is known when it is someone's INPUT.

        Outputs are NOT masked here; that is the asymmetry documented in
        :func:`img_drv.store.output_paths`. Recursive, because substituting a
        derivation's inputs needs their own input-hashes first.
        """
        memoized = self._memo.get(path)
        if memoized is not None:
            return memoized
        drv = self.drvs[path]
        fixed = drv.fixed_output
        if fixed is not None:
            h = fixed_output_input_hash(fixed)
        else:
            h = sha256_hex(
                unparse(
                    drv,
                    mask_outputs=False,
                    input_hashes=self.input_hashes_of(drv),
                )
            )
        self._memo[path] = h
        return h

    def input_hashes_of(self, drv: Derivation) -> dict[StorePath, str]:
        """The substitution map for one derivation's present inputs."""
        return {
            i.path: self.input_hash(i.path)
            for i in drv.input_drvs
            if i.path in self.drvs
        }

    def output_paths_of(self, path: StorePath) -> dict[OutputName, StorePath]:
        """Recompute every output path of one derivation in this corpus."""
        drv = self.drvs[path]
        return output_paths(
            drv, name_from_path(path, drv), self.input_hashes_of(drv)
        )

    def verify(self) -> tuple[int, list[Mismatch]]:
        """Recompute every output path and compare with the recorded one.

        Returns the number of outputs checked and every mismatch. These are
        real derivations produced by real Nix, so this is a regression test
        against vectors nobody wrote by hand.
        """
        checked = 0
        bad: list[Mismatch] = []
        for path, drv in sorted(self.drvs.items()):
            got = self.output_paths_of(path)
            for o in drv.outputs:
                checked += 1
                if got.get(o.name) != o.path:
                    bad.append(
                        Mismatch(
                            drv_name=name_from_path(path, drv),
                            output=o.name,
                            expected=o.path,
                            got=got.get(o.name),
                        )
                    )
        return checked, bad
