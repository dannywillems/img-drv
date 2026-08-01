#!/usr/bin/env python3
"""A real ATerm parser and serializer for Nix store derivations.

Regexes are not sufficient. Real derivations contain escaped quotes inside
values, store paths embedded in unrelated environment variables, and `],[`
sequences inside strings, all of which defeat pattern matching. Getting 80 of
403 real output paths right with regexes, against 12 of 12 on hand-written
examples, is what motivated this file.

Parse, transform, serialize. Nothing here inspects text.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass, field, replace

# The five escapes, and only these five. See docs/spec/canonical.md.
_ESCAPES = {'"': '\\"', "\\": "\\\\", "\n": "\\n", "\r": "\\r", "\t": "\\t"}
_UNESCAPES = {'"': '"', "\\": "\\", "n": "\n", "r": "\r", "t": "\t"}


@dataclass(frozen=True)
class Output:
    name: str
    path: str
    hash_algo: str = ""
    hash: str = ""

    @property
    def fixed(self) -> bool:
        return bool(self.hash_algo)


@dataclass(frozen=True)
class Derivation:
    outputs: tuple[Output, ...] = ()
    input_drvs: tuple[tuple[str, tuple[str, ...]], ...] = ()
    input_srcs: tuple[str, ...] = ()
    system: str = ""
    builder: str = ""
    args: tuple[str, ...] = ()
    env: tuple[tuple[str, str], ...] = ()

    @property
    def output_names(self) -> frozenset[str]:
        return frozenset(o.name for o in self.outputs)


class Parser:
    def __init__(self, text: str) -> None:
        self.s = text
        self.i = 0

    def error(self, what: str) -> None:
        near = self.s[max(0, self.i - 30) : self.i + 30]
        raise ValueError(f"expected {what} at offset {self.i}, near: {near!r}")

    def expect(self, ch: str) -> None:
        if self.i >= len(self.s) or self.s[self.i] != ch:
            self.error(repr(ch))
        self.i += 1

    def string(self) -> str:
        self.expect('"')
        out: list[str] = []
        while True:
            if self.i >= len(self.s):
                self.error("closing quote")
            c = self.s[self.i]
            if c == '"':
                self.i += 1
                return "".join(out)
            if c == "\\":
                self.i += 1
                e = self.s[self.i]
                # Anything not in the table is passed through as itself, which
                # matches Nix: only five sequences are ever produced.
                out.append(_UNESCAPES.get(e, e))
                self.i += 1
                continue
            out.append(c)
            self.i += 1

    def list_of(self, item):  # type: ignore[no-untyped-def]
        self.expect("[")
        out = []
        if self.s[self.i] == "]":
            self.i += 1
            return out
        while True:
            out.append(item())
            if self.s[self.i] == ",":
                self.i += 1
                continue
            self.expect("]")
            return out

    def tuple_of(self, *items):  # type: ignore[no-untyped-def]
        self.expect("(")
        out = []
        for n, item in enumerate(items):
            if n:
                self.expect(",")
            out.append(item())
        self.expect(")")
        return out


def parse(text: str) -> Derivation:
    p = Parser(text.strip())
    for ch in "Derive(":
        p.expect(ch)

    outputs = p.list_of(
        lambda: Output(*p.tuple_of(p.string, p.string, p.string, p.string))
    )
    p.expect(",")
    input_drvs = p.list_of(
        lambda: tuple(p.tuple_of(p.string, lambda: tuple(p.list_of(p.string))))
    )
    p.expect(",")
    input_srcs = p.list_of(p.string)
    p.expect(",")
    system = p.string()
    p.expect(",")
    builder = p.string()
    p.expect(",")
    args = p.list_of(p.string)
    p.expect(",")
    env = p.list_of(lambda: tuple(p.tuple_of(p.string, p.string)))
    p.expect(")")

    return Derivation(
        outputs=tuple(outputs),
        input_drvs=tuple((a, b) for a, b in input_drvs),
        input_srcs=tuple(input_srcs),
        system=system,
        builder=builder,
        args=tuple(args),
        env=tuple((k, v) for k, v in env),
    )


def escape(s: str) -> str:
    return "".join(_ESCAPES.get(c, c) for c in s)


def quote(s: str) -> str:
    return f'"{escape(s)}"'


def unparse(
    drv: Derivation,
    *,
    mask_outputs: bool = False,
    input_hashes: dict[str, str] | None = None,
) -> str:
    """Serialize back to ATerm.

    mask_outputs blanks the output paths, in the outputs list AND in the env
    entries whose KEY is an output name. It must NOT blank an output path that
    merely appears inside some other value, which is precisely where the
    regex version went wrong.

    input_hashes replaces each inputDrv path with that derivation's own hash
    and RE-SORTS by it, because the hashed form is keyed by hash rather than
    by path.
    """
    outs = ",".join(
        "("
        + ",".join(
            [
                quote(o.name),
                quote("" if mask_outputs else o.path),
                quote(o.hash_algo),
                quote(o.hash),
            ]
        )
        + ")"
        for o in drv.outputs
    )

    if input_hashes is None:
        entries = list(drv.input_drvs)
    else:
        entries = sorted(
            ((input_hashes.get(p, p), outs_) for p, outs_ in drv.input_drvs),
            key=lambda e: e[0],
        )
    ins = ",".join(
        f"({quote(p)},[" + ",".join(quote(o) for o in outs_) + "])"
        for p, outs_ in entries
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


def main() -> int:
    """Round-trip check: parse then unparse must reproduce the input exactly."""
    import pathlib

    if len(sys.argv) < 2:
        print("usage: aterm.py <dir-of-drv-files>", file=sys.stderr)
        return 2
    ok = bad = 0
    for f in sorted(pathlib.Path(sys.argv[1]).glob("*.drv")):
        text = f.read_text().rstrip("\n")
        try:
            if unparse(parse(text)) == text:
                ok += 1
            else:
                bad += 1
                print(f"ROUND-TRIP DIFFERS: {f.name}")
        except Exception as exc:  # noqa: BLE001
            bad += 1
            print(f"PARSE ERROR {f.name}: {exc}")
    print(f"{ok}/{ok + bad} round-tripped byte-identically")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
