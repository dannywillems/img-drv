"""Command line entry points, so CI and a laptop run the same code.

    python -m img_drv verify <dir>      recompute every store path
    python -m img_drv roundtrip <dir>   parse then re-serialize, byte for byte

Both exit non-zero on any failure, which is what makes them usable as CI
gates.
"""

from __future__ import annotations

import argparse
import pathlib
import sys

from .aterm import parse, unparse
from .corpus import Corpus


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


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="img_drv")
    sub = ap.add_subparsers(dest="command", required=True)
    for name in ("verify", "roundtrip"):
        p = sub.add_parser(name)
        p.add_argument("directory", type=pathlib.Path)
    ns = ap.parse_args(argv)
    directory: pathlib.Path = ns.directory
    if not directory.is_dir():
        print(f"not a directory: {directory}", file=sys.stderr)
        return 2
    return verify(directory) if ns.command == "verify" else roundtrip(directory)


if __name__ == "__main__":
    sys.exit(main())
