#!/usr/bin/env python3
"""Nix store path computation, derived empirically and self-checking.

Run it: every path in docs/spec/examples/ is recomputed from the derivation
text alone and compared with what real Nix produced. Any mismatch is a bug in
this file or in the spec, and the script exits non-zero.

This is the reference for the rules written up in docs/spec/store-paths.md.
Nothing here was taken from memory: each rule was established by generating
derivations with real Nix (2.35.1) and reproducing the bytes.
"""

from __future__ import annotations

import hashlib
import pathlib
import re
import sys

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


# --- parsing just enough ATerm to test with -------------------------------
#
# A real implementation builds the ATerm rather than parsing it. These helpers
# exist so the golden files can be checked without a full parser.

OUTPUT_RE = re.compile(r'\("([^"]+)","(/nix/store/[^"]*)","([^"]*)","([^"]*)"\)')
INPUTDRV_RE = re.compile(r'\("(/nix/store/[^"]*\.drv)",\[([^\]]*)\]\)')


def outputs_of(aterm: str) -> list[tuple[str, str, str, str]]:
    head = aterm.split("],[", 1)[0]
    return OUTPUT_RE.findall(head)


def mask_outputs(aterm: str) -> str:
    """Blank every output path, in the outputs list AND in env.

    Both places carry the same string, so replacing the string covers both.
    """
    masked = aterm
    for _name, path, _algo, _hash in outputs_of(aterm):
        masked = masked.replace(f'"{path}"', '""')
    return masked


def output_store_name(drv_name: str, output: str) -> str:
    """`out` keeps the plain name; every other output is suffixed."""
    return drv_name if output == "out" else f"{drv_name}-{output}"


# --- the two hashes -------------------------------------------------------


def drv_hash_for_inputs(aterm: str, resolved: dict[str, str]) -> str:
    """hashDerivationModulo with outputs NOT masked.

    This is the value that identifies a derivation when it appears as an INPUT
    of another one. For a derivation with no inputs it is simply the sha256 of
    the .drv text.
    """
    fixed = fixed_output_hash(aterm)
    if fixed is not None:
        return fixed
    return sha256_hex(substitute_inputs(aterm, resolved))


def drv_hash_for_self(aterm: str, resolved: dict[str, str]) -> str:
    """hashDerivationModulo with outputs MASKED.

    This is the value used to compute the derivation's OWN output paths. It has
    to mask them, because they are what is being computed.
    """
    return sha256_hex(substitute_inputs(mask_outputs(aterm), resolved))


def fixed_output_hash(aterm: str) -> str | None:
    """Fixed-output derivations identify themselves by their declared hash.

    Their content is known in advance, so two fixed-output derivations that
    fetch the same bytes are interchangeable no matter how they are written.
    """
    for name, _path, algo, h in outputs_of(aterm):
        if algo:
            return sha256_hex(f"fixed:out:{algo}:{h}:")
    return None


def substitute_inputs(aterm: str, resolved: dict[str, str]) -> str:
    """Replace each inputDrv PATH with that derivation's own hash."""
    out = aterm
    for drv_path, _outs in INPUTDRV_RE.findall(aterm):
        if drv_path in resolved:
            out = out.replace(drv_path, resolved[drv_path])
    return out


def output_paths(aterm: str, drv_name: str, resolved: dict[str, str]) -> dict[str, str]:
    """Compute every output path of a derivation."""
    fixed = fixed_output_hash(aterm)
    if fixed is not None:
        # A fixed-output path depends only on the declared hash, never on how
        # the derivation is written.
        _n, _p, algo, h = next(o for o in outputs_of(aterm) if o[2])
        inner = sha256_hex(f"fixed:out:{algo}:{h}:")
        return {"out": store_path("output:out", inner, drv_name)}
    inner = drv_hash_for_self(aterm, resolved)
    return {
        name: store_path(f"output:{name}", inner, output_store_name(drv_name, name))
        for name, _p, _a, _h in outputs_of(aterm)
    }


def drv_path(aterm: str, drv_name: str) -> str:
    """The path of the .drv file itself: a "text" store object."""
    return store_path("text", sha256_hex(aterm), f"{drv_name}.drv")


# --- self-check against the golden files ----------------------------------


def main() -> int:
    here = pathlib.Path(__file__).resolve().parent.parent
    examples = here / "docs" / "spec" / "examples"
    failures = 0
    checked = 0

    # dep-a is not committed as a golden file; it is RECONSTRUCTED from its
    # definition, which is a stronger test: if the algorithm is right, the
    # reconstruction lands on the path dependent.drv already refers to.
    dep_a_tmpl = (
        'Derive([("out","{p}","","")],[],[],"x86_64-linux","/bin/sh",'
        '["-c","echo a > $out"],[("builder","/bin/sh"),("name","dep-a"),'
        '("out","{p}"),("system","x86_64-linux")])'
    )
    dep_a_inner = sha256_hex(dep_a_tmpl.format(p=""))
    dep_a_out = store_path("output:out", dep_a_inner, "dep-a")
    dep_a_aterm = dep_a_tmpl.format(p=dep_a_out)
    dep_a_drv = drv_path(dep_a_aterm, "dep-a")
    resolved = {dep_a_drv: sha256_hex(dep_a_aterm)}

    for path in sorted(examples.glob("*.drv")):
        name = path.stem
        aterm = path.read_text().rstrip("\n")
        expected = {n: p for n, p, _a, _h in outputs_of(aterm)}
        drv_name = "hello" if name == "minimal" else name
        got = output_paths(aterm, drv_name, resolved)
        for out_name, want in expected.items():
            checked += 1
            if got.get(out_name) != want:
                failures += 1
                print(f"FAIL {name}:{out_name}")
                print(f"  expected {want}")
                print(f"  got      {got.get(out_name)}")
            else:
                print(f"ok   {name}:{out_name}")

    # the reconstruction test
    checked += 1
    dependent = (examples / "dependent.drv").read_text()
    if dep_a_drv in dependent and dep_a_out in dependent:
        print("ok   dep-a reconstructed from scratch (drv path and out path)")
    else:
        failures += 1
        print("FAIL dep-a reconstruction")
        print(f"  computed drv {dep_a_drv}")
        print(f"  computed out {dep_a_out}")

    print(f"\n{checked - failures}/{checked} checks passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
