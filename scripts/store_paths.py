#!/usr/bin/env python3
"""Nix store path computation, derived empirically and self-checking.

Run it: every path in docs/spec/examples/ is recomputed from the derivation
text alone and compared with what real Nix produced. Any mismatch is a bug in
this file or in the spec, and the script exits non-zero.

This is the reference for the rules written up in docs/spec/store-paths.md.
Nothing here was taken from memory: each rule was established by generating
derivations with real Nix (2.35.1) and reproducing the bytes, then checked
against real nixpkgs derivations, which is what caught the errors the
hand-written examples could not.
"""

from __future__ import annotations

import hashlib
import pathlib
import sys

from aterm import Derivation, parse, unparse

STORE = "/nix/store"

# Nix's own base-32 alphabet. Note the omissions: e, o, u and t are absent, so
# that no store path can accidentally spell a word.
BASE32_ALPHABET = "0123456789abcdfghijklmnpqrsvwxyz"


def base32(data: bytes) -> str:
    """Nix base-32: least significant digit first, five bits at a time.

    Not RFC 4648. The digits are emitted from the END of the buffer backwards,
    which is why a naive base-32 library produces a different string.
    """
    length = (len(data) * 8 - 1) // 5 + 1
    out = []
    for i in range(length - 1, -1, -1):
        bit = i * 5
        idx, offset = bit // 8, bit % 8
        c = data[idx] >> offset
        if idx + 1 < len(data):
            c |= data[idx + 1] << (8 - offset)
        out.append(BASE32_ALPHABET[c & 0x1F])
    return "".join(out)


def compress(h: bytes, size: int = 20) -> bytes:
    """XOR-fold a hash down to `size` bytes.

    A store path holds 20 bytes, not 32, so the sha256 is folded rather than
    truncated: byte i of the digest is XORed into byte i mod 20.
    """
    out = bytearray(size)
    for i, b in enumerate(h):
        out[i % size] ^= b
    return bytes(out)


def store_path(kind: str, inner_hex: str, name: str) -> str:
    """The outer step, shared by every kind of store path.

    fingerprint = "<kind>:sha256:<inner hex>:<store dir>:<name>"
    path        = <store dir>/<base32(compress(sha256(fingerprint)))>-<name>

    `kind` is what varies: "text" for a .drv, "output:<name>" for a build
    output, "source" for an added file.
    """
    fingerprint = f"{kind}:sha256:{inner_hex}:{STORE}:{name}"
    digest = hashlib.sha256(fingerprint.encode()).digest()
    return f"{STORE}/{base32(compress(digest))}-{name}"


def sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


# --- the two hashes -------------------------------------------------------


def fixed_output_hash(drv: Derivation) -> str | None:
    """A fixed-output derivation is identified by its DECLARED hash.

    Its content is known in advance, so two fixed-output derivations fetching
    the same bytes are interchangeable however differently they are written.
    That is what lets every fetchurl in nixpkgs share a cache entry.
    """
    for o in drv.outputs:
        if o.fixed:
            return sha256_hex(f"fixed:out:{o.hash_algo}:{o.hash}:")
    return None


def input_hash(path: str, corpus: dict[str, Derivation], memo: dict[str, str]) -> str:
    """The hash by which a derivation is known when it is someone's INPUT.

    Outputs are NOT masked here. Recursive, because substituting a
    derivation's inputs needs their own input-hashes first, and memoized
    because a real closure is a DAG with heavy sharing.
    """
    if path in memo:
        return memo[path]
    drv = corpus[path]
    fixed = fixed_output_hash(drv)
    if fixed is None:
        inputs = {
            dep: input_hash(dep, corpus, memo)
            for dep, _outs in drv.input_drvs
            if dep in corpus
        }
        fixed = sha256_hex(unparse(drv, mask_outputs=False, input_hashes=inputs))
    memo[path] = fixed
    return fixed


def output_store_name(drv_name: str, output: str) -> str:
    """`out` keeps the plain name; every other output is suffixed."""
    return drv_name if output == "out" else f"{drv_name}-{output}"


def output_paths(
    drv: Derivation, drv_name: str, input_hashes: dict[str, str]
) -> dict[str, str]:
    """Every output path of a derivation.

    The asymmetry: mask MY outputs, because they are what is being computed;
    do not mask my inputs'.
    """
    fixed = fixed_output_hash(drv)
    if fixed is not None:
        return {"out": store_path("output:out", fixed, drv_name)}
    inner = sha256_hex(unparse(drv, mask_outputs=True, input_hashes=input_hashes))
    return {
        o.name: store_path(
            f"output:{o.name}", inner, output_store_name(drv_name, o.name)
        )
        for o in drv.outputs
    }


def drv_path(aterm: str, drv_name: str) -> str:
    """The path of the .drv file itself: a "text" store object."""
    return store_path("text", sha256_hex(aterm), f"{drv_name}.drv")


def name_of(store_path_str: str) -> str:
    """`/nix/store/<32 chars>-hello-2.12.3.drv` -> `hello-2.12.3`."""
    return store_path_str.split("/")[-1].split("-", 1)[1].removesuffix(".drv")


# --- verification ---------------------------------------------------------


def verify_corpus(directory: pathlib.Path) -> tuple[int, int]:
    """Recompute every output path of every derivation in a directory.

    These are real derivations exported from a Nix store, so this is a
    regression test against vectors nobody wrote by hand.
    """
    corpus = {
        f"{STORE}/{f.name}": parse(f.read_text())
        for f in directory.glob("*.drv")
    }
    memo: dict[str, str] = {}
    checked = failures = 0
    for path, drv in sorted(corpus.items()):
        inputs = {
            dep: input_hash(dep, corpus, memo)
            for dep, _outs in drv.input_drvs
            if dep in corpus
        }
        got = output_paths(drv, name_of(path), inputs)
        for o in drv.outputs:
            checked += 1
            if got.get(o.name) != o.path:
                failures += 1
                print(f"FAIL {name_of(path)}:{o.name}")
                print(f"  expected {o.path}")
                print(f"  got      {got.get(o.name)}")
    return checked, failures


def main() -> int:
    if len(sys.argv) > 1:
        directory = pathlib.Path(sys.argv[1])
        checked, failures = verify_corpus(directory)
        n = len(list(directory.glob("*.drv")))
        print(f"{checked - failures}/{checked} output paths reproduced "
              f"from {n} real derivations")
        return 1 if failures else 0

    examples = pathlib.Path(__file__).resolve().parent.parent / "docs/spec/examples"
    checked, failures = verify_corpus(examples)
    print(f"{checked - failures}/{checked} output paths reproduced "
          f"from the golden examples")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
