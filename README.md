# img-drv

A portable, content-addressed **intermediate representation for reproducible
build descriptions**, with thin embedded DSLs in **Go, OCaml, Rust and Python**.

All four exist, they emit the same bytes, and each can now also **write and
read the Nix language itself**. See [Status](#status).

## The thesis

> A build description is first-order data. Therefore the language you write it
> in does not matter, only the term it denotes does, and that term can be
> emitted identically from any typed language.

If that is true, then "reproducible builds" need no new language: they need one
small **signature**, one **canonical serialization**, and a **builder** that
already exists. The DSL becomes a library, in whatever language you already
use.

If it is false, this repository should say so, quickly and in public.

## Why this might not be reinventing the wheel

Nix is really three separable systems, and only one of them is being
questioned here:

| Layer             | What it does                                 | Our position                                             |
| ----------------- | -------------------------------------------- | -------------------------------------------------------- |
| Evaluator         | Nix language to derivations                  | **Replaceable.** This is the part we replace with eDSLs. |
| Store and builder | Content-addressed store, sandbox, caches, GC | **Reuse.** Twenty years of work. Do not rewrite.         |
| Module system     | Typed options, merging, activation           | Interesting on its own, later.                           |

The evaluator is the layer people actually complain about (a hard functional
language, documentation that never joins the language to the OS, flakes
experimental since 2021). Almost nobody criticises the model. So: keep the
model, replace the surface, reuse the engine.

## The move that makes it tractable

**Emit real `.drv` files.** Nix store derivations have a documented on-disk
format (ATerm), so a front-end that emits them inherits, on day one:

- the sandboxed builder,
- the content-addressed store,
- garbage collection,
- `cache.nixos.org` and every other substituter,
- remote and distributed builds.

And it hands us a **differential oracle**: write the same package in an eDSL
and in Nix, emit both derivations, and compare byte for byte against
`nix-instantiate`. If they agree, the IR is provably right. That test is the
project.

## Why four languages, and why these four

Portability is the claim under test, so the eDSLs are the experiment, not the
product. One engine, four front-ends, chosen to span the axis from "no static
types" to "very strong static types".

- **OCaml** carries the reference implementation and the normalizer. Sum types
  and exhaustiveness checking are what make a canonical serialization spec
  pleasant to get exactly right.
- **Rust** carries the tooling, and is the path to embedding a builder
  (Snix) later if we ever want one of our own.
- **Go** is the **falsification test**, and the most important of the four.
  It has no sum types, no higher-kinded types, and minimal generics. If the
  signature needs anything beyond finite products, Go is where it breaks.
  A clean Go embedding is the empirical evidence for the theory in
  [`docs/theory.md`](docs/theory.md); an ugly one is the refutation.
- **Python** is the readable one, and it probes gradual typing pushed to its
  limit: fully annotated and `mypy --strict` clean, so it tests whether the
  signature survives when types are BOLTED ON rather than intrinsic. It is also
  the fastest to iterate on while the spec is still moving, and the best
  language to read the spec back out of, which is why it goes first in Phase 1.

Every implementation is as strongly typed as its language permits, enforced in
CI. That is not a style preference: four implementations only span the typing
axis if each one is honest about what its type system can actually enforce, and
the table of "which invariants are unrepresentable here" is one of the real
outputs of the project. Each targets the LATEST STABLE release of its language,
pinned. See [`PLAN.md`](PLAN.md#engineering-baseline-runs-alongside-every-phase).

## Layout

```
PLAN.md                 the living plan, and where tasks come from
docs/theory.md          why finite products suffice, and what that forces
docs/architecture.md    the two term algebras, and the layout they imply
docs/abstractions.md    which structure each piece of code realizes, its
                        laws, and where each law is tested
docs/nix-internals.md   how Nix actually works, with sources
docs/learning-nix.md    a path to learning Nix properly, in order
docs/spec/              the IR signature and canonical serialization,
                        with golden .drv files from real Nix, plus the
                        parser's differential vectors
impl/python/            the reference implementation, as a library
impl/rust/              the second implementation, as a crate
impl/go/                the falsification test, as a module
impl/ocaml/             the typed reference, as an opam package
```

## Status

**All four implementations exist, and they agree.** Every gate below runs in
CI, and none of them is a test we wrote about ourselves: each compares against
real Nix.

| gate                   | what it asserts                                       | current                       |
| ---------------------- | ----------------------------------------------------- | ----------------------------- |
| `make conformance`     | four eDSLs emit the same `.drv` bytes as Nix          | **11 intents x 4**            |
| `make corpus`          | real nixpkgs closures round-trip and re-hash          | **2063 of 2063** output paths |
| `make drvpath-check`   | each `.drv`'s own store path, from its bytes          | **1458 of 1458**              |
| `make transpile-check` | our `.nix`, through real Nix, gives the golden `.drv` | **44 of 44**                  |
| `make nixpkgs-parse`   | our parse tree equals `nix-instantiate --parse`       | **all four languages**        |
| `make differential`    | a live closure's paths, against pinned Nix            | **7 of 7**                    |

Both arrows between the Nix language and its syntax tree now exist, in all four
languages. The arrow from that tree to the IR does NOT: there is no
`derivation` primop yet, so a real package can be read and written but not yet
turned into a derivation.

```
   .nix text  --parse-->  EXPR  - - eval - >  DRV  --hash-->  store path
              <--emit---              ^
                                      |
                                 not built yet
```

Four results worth stating on their own.

**The falsification test came back negative.** Go was the one most likely to
refute the thesis, and the signature needed nothing beyond finite products
there. What Go costs is ENFORCEMENT and UNIFORMITY, not expressiveness:
[`impl/go/README.md`](impl/go/README.md).

**The typing axis has a floor.** Across all four languages, "the recorded paths
match this derivation's own hash" is a runtime check, and always will be. A
type system distinguishes what you CONSTRUCT; a verifier is still required for
what you COMPUTE. OCaml moves exactly one row the others cannot
([`impl/ocaml/README.md`](impl/ocaml/README.md)), and the last two rows move
nowhere.

**Agreement between implementations is not evidence of correctness.** A store
path rule was wrong in all four at once, byte-identically, and every gate that
compared them against each other stayed green. It was found by the first check
that let NIX name the artifact instead of validating one we had named. The
language count measures PORTABILITY; only an external oracle measures
CORRECTNESS. `docs/abstractions.md` entry 10.

**A curated test set measures what you thought to ask.** The Nix parser passed
59 hand-written differential vectors and then scored **0 of 40** on real
nixpkgs files. Eight rules of Nix were wrong or missing, none of them exotic.
Writing those eight down as a specification is what made the other three ports
pass first time. Entries 13 and 14.

Next is the EVALUATOR: parsing is done, but without a `derivation` primop no
parsed package can become IR. See [`PLAN.md`](PLAN.md).

## Licence

**MPL-2.0** for the code, **CC0-1.0** for `docs/spec/`.

MPL-2.0 is file-level copyleft: embedding these libraries in a larger work,
under any licence, is explicitly permitted, while changes to img-drv's own
files stay open. That fits a library whose whole purpose is to be embedded,
and it avoids the static-linking question LGPL creates for Go, Rust and OCaml.
The specification is CC0 because independent implementations of it are the
point of the project.

Reasoning, costs accepted, and the conditions to revisit:
[`docs/decisions/2026-08-01-licence-mpl-2.0.md`](docs/decisions/2026-08-01-licence-mpl-2.0.md).
