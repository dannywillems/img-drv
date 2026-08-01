"""Store path computation: the pieces, and the traps in each of them.

Each test below pins down a rule that a plausible wrong implementation would
violate silently. None of them assert against a value taken from memory: the
expected paths come from real Nix output, recorded in docs/spec/examples/.
"""

from __future__ import annotations

import base64
import hashlib

from img_drv import (
    BASE32_ALPHABET,
    STORE,
    Output,
    OutputName,
    Sha256Hex,
    StorePath,
    base32,
    compress,
    fixed_output_input_hash,
    fixed_output_path,
    output_store_name,
    store_path,
)


def test_alphabet_omits_the_letters_that_spell_words() -> None:
    """e, o, u and t are absent, so no store path spells anything."""
    assert len(BASE32_ALPHABET) == 32
    assert len(set(BASE32_ALPHABET)) == 32
    assert not set("eout") & set(BASE32_ALPHABET)


def test_base32_is_not_rfc_4648() -> None:
    """Digits come from the END of the buffer backwards, five bits at a time.

    A stock base-32 library gives a different string. This is the first thing
    to check when a path is close but wrong.
    """
    data = bytes(range(20))
    ours = base32(data)
    theirs = base64.b32encode(data).decode().lower().rstrip("=")
    assert ours != theirs
    assert len(ours) == 32
    assert not set(ours) - set(BASE32_ALPHABET)


def test_compress_folds_rather_than_truncates() -> None:
    """Byte i of the digest is XORed into byte i mod 20.

    Truncating gives a plausible-looking path that is wrong, and the two agree
    on the first 20 bytes only when the tail happens to be zero.
    """
    digest = hashlib.sha256(b"anything").digest()
    folded = compress(digest)
    assert len(folded) == 20
    assert folded != digest[:20]
    expected = bytearray(20)
    for i, b in enumerate(digest):
        expected[i % 20] ^= b
    assert folded == bytes(expected)
    # Folding is an involution on the tail: XORing a byte in twice cancels.
    assert compress(b"\x00" * 20 + b"\xff" * 20) == compress(b"\xff" * 20)


def test_store_path_shape() -> None:
    path = store_path("text", Sha256Hex("00" * 32), "hello.drv")
    assert path.startswith(f"{STORE}/")
    base = path.removeprefix(f"{STORE}/")
    digest, _, name = base.partition("-")
    assert len(digest) == 32
    assert name == "hello.drv"


def test_kind_and_name_both_enter_the_fingerprint() -> None:
    """Nothing about a path is incidental: change either and it moves."""
    inner = Sha256Hex("11" * 32)
    assert store_path("text", inner, "x") != store_path("source", inner, "x")
    assert store_path("text", inner, "x") != store_path("text", inner, "y")


def test_out_keeps_the_plain_name_others_are_suffixed() -> None:
    assert output_store_name("multi", OutputName("out")) == "multi"
    assert output_store_name("multi", OutputName("dev")) == "multi-dev"


def test_fixed_output_has_two_different_hash_strings() -> None:
    """The trap that cost 145 failures in the first real corpus.

    The string computing a fixed-output derivation's own path ends at a colon;
    the one identifying it as someone's INPUT appends the output path. Using
    the first in both places leaves every fetch's own path correct and every
    path DOWNSTREAM of a fetch wrong, which is invisible until something
    depends on a fetch.
    """
    o = Output(
        name=OutputName("out"),
        path=StorePath("/nix/store/aaa-src"),
        hash_algo="sha256",
        hash="ab" * 32,
    )
    own = hashlib.sha256(f"fixed:out:sha256:{o.hash}:".encode()).hexdigest()
    as_input = fixed_output_input_hash(o)
    assert as_input != own
    assert (
        as_input
        == hashlib.sha256(
            f"fixed:out:sha256:{o.hash}:{o.path}".encode()
        ).hexdigest()
    )


def test_recursive_sha256_uses_the_source_scheme() -> None:
    """r:sha256 takes the `source` kind with the declared hash DIRECTLY.

    No fixed:out: fingerprint at all. Exactly one derivation in a
    226-derivation closure exercised this, so a hand-written corpus would
    never contain it.
    """
    digest = "cd" * 32
    o = Output(
        name=OutputName("out"),
        path=StorePath("/nix/store/x-src"),
        hash_algo="r:sha256",
        hash=digest,
    )
    assert fixed_output_path(o, "src") == store_path(
        "source", Sha256Hex(digest), "src"
    )
    flat = Output(
        name=OutputName("out"),
        path=StorePath("/nix/store/x-src"),
        hash_algo="sha256",
        hash=digest,
    )
    assert fixed_output_path(flat, "src") != fixed_output_path(o, "src")


def test_identical_content_gives_identical_paths() -> None:
    """Two fetches of the same bytes are interchangeable, however expressed.

    This is a feature rather than an accident: it is what lets every fetchurl
    in nixpkgs share one cache entry.
    """
    digest = "ef" * 32
    a = Output(OutputName("out"), StorePath("/nix/store/a"), "sha256", digest)
    b = Output(OutputName("out"), StorePath("/nix/store/b"), "sha256", digest)
    assert fixed_output_path(a, "same") == fixed_output_path(b, "same")
