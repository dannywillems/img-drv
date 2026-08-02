# img-drv (Python)

A portable, content-addressed IR for reproducible build descriptions. Parse a
derivation, transform it, compute its store paths, serialize it back, and get
bytes identical to what Nix emits.

This is the reference implementation. The Go, Rust and OCaml ports are checked
against it, and all four are checked against real Nix.

**Status:** the derivation format, store path computation and the eDSL surface
are implemented and verified. Describing each of the ten golden examples
reproduces the bytes real Nix emitted, including the derivation's own store
path.

## Install

```sh
pip install img-drv
```

Requires Python 3.11 or newer. No runtime dependencies.

## Describe a build

```python
from img_drv import derivation

hello = derivation(
    name="hello",
    system="x86_64-linux",
    builder="/bin/sh",
    args=["-c", "echo hi > $out"],
)

hello.output()  # '/nix/store/mjs27ix6ig2bkbi3s3sm470vrv4lf7ic-hello'
hello.path  # '/nix/store/76w21n1f03fs5kw8fnffphx7qrqffw6r-hello.drv'
hello.aterm()  # the bytes, byte-identical to nix-instantiate's
```

Both paths are Nix's own, and both are known before anything is built. That is
input addressing, and it is why a binary cache can answer "I already have that"
without ever seeing your source.

Depending on something means naming the outputs you need:

```python
dependent = derivation(
    name="dependent",
    system="x86_64-linux",
    builder="/bin/sh",
    args=["-c", f"cat {hello.output()} > $out"],
    input_drvs=[hello],  # or hello.ref("dev", "lib")
)
```

The reference in `args` and the edge in `input_drvs` are written separately.
Nix couples them through string contexts, which belongs to its evaluator; the
signature has no computation in it, so the coupling is yours to make.

A fixed-output derivation declares its result in advance, which is the escape
hatch that lets a build fetch from the network and stay reproducible:

```python
from img_drv import FixedOutput

src = derivation(
    name="source.tar.gz",
    system="x86_64-linux",
    builder="/bin/sh",
    # SRI, Nix base-32, base-64 or hex; the env keeps whichever you wrote
    fixed_output=FixedOutput(
        hash="sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
    ),
)
```

Two fixed-output derivations declaring the same BYTES land on the same output
path however differently the hash was spelled. That is what lets every
`fetchurl` in nixpkgs share one cache entry.

### `outputs` is an option, not a defaulted list

Passing `outputs=None` (the default) emits no `outputs` environment variable,
as a bare `derivation { ... }` does. Passing `outputs=["out"]` emits
`("outputs","out")`, as every nixpkgs package does. They are **different
derivations with different store paths**, and both occur in the wild: of the
single-output derivations in a 2516-derivation sample, 96 do the first and 605
do the second.

## Read a build

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
python -m img_drv canonical ./closure   # canonicalizing must change nothing
```

All exit non-zero on failure, so each works as a CI gate.

## What the API guarantees

The bytes are the artifact: a derivation's own store path is the hash of its
serialization, so a change to what `unparse` emits is a change of identity for
every build that uses it. That makes the byte-level behaviour part of the
public contract and a MAJOR version bump under semver, not an implementation
detail.

These laws hold, and the asymmetry between the first two is the point of a
canonical form:

| law | scope |
| --- | --- |
| `parse(unparse(d)) == d` | every derivation |
| `unparse(parse(t)) == t` | canonical text only |
| `canonical(canonical(d)) == canonical(d)` | every derivation |
| `canonical(d) == d` | every derivation real Nix emits |
| `derivation(...)` is unaffected by `env` insertion order | every intent |
| `derivation(...)` is unaffected by `input_drvs` order | every intent |

All are property-tested with Hypothesis over deliberately hostile input,
including the five escaped characters, control characters that must NOT be
escaped, and the `],[` sequence that defeats pattern matching. The ones about
real derivations are additionally checked against a fresh random sample of
nixpkgs on every CI run: `unparse . parse = id` holds 2516 times out of 2516,
and so does `canonical = id`.

The last two are what make the portability claim meaningful rather than
circular. Four languages will never agree on the iteration order of a mapping,
so if order leaked into the bytes, byte-identical output across four
implementations would be unreachable by construction.

## Layout

| module | contents |
| --- | --- |
| `img_drv.derivation` | the types: `Derivation`, `Output`, `InputDrv`, and the `NewType` aliases |
| `img_drv.aterm` | `parse`, `unparse`, and the escaping rules |
| `img_drv.store` | base-32, XOR-folding, and the store path schemes |
| `img_drv.corpus` | a closure, the memoized recursive hashing, and `verify` |
| `img_drv.edsl` | `derivation`, `Drv`, `FixedOutput`, and the canonical form |
| `img_drv.cli` | the three entry points above |

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
