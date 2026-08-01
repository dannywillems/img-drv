"""Serialization laws, and the escaping rules that are easiest to get wrong.

The property tests encode the specification rather than examples of it. Every
one of them is a law that any conforming implementation in any language must
satisfy, which is what makes them portable to the Go, Rust and OCaml ports.
"""

from __future__ import annotations

import pytest
from hypothesis import given
from hypothesis import strategies as st

from img_drv import (
    Derivation,
    InputDrv,
    Output,
    OutputName,
    ParseError,
    StorePath,
    escape,
    parse,
    quote,
    unparse,
)

# Deliberately nasty text: the escaped characters, control characters that must
# NOT be escaped, quotes, backslashes, and the `],[` sequence that defeats
# pattern matching.
text = st.text(
    st.characters(
        codec="utf-8",
        include_characters='"\\\n\r\t\x07],[/',
    ),
    max_size=40,
)
names = st.text(
    st.characters(min_codepoint=97, max_codepoint=122), min_size=1, max_size=8
)


@st.composite
def derivations(draw: st.DrawFn) -> Derivation:
    outs = draw(
        st.lists(
            st.builds(
                Output,
                name=names.map(OutputName),
                path=text.map(StorePath),
                hash_algo=st.sampled_from(["", "sha256", "r:sha256"]),
                hash=text,
            ),
            max_size=3,
            unique_by=lambda o: o.name,
        )
    )
    ins = draw(
        st.lists(
            st.builds(
                InputDrv,
                path=text.map(StorePath),
                outputs=st.lists(names.map(OutputName), max_size=2).map(tuple),
            ),
            max_size=3,
        )
    )
    return Derivation(
        outputs=tuple(outs),
        input_drvs=tuple(ins),
        input_srcs=tuple(draw(st.lists(text.map(StorePath), max_size=3))),
        system=draw(text),
        builder=draw(text),
        args=tuple(draw(st.lists(text, max_size=3))),
        env=tuple(draw(st.lists(st.tuples(text, text), max_size=4))),
    )


@given(derivations())
def test_parse_after_unparse_is_identity(drv: Derivation) -> None:
    """parse . unparse = id.

    The direction that always holds. The other direction, unparse . parse =
    id, holds only on CANONICAL text, and is tested against real derivations
    in test_golden.py. That asymmetry is exactly what a canonical form means.
    """
    assert parse(unparse(drv)) == drv


@given(text)
def test_escaping_round_trips(s: str) -> None:
    assert parse(f'Derive([],[],[],{quote(s)},"",[],[])').system == s


def test_exactly_five_escapes_and_no_others() -> None:
    """Every other byte is emitted raw, including other control characters.

    An implementation that escapes control characters generally, as JSON does
    with \\uXXXX, produces different bytes and therefore a different
    derivation. Verified against real Nix by embedding BEL in a value.
    """
    assert escape('"') == '\\"'
    assert escape("\\") == "\\\\"
    assert escape("\n") == "\\n"
    assert escape("\r") == "\\r"
    assert escape("\t") == "\\t"
    assert escape("\x07") == "\x07"
    assert escape("\x00\x1b") == "\x00\x1b"


def test_masking_blanks_output_paths_by_key_not_by_value() -> None:
    """The distinction a textual substitution cannot make.

    An env entry is blanked when its KEY is an output name. An output path
    that merely appears INSIDE another value is left alone. Getting this wrong
    is how a regex-based implementation passes every hand-written example and
    fails real ones.
    """
    drv = Derivation(
        outputs=(Output(OutputName("out"), StorePath("/nix/store/aaa-x")),),
        env=(
            ("out", "/nix/store/aaa-x"),
            ("buildInputs", "/nix/store/aaa-x /nix/store/bbb-y"),
        ),
    )
    masked = unparse(drv, mask_outputs=True)
    assert '("out","")' in masked
    assert '("buildInputs","/nix/store/aaa-x /nix/store/bbb-y")' in masked


def test_input_hashes_resort_by_hash_not_by_path() -> None:
    """One derivation carries two orderings of its inputs.

    The serialized .drv sorts inputs by store PATH; the form that gets hashed
    sorts them by HASH. A substitution that preserves path order silently
    breaks every derivation with more than one input, which is why
    single-input examples hid this for so long.
    """
    drv = Derivation(
        input_drvs=(
            InputDrv(StorePath("/nix/store/aaa.drv"), (OutputName("out"),)),
            InputDrv(StorePath("/nix/store/bbb.drv"), (OutputName("out"),)),
        )
    )
    # aaa hashes to zzz and bbb to mmm, so hash order reverses path order.
    out = unparse(
        drv,
        input_hashes={
            StorePath("/nix/store/aaa.drv"): "zzz",
            StorePath("/nix/store/bbb.drv"): "mmm",
        },
    )
    assert out.index('"mmm"') < out.index('"zzz"')


@pytest.mark.parametrize(
    "bad",
    [
        "",
        'NotADerive([],[],[],"","",[],[])',
        'Derive([],[],[],"","",[],[]',
        'Derive([("out","x","","")],[],[],"unterminated',
    ],
)
def test_malformed_input_raises_parse_error(bad: str) -> None:
    with pytest.raises(ParseError):
        parse(bad)
