"""A real parser and serializer for the ATerm derivation format.

Regexes are not sufficient, and this is not a stylistic claim. A regex-based
reader passed 12 of 12 hand-written examples and then failed 323 of 403 real
derivations, because real ones contain escaped quotes inside values, store
paths embedded in unrelated environment variables, and ``],[`` sequences
inside strings. The recursive-descent parser below round-trips 805 of 805 real
derivations byte-identically.

Parse, transform, serialize. Nothing here inspects text.

The pair (:func:`parse`, :func:`unparse`) is a section-retraction, not an
isomorphism: ``parse(unparse(d)) == d`` for every derivation, while
``unparse(parse(t)) == t`` holds only for CANONICAL text. That asymmetry is
the point of a canonical form, and both directions are tested.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import TypeVar

from .derivation import (
    Derivation,
    InputDrv,
    Output,
    OutputName,
    StorePath,
)

__all__ = ["ParseError", "escape", "parse", "quote", "unparse"]

T = TypeVar("T")

# The five escapes, and only these five. Every other byte, including other
# control characters, is emitted raw. An implementation that escapes control
# characters generally, as JSON does, produces different bytes and therefore a
# different derivation. See docs/spec/canonical.md section 2.
_ESCAPES = {'"': '\\"', "\\": "\\\\", "\n": "\\n", "\r": "\\r", "\t": "\\t"}
_UNESCAPES = {'"': '"', "\\": "\\", "n": "\n", "r": "\r", "t": "\t"}


class ParseError(ValueError):
    """Raised when the input is not a well-formed ``Derive(...)`` term."""


class _Parser:
    """Recursive descent over the ATerm grammar.

    Deliberately small: the grammar is seven positional fields of lists,
    tuples and strings. Anything larger, such as the Nix language itself,
    gets a parser generator instead.
    """

    __slots__ = ("i", "s")

    def __init__(self, text: str) -> None:
        self.s = text
        self.i = 0

    def error(self, what: str) -> ParseError:
        near = self.s[max(0, self.i - 30) : self.i + 30]
        return ParseError(f"expected {what} at offset {self.i}, near: {near!r}")

    def peek(self) -> str:
        if self.i >= len(self.s):
            raise self.error("more input")
        return self.s[self.i]

    def expect(self, ch: str) -> None:
        if self.i >= len(self.s) or self.s[self.i] != ch:
            raise self.error(repr(ch))
        self.i += 1

    def literal(self, text: str) -> None:
        for ch in text:
            self.expect(ch)

    def string(self) -> str:
        self.expect('"')
        out: list[str] = []
        while True:
            if self.i >= len(self.s):
                raise self.error("closing quote")
            c = self.s[self.i]
            if c == '"':
                self.i += 1
                return "".join(out)
            if c == "\\":
                self.i += 1
                if self.i >= len(self.s):
                    raise self.error("escape character")
                e = self.s[self.i]
                # Anything outside the table passes through as itself, which
                # matches Nix: only the five sequences above are ever emitted.
                out.append(_UNESCAPES.get(e, e))
                self.i += 1
                continue
            out.append(c)
            self.i += 1

    def list_of(self, item: Callable[[], T]) -> tuple[T, ...]:
        self.expect("[")
        out: list[T] = []
        if self.peek() == "]":
            self.i += 1
            return ()
        while True:
            out.append(item())
            if self.peek() == ",":
                self.i += 1
                continue
            self.expect("]")
            return tuple(out)

    def output(self) -> Output:
        self.expect("(")
        name = OutputName(self.string())
        self.expect(",")
        path = StorePath(self.string())
        self.expect(",")
        algo = self.string()
        self.expect(",")
        digest = self.string()
        self.expect(")")
        return Output(name=name, path=path, hash_algo=algo, hash=digest)

    def input_drv(self) -> InputDrv:
        self.expect("(")
        path = StorePath(self.string())
        self.expect(",")
        outputs = self.list_of(lambda: OutputName(self.string()))
        self.expect(")")
        return InputDrv(path=path, outputs=outputs)

    def env_entry(self) -> tuple[str, str]:
        self.expect("(")
        key = self.string()
        self.expect(",")
        value = self.string()
        self.expect(")")
        return (key, value)


def parse(text: str) -> Derivation:
    """Parse ATerm text into a :class:`Derivation`.

    Raises :class:`ParseError` with an offset and surrounding context when the
    input is malformed.
    """
    p = _Parser(text.strip())
    p.literal("Derive(")
    outputs = p.list_of(p.output)
    p.expect(",")
    input_drvs = p.list_of(p.input_drv)
    p.expect(",")
    input_srcs = p.list_of(lambda: StorePath(p.string()))
    p.expect(",")
    system = p.string()
    p.expect(",")
    builder = p.string()
    p.expect(",")
    args = p.list_of(p.string)
    p.expect(",")
    env = p.list_of(p.env_entry)
    p.expect(")")
    return Derivation(
        outputs=outputs,
        input_drvs=input_drvs,
        input_srcs=input_srcs,
        system=system,
        builder=builder,
        args=args,
        env=env,
    )


def escape(s: str) -> str:
    """Apply exactly the five ATerm escapes, and nothing else."""
    return "".join(_ESCAPES.get(c, c) for c in s)


def quote(s: str) -> str:
    """Escape and wrap in double quotes."""
    return f'"{escape(s)}"'


def unparse(
    drv: Derivation,
    *,
    mask_outputs: bool = False,
    input_hashes: dict[StorePath, str] | None = None,
) -> str:
    """Serialize a derivation back to ATerm.

    With both keyword arguments at their defaults this is the plain canonical
    form, and is the inverse of :func:`parse` on canonical input.

    The two arguments select the variants needed for hashing, and getting
    either backwards yields a syntactically perfect derivation with wrong
    paths:

    ``mask_outputs``
        Blank this derivation's own output paths, in the outputs list AND in
        the env entries whose KEY is an output name. Required when computing
        those paths, since they are what is being computed. It must NOT blank
        an output path that merely appears inside some other value, which is
        precisely where a textual substitution goes wrong.

    ``input_hashes``
        Replace each input's store path with that input's own hash, and
        RE-SORT by it. The serialized ``.drv`` sorts inputs by PATH; the form
        that gets hashed sorts them by HASH. One derivation, two orderings.
    """
    outs = ",".join(
        "("
        + ",".join(
            (
                quote(o.name),
                quote("" if mask_outputs else o.path),
                quote(o.hash_algo),
                quote(o.hash),
            )
        )
        + ")"
        for o in drv.outputs
    )

    if input_hashes is None:
        entries = [(str(i.path), i.outputs) for i in drv.input_drvs]
    else:
        entries = sorted(
            (str(input_hashes.get(i.path, i.path)), i.outputs)
            for i in drv.input_drvs
        )
    ins = ",".join(
        f"({quote(key)},[" + ",".join(quote(o) for o in names) + "])"
        for key, names in entries
    )

    srcs = ",".join(quote(s) for s in drv.input_srcs)
    args = ",".join(quote(a) for a in drv.args)
    names = drv.output_names
    env = ",".join(
        f"({quote(k)},{quote('' if (mask_outputs and k in names) else v)})"
        for k, v in drv.env
    )

    return (
        f"Derive([{outs}],[{ins}],[{srcs}],"
        f"{quote(drv.system)},{quote(drv.builder)},[{args}],[{env}])"
    )
