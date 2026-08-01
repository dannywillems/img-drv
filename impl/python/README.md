# img-drv (Python)

A portable, content-addressed IR for reproducible build descriptions. Parse a
derivation, transform it, compute its store paths, serialize it back, and get
bytes identical to what Nix emits.

This is the reference implementation. The Go, Rust and OCaml ports are checked
against it, and all four are checked against real Nix.

**Status:** the derivation format and store path computation are implemented
and verified. The eDSL surface described in the [project
plan](../../PLAN.md) is not built yet.

## Install

```sh
pip install img-drv
```

Requires Python 3.11 or newer. No runtime dependencies.

## Use

```python
import pathlib
from img_drv import Corpus, parse, unparse

drv = parse(pathlib.Path("hello.drv").read_text())

drv.name  # 'hello'
drv.outputs[0].path  # '/nix/store/...-hello'
drv.output_names  # frozenset({'out'})

unparse(drv)  # byte-identical to the input, for canonical text
```

Recomputing every store path in a closure, which is how you find out an
implementation is wrong:

```python
corpus = Corpus.from_directory(pathlib.Path("./closure"))
checked, mismatches = corpus.verify()
print(f"{checked - len(mismatches)}/{checked}")
for m in mismatches:
    print(m)
```

From the command line:

```sh
python -m img_drv verify ./closure      # recompute every store path
python -m img_drv roundtrip ./closure   # parse, re-serialize, compare bytes
```

Both exit non-zero on failure, so either works as a CI gate.

## What the API guarantees

The bytes are the artifact: a derivation's own store path is the hash of its
serialization, so a change to what `unparse` emits is a change of identity for
every build that uses it. That makes the byte-level behaviour part of the
public contract and a MAJOR version bump under semver, not an implementation
detail.

Two laws hold, and the asymmetry between them is the point of a canonical
form:

| law | scope |
| --- | --- |
| `parse(unparse(d)) == d` | every derivation |
| `unparse(parse(t)) == t` | canonical text only |

The first is property-tested with Hypothesis over deliberately hostile input.
The second is tested against real derivations, where it holds 805 times out of
805.

## Layout

| module | contents |
| --- | --- |
| `img_drv.derivation` | the types: `Derivation`, `Output`, `InputDrv`, and the `NewType` aliases |
| `img_drv.aterm` | `parse`, `unparse`, and the escaping rules |
| `img_drv.store` | base-32, XOR-folding, and the store path schemes |
| `img_drv.corpus` | a closure, the memoized recursive hashing, and `verify` |
| `img_drv.cli` | the two entry points above |

`Derivation` and friends are frozen and slotted, so a derivation is a value:
comparable, hashable, and usable as a memo key.

## Types

`mypy --strict` clean, with no `Any` in the public surface and a `py.typed`
marker, so your own strict build sees the types.

`StorePath`, `Sha256Hex` and `OutputName` are `NewType` aliases. They cost
nothing at runtime and are not decoration: a derivation's own path and the
hash by which it is known as an input are both 64-character strings, and
swapping them produces a plausible wrong answer rather than an error. That
exact confusion cost 145 wrong paths once already.

## Develop

```sh
make -C ../.. python-test     # pytest, in a container
make -C ../.. python-lint     # ruff + mypy, in a container
```

Nothing needs to be installed on your machine, and CI runs the same targets.

## Licence

MPL-2.0. Embedding it in a larger work, under any licence, is fine and is the
point; changes to these files themselves stay open. See
[`docs/decisions/`](../../docs/decisions/) for the reasoning.
