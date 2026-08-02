"""Command line entry points, so CI and a laptop run the same code.

    python -m img_drv verify <dir>      recompute every store path
    python -m img_drv roundtrip <dir>   parse then re-serialize, byte for byte
    python -m img_drv canonical <dir>   canonicalizing must change nothing
    python -m img_drv drvpaths <dir>    recompute each .drv's own store path
    python -m img_drv examples <dir>    emit the conformance corpus

All exit non-zero on any failure, which is what makes them usable as CI
gates. `examples` is what `make conformance` drives: each implementation
emits the same ten intents, and the bytes are diffed against each other and
against what real Nix produced.
"""

from __future__ import annotations

import argparse
import pathlib
import sys

from .aterm import parse, unparse
from .corpus import Corpus
from .edsl import canonical
from .examples import CORPUS


def verify(directory: pathlib.Path) -> int:
    corpus = Corpus.from_directory(directory)
    checked, bad = corpus.verify()
    for m in bad:
        print(f"FAIL {m}")
    print(
        f"{checked - len(bad)}/{checked} output paths reproduced "
        f"from {len(corpus)} derivations"
    )
    return 1 if bad else 0


def roundtrip(directory: pathlib.Path) -> int:
    ok = bad = 0
    for f in sorted(directory.glob("*.drv")):
        text = f.read_text().rstrip("\n")
        try:
            if unparse(parse(text)) == text:
                ok += 1
            else:
                bad += 1
                print(f"ROUND-TRIP DIFFERS: {f.name}")
        except ValueError as exc:
            bad += 1
            print(f"PARSE ERROR {f.name}: {exc}")
    print(f"{ok}/{ok + bad} round-tripped byte-identically")
    return 1 if bad else 0


def canonical_check(directory: pathlib.Path) -> int:
    """Assert the canonical form is NIX's, not merely ours.

    The eDSL emits canonical bytes, so every ordering rule it applies is a
    claim about what Nix does. If canonicalizing a real derivation changed it,
    that claim would be false and "byte-identical across four languages" would
    only mean the four agree with each other.
    """
    ok = bad = 0
    for f in sorted(directory.glob("*.drv")):
        drv = parse(f.read_text())
        if canonical(drv) == drv:
            ok += 1
        else:
            bad += 1
            print(f"NOT CANONICAL: {f.name}")
    print(f"{ok}/{ok + bad} real derivations are already canonical")
    return 1 if bad else 0


def examples(directory: pathlib.Path) -> int:
    """Emit every intent in the conformance corpus, named as in the store.

    The FILENAME is the derivation's own computed store path, so a wrong hash
    shows up as a differently named file rather than as differing content,
    and `make conformance` catches both.
    """
    directory.mkdir(parents=True, exist_ok=True)
    for build in CORPUS.values():
        build().write(directory)
    print(f"{len(CORPUS)} derivations written to {directory}")
    return 0


def drvpaths(directory: pathlib.Path) -> int:
    """Recompute each derivation's own `.drv` path from its bytes.

    The corpus filenames are real Nix store paths, which makes this a free
    check nothing performed until the transpiler's commuting square found the
    gap.
    """
    corpus = Corpus.from_directory(directory)
    checked, bad = corpus.verify_drv_paths()
    for m in bad:
        print(f"FAIL {m}")
    print(f"{checked - len(bad)}/{checked} .drv paths recomputed from bytes")
    return 1 if bad else 0


COMMANDS = {
    "verify": verify,
    "roundtrip": roundtrip,
    "canonical": canonical_check,
    "drvpaths": drvpaths,
    "examples": examples,
}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="img_drv")
    sub = ap.add_subparsers(dest="command", required=True)
    for name in COMMANDS:
        p = sub.add_parser(name)
        p.add_argument("directory", type=pathlib.Path)
    ns = ap.parse_args(argv)
    directory: pathlib.Path = ns.directory
    if ns.command != "examples" and not directory.is_dir():
        print(f"not a directory: {directory}", file=sys.stderr)
        return 2
    return COMMANDS[str(ns.command)](directory)


if __name__ == "__main__":
    sys.exit(main())
