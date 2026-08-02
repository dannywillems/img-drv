# img-drv (Rust)

A portable, content-addressed IR for reproducible build descriptions. Describe
a build, compute its store paths, serialize it, and get bytes identical to what
Nix emits.

This is the second implementation. It exists so that `make conformance` stops
being vacuous: one implementation cannot disagree with itself.

**Status:** the derivation format, store path computation and the eDSL surface
are implemented and verified. All ten golden examples are reproduced
byte-identically from intent, including each derivation's own `.drv` store
path, and `make conformance` shows Rust and Python emitting the same bytes.

## Install

```toml
[dependencies]
img-drv = "0.1"
```

Rust 1.97.1. One runtime dependency (`sha2`), because hashing is not in the
standard library; the Python reference has none for the same reason it has
none.

## Describe a build

```rust
use img_drv::{Build, derivation};

let hello = derivation(Build {
    name: "hello".into(),
    system: "x86_64-linux".into(),
    builder: "/bin/sh".into(),
    args: vec!["-c".into(), "echo hi > $out".into()],
    ..Default::default()
})?;

hello.output("out")?;  // /nix/store/mjs27ix6ig2bkbi3s3sm470vrv4lf7ic-hello
hello.path();          // /nix/store/76w21n1f03fs5kw8fnffphx7qrqffw6r-hello.drv
hello.aterm();         // the bytes, byte-identical to nix-instantiate's
# Ok::<(), img_drv::InvalidDerivation>(())
```

Both paths are Nix's own, and both are known before anything is built.

Depending on something means naming the outputs you need:

```rust
# use img_drv::{Build, derivation};
# let hello = derivation(Build {
#     name: "hello".into(), system: "x86_64-linux".into(),
#     builder: "/bin/sh".into(), ..Default::default() })?;
let out = hello.output("out")?.clone();
let dependent = derivation(Build {
    name: "dependent".into(),
    system: "x86_64-linux".into(),
    builder: "/bin/sh".into(),
    args: vec!["-c".into(), format!("cat {out} > $out")],
    input_drvs: vec![hello.needs(&[])?],   // or hello.needs(&["dev", "lib"])?
    ..Default::default()
})?;
# Ok::<(), img_drv::InvalidDerivation>(())
```

The reference in `args` and the edge in `input_drvs` are written separately.
Nix couples them through string contexts, which belongs to its evaluator; the
signature has no computation in it, so the coupling is yours to make.

## Differences from the Python reference, and why

Both are the same signature; these are the places the languages forced a
choice. They are recorded because the whole reason for four implementations is
to find out where a first-order signature stops embedding cleanly.

| Python | Rust | why |
| --- | --- | --- |
| keyword arguments | `Build { .. ..Default::default() }` | Rust has no keyword arguments. Arguably the more honest translation: `spec/signature.md` IS a finite product, and this is that product. |
| `Drv.ref(...)` | `Drv::needs(...)` | `ref` is a keyword. |
| `input_drvs=[drv]` accepted | `input_drvs: vec![drv.needs(&[])?]` | Converting a `Drv` to an edge can FAIL, when the target has no output named `out`. `From` cannot fail without panicking, so the shorthand is unavailable and the conversion is explicit. |
| `env: Mapping[str, str]` | `env: BTreeMap<String, String>` | Both make key uniqueness free. `BTreeMap` additionally makes insertion order unobservable, so one Python property test becomes unrepresentable here (see below). |

## The typing table

Which invariants from `spec/signature.md` each type system makes
UNREPRESENTABLE, and which stay runtime checks. This is one of the research
outputs of the project, not bookkeeping.

| invariant | Python | Rust |
| --- | --- | --- |
| store path vs digest vs output name not confused | `NewType`, erased at runtime; `mypy` only | distinct types; does not compile |
| hash algorithm is one of four | `Literal`, erased; **needs a runtime check** | `enum`; does not compile |
| ingestion mode is flat or recursive | `Literal`, erased | `enum`; does not compile |
| env keys are unique | free (`Mapping`) | free (`BTreeMap`) |
| env insertion order is not observable | **property test**, because `dict` preserves insertion order | free: `BTreeMap` has no insertion order |
| `outputs` is an Option, not a defaulted list | `Sequence[str] \| None` | `Option<Vec<OutputName>>` |
| outputs non-empty, names unique, valid | runtime | runtime |
| fixed-output has exactly one output | runtime | runtime |
| a derivation's recorded paths match its own hash | runtime (`Corpus::verify`) | runtime (`Corpus::verify`) |

The pattern worth naming: Rust converts three of Python's runtime checks into
compile-time impossibilities, and one property test into a non-property. What
it does NOT convert is anything requiring a value to be checked against
computed data, which is every remaining row. Those are exactly the invariants
that need a checker rather than a type, in any language.

The parser is where this reverses. `Output::hash_algo` is a `String` and not
the `HashAlgo` enum ON PURPOSE: parsing has to be TOTAL over whatever real Nix
wrote, so the wire type stays permissive and the strictness lives on the
construction side. A type system can only make illegal states unrepresentable
where you are the one constructing them.

## One bug the port found

`base32` shifts a `u8` left by `8 - offset`. When `offset` is 0 that is a shift
by 8, which **panics in debug and is silently masked to a shift of 0 in
release**. The Python original is correct without a guard because its integers
are unbounded. `cargo build --release` was clean; `cargo test` caught it
immediately. A release-only wrong answer in a hash function is the worst
possible failure mode, and it is the sort of thing porting finds and
single-implementation testing does not.

## What the API guarantees

The bytes are the artifact: a derivation's own store path is the hash of its
serialization, so a change to what `unparse` emits changes the identity of
every build that uses it. That makes byte-level behaviour part of the public
contract and a MAJOR version bump under semver.

The laws in `tests/laws.rs` are the same laws as
`impl/python/tests/test_edsl_laws.py`, deliberately: a law is a property of the
SPECIFICATION, so it ports rather than being rewritten.

## Develop

```sh
make -C ../.. rust-test        # cargo test, in a container
make -C ../.. rust-lint        # rustfmt + clippy -D warnings
make -C ../.. conformance      # Rust vs Python vs real Nix
```

Docker is the only prerequisite; the toolchain is a pinned image
(`scripts/pins.env`), so a laptop and a CI runner run the same bytes.

Note that formatting uses the pinned STABLE `cargo fmt`, not nightly. This
project pins one toolchain per language by digest and runs everything in it;
adding a second toolchain purely for the formatter would defeat that.

## Licence

MPL-2.0. Embedding it in a larger work, under any licence, is fine and is the
point; changes to these files themselves stay open. See
[`docs/decisions/`](../../docs/decisions/) for the reasoning.
