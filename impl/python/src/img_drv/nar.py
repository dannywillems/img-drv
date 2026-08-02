"""NAR: the Nix Archive format, and the store path of a source.

The last unspecified corner of the format (``docs/spec/canonical.md`` section
3), and the one half of the ``.drv`` references rule that nothing we produced
could exercise: a derivation's fingerprint lists its ``inputDrvs`` *and* its
``inputSrcs``, and until now every derivation we built had an empty
``inputSrcs``.

The format
----------

NAR is a canonical serialization of a filesystem object, and canonical is the
whole point: two directories with the same contents serialize to the same bytes
regardless of inode order, mtimes, ownership or permissions beyond one bit.
Everything a filesystem records that is not content is deliberately discarded.

The grammar, from the Nix thesis (Dolstra 2006, figure 5.2)::

    serialise(fso)  = str("nix-archive-1") ++ node(fso)
    node(fso)       = str("(") ++ body(fso) ++ str(")")

    body(Regular)   = str("type") str("regular")
                      [ str("executable") str("") ]
                      str("contents") str(contents)
    body(Symlink)   = str("type") str("symlink") str("target") str(target)
    body(Directory) = str("type") str("directory") entry*

    entry           = str("entry") str("(") str("name") str(name)
                      str("node") node str(")")

    str(s)          = int(len(s)) ++ s ++ zero padding to a multiple of 8
    int(n)          = 8 bytes, little endian

Three details decide whether an implementation is right, and all three are
invisible in a happy-path test:

- directory entries are sorted by name, BYTE-wise, not by locale;
- the executable BIT is the only permission preserved, and it is encoded as the
  presence of a field rather than as a value;
- padding is to eight bytes and the pad is zeroes, so a length that is already
  a multiple of eight adds nothing rather than a full block.

Why this module takes a TREE and not a path
--------------------------------------------

A filesystem object is an inductive type, the initial algebra of

    F(X) = (contents x executable) + target + (name x X)*

and NAR is the unique homomorphism out of it into bytes: a CATAMORPHISM.
Writing it that way rather than as a directory walk makes the serializer
testable without a filesystem and puts the part that decides the bytes where it
can be read. :func:`read_fso` materialises the tree; everything else is pure.

The store path
--------------

A source added to the store is the ``source`` kind of
``docs/spec/store-paths.md``, with the NAR's sha256 as the inner hash::

    source_path = store_path("source", sha256(nar(fso)), name)

and it takes the SAME references treatment as a ``.drv``: the kind becomes
``source:<ref>:<ref>:...`` when the object refers to other store paths. That is
`makeType` in Nix, shared by both, which is why getting it wrong for ``text``
got it wrong for ``source`` too.
"""

from __future__ import annotations

import hashlib
import pathlib
from collections.abc import Iterable
from dataclasses import dataclass
from typing import TypeAlias

from .derivation import Sha256Hex, StorePath
from .store import store_path

__all__ = [
    "Directory",
    "Fso",
    "Regular",
    "Symlink",
    "nar",
    "read_fso",
    "source_path",
]


@dataclass(frozen=True, slots=True)
class Regular:
    """A file. The executable bit is the ONLY permission NAR keeps."""

    contents: bytes
    executable: bool = False


@dataclass(frozen=True, slots=True)
class Symlink:
    target: str


@dataclass(frozen=True, slots=True)
class Directory:
    entries: tuple[tuple[str, Fso], ...]


#: A filesystem object, as NAR understands one. Note what is ABSENT: mtimes,
#: ownership, and every permission but one. NAR does not discard them as an
#: optimisation; a format that kept them could not be canonical.
Fso: TypeAlias = Regular | Symlink | Directory


def _pad(payload: bytes) -> bytes:
    """Zero-pad to a multiple of eight, adding nothing when already aligned."""
    remainder = len(payload) % 8
    return payload if remainder == 0 else payload + b"\0" * (8 - remainder)


def _int(n: int) -> bytes:
    return n.to_bytes(8, "little")


def _str(s: bytes | str) -> bytes:
    payload = s.encode() if isinstance(s, str) else s
    return _int(len(payload)) + _pad(payload)


def _node(fso: Fso) -> bytes:
    """One filesystem object, wrapped in its parentheses."""
    out = [_str("(")]
    if isinstance(fso, Symlink):
        out += [_str("type"), _str("symlink"), _str("target"), _str(fso.target)]
    elif isinstance(fso, Directory):
        out += [_str("type"), _str("directory")]
        # Sorted BY BYTES. A locale-aware sort produces a different archive and
        # therefore a different store path, on the same directory.
        for name, child in sorted(fso.entries, key=lambda e: e[0].encode()):
            out += [_str("entry"), _str("("), _str("name"), _str(name)]
            out += [_str("node"), _node(child), _str(")")]
    else:
        out += [_str("type"), _str("regular")]
        # The executable bit is the ONLY permission NAR keeps, and it is
        # encoded as a present-or-absent field rather than as a value.
        if fso.executable:
            out += [_str("executable"), _str("")]
        out += [_str("contents"), _str(fso.contents)]
    out.append(_str(")"))
    return b"".join(out)


def nar(fso: Fso) -> bytes:
    """Serialize a filesystem object to its canonical NAR bytes."""
    return _str("nix-archive-1") + _node(fso)


def nar_hash(fso: Fso) -> Sha256Hex:
    """The sha256 of the NAR, as 64 lowercase hex characters."""
    return Sha256Hex(hashlib.sha256(nar(fso)).hexdigest())


def read_fso(path: pathlib.Path) -> Fso:
    """Materialise a real path as a tree.

    The only part of NAR that touches the disk.
    """
    if path.is_symlink():
        return Symlink(str(path.readlink()))
    if path.is_dir():
        return Directory(
            tuple((c.name, read_fso(c)) for c in sorted(path.iterdir()))
        )
    return Regular(path.read_bytes(), bool(path.stat().st_mode & 0o111))


def source_path(
    fso: Fso,
    name: str,
    references: Iterable[str] = (),
) -> StorePath:
    """The store path a source lands at, as ``nix-store --add`` computes it.

    ``references`` take the same treatment as a ``.drv``'s: sorted, joined with
    colons, and appended to the kind. Shared with the ``text`` kind through
    Nix's ``makeType``, which is why one bug in that rule was two bugs.
    """
    refs = sorted(set(references))
    kind = "source:" + ":".join(refs) if refs else "source"
    return store_path(kind, nar_hash(fso), name)
