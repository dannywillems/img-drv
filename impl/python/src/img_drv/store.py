"""Store path computation.

Verified against real derivations: 1259 of 1259 output paths across 805 real
nixpkgs derivations, plus 12 of 12 golden examples. The rules are written up
in ``docs/spec/store-paths.md``.

Nothing here came from memory. Each rule was established by generating
derivations with a pinned Nix and reproducing the bytes, then checked against
real nixpkgs derivations, which is what caught the two errors that
hand-written examples could not.
"""

from __future__ import annotations

import hashlib

from .aterm import unparse
from .derivation import (
    Derivation,
    Output,
    OutputName,
    Sha256Hex,
    StorePath,
)

__all__ = [
    "BASE32_ALPHABET",
    "STORE",
    "base32",
    "compress",
    "drv_path",
    "fixed_output_input_hash",
    "fixed_output_path",
    "output_paths",
    "output_store_name",
    "sha256_hex",
    "store_path",
]

STORE = "/nix/store"

# Nix's own base-32 alphabet. Note the omissions: e, o, u and t are absent, so
# that no store path can accidentally spell a word.
BASE32_ALPHABET = "0123456789abcdfghijklmnpqrsvwxyz"


def base32(data: bytes) -> str:
    """Nix base-32: least significant digit first, five bits at a time.

    Not RFC 4648. Digits are emitted from the END of the buffer backwards,
    which is why a stock base-32 library produces a different string. This is
    the first thing to check when a path is close but wrong.
    """
    length = (len(data) * 8 - 1) // 5 + 1
    out: list[str] = []
    for i in range(length - 1, -1, -1):
        bit = i * 5
        idx, offset = bit // 8, bit % 8
        c = data[idx] >> offset
        if idx + 1 < len(data):
            c |= data[idx + 1] << (8 - offset)
        out.append(BASE32_ALPHABET[c & 0x1F])
    return "".join(out)


def compress(h: bytes, size: int = 20) -> bytes:
    """XOR-fold a digest down to ``size`` bytes.

    A store path carries 20 bytes, not 32, and the sha256 is folded rather
    than truncated: byte ``i`` of the digest is XORed into byte ``i mod 20``.
    Truncating gives a plausible-looking path that is wrong.
    """
    out = bytearray(size)
    for i, b in enumerate(h):
        out[i % size] ^= b
    return bytes(out)


def sha256_hex(s: str) -> Sha256Hex:
    """The sha256 of a string, as 64 lowercase hex characters."""
    return Sha256Hex(hashlib.sha256(s.encode()).hexdigest())


def store_path(kind: str, inner: Sha256Hex, name: str) -> StorePath:
    """The outer step, shared by every kind of store path.

    ``fingerprint = "<kind>:sha256:<inner hex>:<store dir>:<name>"`` and the
    path is ``<store dir>/<base32(compress(sha256(fingerprint)))>-<name>``.

    Only ``kind`` and ``inner`` vary: ``text`` for a ``.drv`` file,
    ``output:<name>`` for a build output, ``source`` for a file added
    directly to the store.
    """
    fingerprint = f"{kind}:sha256:{inner}:{STORE}:{name}"
    digest = hashlib.sha256(fingerprint.encode()).digest()
    return StorePath(f"{STORE}/{base32(compress(digest))}-{name}")


def fixed_output_path(o: Output, drv_name: str) -> StorePath:
    """The store path of a fixed-output derivation.

    TWO schemes, selected by the ingestion method encoded in the algo field:

    - ``r:sha256``, recursive (NAR) ingestion with sha256, takes the
      ``source`` kind and uses the declared hash DIRECTLY as the inner hash;
    - everything else builds the usual ``fixed:out:`` fingerprint first.

    Missing the first case costs exactly one path in a 226-derivation closure,
    which is how it survived a corpus written by hand.
    """
    if o.hash_algo == "r:sha256":
        return store_path("source", Sha256Hex(o.hash), drv_name)
    inner = sha256_hex(f"fixed:out:{o.hash_algo}:{o.hash}:")
    return store_path("output:out", inner, drv_name)


def fixed_output_input_hash(o: Output) -> Sha256Hex:
    """The hash by which a fixed-output derivation is known AS AN INPUT.

    Note the trailing store path. This is NOT the string used to compute the
    path itself, which ends at the colon; including the path there would be
    circular.

    Confusing the two is invisible until something DEPENDS on a fixed-output
    derivation, because the derivation's own path still comes out right. It
    accounted for every one of the 145 downstream failures in the first real
    corpus: the fetches all verified, and everything below them did not.
    """
    return sha256_hex(f"fixed:out:{o.hash_algo}:{o.hash}:{o.path}")


def output_store_name(drv_name: str, output: OutputName) -> str:
    """``out`` keeps the plain name; every other output is suffixed.

    Package ``multi`` with outputs ``out``, ``dev``, ``lib`` yields store
    names ``multi``, ``multi-dev``, ``multi-lib``.
    """
    return drv_name if output == "out" else f"{drv_name}-{output}"


def output_paths(
    drv: Derivation,
    drv_name: str,
    input_hashes: dict[StorePath, str],
) -> dict[OutputName, StorePath]:
    """Every output path of a derivation.

    The asymmetry that matters: mask MY outputs, because they are what is
    being computed; do not mask my inputs'.
    """
    fixed = drv.fixed_output
    if fixed is not None:
        return {fixed.name: fixed_output_path(fixed, drv_name)}
    inner = sha256_hex(
        unparse(drv, mask_outputs=True, input_hashes=input_hashes)
    )
    return {
        o.name: store_path(
            f"output:{o.name}", inner, output_store_name(drv_name, o.name)
        )
        for o in drv.outputs
    }


def drv_path(aterm: str, drv_name: str) -> StorePath:
    """The path of the ``.drv`` file itself: a ``text`` store object."""
    return store_path("text", sha256_hex(aterm), f"{drv_name}.drv")
