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

from aterm import Derivation, Output, parse, unparse

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


def fixed_output(drv: Derivation) -> Output | None:
    for o in drv.outputs:
        if o.fixed:
            return o
    return None


def fixed_output_path(o: Output, drv_name: str) -> str:
    """The store path of a fixed-output derivation.

    TWO schemes, and which one applies depends on the ingestion method that is
    encoded in the algo field itself:

    - `r:sha256`, i.e. recursive/NAR ingestion with sha256, takes the `source`
      kind and uses the declared hash DIRECTLY as the inner hash;
    - everything else builds the usual `fixed:out:...` fingerprint first.

    Missing the first case costs exactly one path in a real closure, which is
    how it survived a corpus of examples written by hand.
    """
    if o.hash_algo == "r:sha256":
        return store_path("source", o.hash, drv_name)
    return store_path("output:out", sha256_hex(f"fixed:out:{o.hash_algo}:{o.hash}:"), drv_name)


def fixed_output_input_hash(o: Output) -> str:
    """The hash by which a fixed-output derivation is known AS AN INPUT.

    Note the trailing store path. This is NOT the same string used to compute
    the path itself, which ends at the colon: including the path here would be
    circular there.

    Getting these two confused is invisible until something DEPENDS on a
    fixed-output derivation, because the derivation's own path still comes out
    right. It accounted for every one of the 145 failures in the first real
    corpus: the fetches all verified, and everything downstream of them did
    not.
    """
    return sha256_hex(f"fixed:out:{o.hash_algo}:{o.hash}:{o.path}")


def input_hash(path: str, corpus: dict[str, Derivation], memo: dict[str, str]) -> str:
    """The hash by which a derivation is known when it is someone's INPUT.

    Outputs are NOT masked here. Recursive, because substituting a
    derivation's inputs needs their own input-hashes first, and memoized
    because a real closure is a DAG with heavy sharing.
    """
    if path in memo:
        return memo[path]
    drv = corpus[path]
    o = fixed_output(drv)
    if o is not None:
        h = fixed_output_input_hash(o)
    else:
        inputs = {
            dep: input_hash(dep, corpus, memo)
            for dep, _outs in drv.input_drvs
            if dep in corpus
        }
        h = sha256_hex(unparse(drv, mask_outputs=False, input_hashes=inputs))
    memo[path] = h
    return h


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
    o = fixed_output(drv)
    if o is not None:
        return {o.name: fixed_output_path(o, drv_name)}
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


def name_of(store_path_str: str, drv: Derivation | None = None) -> str:
    """The derivation's name, which is what output paths are suffixed with.

    A real store path is `<32 chars>-<name>.drv`, so the hash prefix is
    stripped. The golden examples are named after the case they demonstrate
    rather than after the derivation, so fall back to the `name` environment
    variable, which every derivation carries.
    """
    base = store_path_str.split("/")[-1].removesuffix(".drv")
    head, sep, tail = base.partition("-")
    if sep and len(head) == 32 and not set(head) - set(BASE32_ALPHABET):
        return tail
    if drv is not None:
        for k, v in drv.env:
            if k == "name":
                return v
    return base


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
        got = output_paths(drv, name_of(path, drv), inputs)
        for o in drv.outputs:
            checked += 1
            if got.get(o.name) != o.path:
                failures += 1
                print(f"FAIL {name_of(path, drv)}:{o.name}")
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
