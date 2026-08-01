# img-drv

A portable, content-addressed **intermediate representation for reproducible
build descriptions**, with thin embedded DSLs in **Go, OCaml and Rust**.

Nothing is built yet. This repository currently holds a thesis, a plan to
falsify it cheaply, and the mathematics that constrains the design.

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

| Layer | What it does | Our position |
| --- | --- | --- |
| Evaluator | Nix language to derivations | **Replaceable.** This is the part we replace with eDSLs. |
| Store and builder | Content-addressed store, sandbox, caches, GC | **Reuse.** Twenty years of work. Do not rewrite. |
| Module system | Typed options, merging, activation | Interesting on its own, later. |

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

## Why three languages, and why these three

Portability is the claim under test, so the eDSLs are the experiment, not the
product. One engine, three front-ends.

- **OCaml** carries the reference implementation and the normalizer. Sum types
  and exhaustiveness checking are what make a canonical serialization spec
  pleasant to get exactly right.
- **Rust** carries the tooling, and is the path to embedding a builder
  (Snix) later if we ever want one of our own.
- **Go** is the **falsification test**, and the most important of the three.
  It has no sum types, no higher-kinded types, and minimal generics. If the
  signature needs anything beyond finite products, Go is where it breaks.
  A clean Go embedding is the empirical evidence for the theory in
  [`docs/theory.md`](docs/theory.md); an ugly one is the refutation.

## Layout

```
docs/theory.md          why finite products suffice, and what that forces
docs/nix-internals.md   how Nix actually works, with sources
docs/learning-nix.md    a path to learning Nix properly, in order
docs/plan.md            phases, with a falsifiable MVP
docs/spec/              the IR signature and canonical serialization
```

## Status

Planning. See [`docs/plan.md`](docs/plan.md). Phase 0 to 2 are weeks of work and
either validate the thesis or kill it; nothing beyond that is committed to.

## Licence

GPL-3.0. See the note in [`docs/plan.md`](docs/plan.md#open-questions): a
copyleft licence on a library intended for embedding in other people's stacks
is in tension with the goal of easy adoption, and that tension should be
resolved deliberately rather than by default.
