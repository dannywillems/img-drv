# How the codebase is organized, and why

The goal that shapes this layout: **a developer writes Nix expressions in the
language they already use, and never learns the Nix language.** That is one
sentence and it implies almost everything below.

The mathematics is in [`theory.md`](theory.md); section 8 is the one that
governs this file. This file is the map from that mathematics to directories.

## Two term algebras, not one

There are two initial objects in this project and it is worth naming them
before naming any directory, because every module belongs to one or sits on an
arrow between them.

```
                         host eDSL surface
                        (HOAS, feels native)
                                 |
                                 v
   .nix text  <--print--   EXPR  core        the SECOND-ORDER theory:
              --parse-->  (named/de Bruijn)  binding, functions, laziness
                                 |
                                 | evaluate
                                 v
   .drv bytes <--print--    DRV  core        the FIRST-ORDER theory:
              --parse-->   (Derivation)      finite products, no binders
                                 |
                                 | hash
                                 v
                            store path
```

- **DRV** is what the repository already has, in four languages, agreeing byte
  for byte. First-order, a Lawvere theory, `theory.md` sections 1 to 4.
- **EXPR** is the new one. Second-order, because it has binders, `theory.md`
  section 8.

Everything else is an arrow. Naming the arrows is what keeps the modules from
growing into each other:

| arrow | module | status |
| --- | --- | --- |
| EXPR to `.nix` | `expr/printer` | not started; this is the transpiler |
| `.nix` to EXPR | `expr/parser` | done in OCaml (`ocamllex` + `menhir`) |
| EXPR to DRV | `expr/eval` | started in OCaml |
| DRV to `.drv` | `ir/aterm` | done, four languages |
| `.drv` to DRV | `ir/aterm` | done, four languages |
| DRV to store path | `ir/store` | done, four languages |

## The layout each implementation follows

```
impl/<lang>/
  ir/        the FIRST-ORDER core: Derivation, ATerm, store paths, the eDSL
             surface for describing derivations directly.
             Zero dependencies. This is the part that must never regress.

  expr/      the SECOND-ORDER core: the Nix expression AST, its printer, its
             parser, and its evaluator. Depends on ir/, never the reverse.

  compose/   the composability layer: overlays as mixins, `//`, and the fixed
             point that closes them. Pure host-language values; it produces
             EXPR terms and knows nothing about bytes.

  cmd/       the CLI, driving all of the above through Makefile targets.
```

The one-way dependency `expr → ir` is the important rule. It is what keeps the
derivation core free of the language's complexity, so that a bug in the
evaluator can never change a store path computed by the eDSL.

## Why `ir/` and `expr/` are separate libraries rather than one

Three reasons, in order of how much they would cost to get wrong.

1. **Dependencies.** `ir/` has none in Python, Go and OCaml and one in Rust.
   `expr/` needs a parser generator per `decisions/2026-08-02-nix-frontend-build-not-reuse.md`.
   Someone embedding img-drv to emit derivations should not inherit menhir.
2. **Blast radius.** The store-path computation is verified against 2516 real
   derivations and four implementations. The evaluator is new. Keeping them in
   separate compilation units means the evaluator cannot accidentally widen a
   type the IR depends on.
3. **They are different theories.** First-order and second-order are not a
   stylistic distinction; the second needs an exponentiable generator and the
   first does not. Directories that mirror the mathematics stay honest longer
   than directories that mirror a feature list.

This is already true in OCaml: `impl/ocaml/lib/` is `img_drv` with zero
dependencies and `impl/ocaml/nix/` is `img_drv_nix`, which depends on it.

## The surface/core split inside `expr/`

`theory.md` section 8 argues for HOAS at the surface and a named or de Bruijn
core underneath. Concretely:

```
expr/
  surface.<ext>   what a user writes: lam (fun x -> ...), attrs [...], //
  core.<ext>      the AST: named binders, no host closures, fully inspectable
  lower.<ext>     surface -> core, inventing names with a fresh supply
  printer.<ext>   core -> .nix text
  parser.<ext>    .nix text -> core   (generated)
  eval.<ext>      core -> ir::Derivation
```

`lower` is the only module that sees a host closure. Everything downstream sees
data. That is the same discipline as the existing eDSL, where `derivation()`
is the only thing that computes store paths and everything else manipulates a
`Derivation` record.

## Where composability lives, and what it actually is

`compose/` implements one thing well rather than three things partly:

**An overlay is a mixin.** `final: prev: { ... }` is Cook and Palsberg's
wrapper over a generator, composed asymmetrically and closed by a fixed point
(`theory.md` section 8). So the host-language interface a user implements is:

```
overlay : Attrs -> Attrs -> Attrs        (final, previous, additions)
compose : Overlay -> Overlay -> Overlay  (associative, identity = fun _ prev -> {})
fix     : Overlay -> Attrs
```

That is a **monoid** with a map out of it, and it needs only functions and
records, so it is the mechanism most worth porting to all four languages first.
It is also the honest answer to "a trait/signature/abstract class describing a
Nix expression": the trait is the mixin, and composition is the monoid
operation.

What `compose/` should NOT do yet is reimplement the module system. Its merge
is n-ary and does not decompose into binary merges (`theory.md` section 6), so
it is a different and larger piece of work, and `PLAN.md` phase 3 keeps it
separate deliberately.

## How correctness is established at each layer

Each arrow gets an oracle, and none of them is a unit test we wrote about
ourselves:

| layer | oracle | current state |
| --- | --- | --- |
| DRV to `.drv` | real Nix, via `make conformance` | 11 intents, 4 implementations |
| `.drv` to DRV | real nixpkgs closures, `make corpus` | 2516 derivations |
| store paths | `make differential` against pinned Nix | 7 of 7, plus 1259 of 1259 |
| `.nix` to EXPR | `nix-instantiate --parse`, 59 vectors | OCaml only |
| EXPR to `.nix` | **the commuting square** (below) | not started |
| EXPR to DRV | the same square | not started |

The square is the one that matters for the transpiler, and it is worth stating
as a target before any code is written:

> Take a term. Print it to `.nix`, hand that to real Nix, instantiate: get a
> `.drv`. Separately, evaluate the same term ourselves: get a `.drv`. **The two
> must be identical.**

Both halves are then checkable against `make conformance`, which already knows
what the right bytes are for eleven intents. So the transpiler's first
milestone is not "it prints something Nix accepts", it is "it prints something
Nix turns into the bytes we already know are right".

## What stays out

- **`with` and dynamic attribute names.** The printer should be unable to emit
  them; `theory.md` section 8 says why (they defeat safe renaming). If a user
  needs them, the answer is that the host language already has scoping.
- **Reimplementing `lib` and `stdenv`.** A transpiler that emits
  `import <nixpkgs>` and calls into it is a far better first target than one
  that rewrites `mkDerivation`.
- **An effect layer.** Unchanged from `theory.md` section 5: this repository
  emits descriptions and does not converge machines.
