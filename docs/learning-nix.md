# Learning Nix properly, in order

The usual complaint about Nix documentation is that there are docs for the
language and docs for the OS, and the connection between them is undocumented.
This path is arranged to close exactly that gap, and to be useful for THIS
project: the goal is not to become a NixOS user, it is to understand the model
well enough to reimplement its front-end and to know precisely which parts are
worth reusing.

Work through it in order. Each step has a "you understand this when" test,
because reading Nix material and believing you have understood it is the
characteristic failure mode.

## 0. Frame it correctly before reading anything

Nix is a **build system whose outputs happen to include operating systems**. It
is not a package manager with unusual syntax. Every confusing thing becomes
less confusing once "everything is a derivation, and a derivation is a pure
function from inputs to a store path" is the frame.

## 1. The store and derivations (start here, not with the language)

Most tutorials start with the language. Start with the data model instead: it
is smaller, it is documented, and it is the part this project reimplements.

- Nix manual: "Store Derivation and Deriving Path",
  <https://nix.dev/manual/nix/2.34/store/derivation/>
- Nix manual: the derivation ATerm format page in the same version.

**You understand this when** you can, by hand:
- take a trivial expression, run `nix-instantiate` on it, and read the
  resulting `.drv`;
- explain every field in it;
- say why the output path is known before the build runs.

## 2. Realization, sandboxing, substitution

- What `nix-store --realise` does.
- Why a build has no network, and what a fixed-output derivation is for.
- What a substituter is, and why input addressing is what makes it possible.

**You understand this when** you can explain why a binary cache can answer
"I have that already" without ever seeing your source.

## 3. The language, now that you know what it is FOR

Only now. The language exists to produce the structures from step 1.

- <https://nix.dev> tutorials, and the "Nix language basics" page.
- Read `lib/` in nixpkgs with the question "what is this doing to derivations?"

**You understand this when** you can write a derivation by hand with
`builtins.derivation`, with no `stdenv`, no `mkDerivation`, no helpers, and
build it.

## 4. stdenv and nixpkgs conventions

This is where the real complexity lives, and where most of the twenty years of
work sits.

- `stdenv.mkDerivation`, phases, hooks.
- Overlays and `override` / `overrideAttrs`.

**You understand this when** you can patch a package's source and rebuild it
without copying a recipe from somewhere.

## 5. NixOS: the module system

- `nixpkgs/lib/modules.nix`, `nixpkgs/nixos/lib/eval-config.nix`.
- Options, types, merge functions, `mkDefault` / `mkForce` / `mkOrder`.

**You understand this when** you can explain why module order usually does not
matter, and construct a case where priorities make it matter.

## 6. Generations and activation

- What `nixos-rebuild switch` versus `boot` versus `test` actually do.
- Where generations live and how rollback works.

**You understand this when** you can describe rollback without using the word
"magic", i.e. as a symlink swap over an immutable store.

## 7. Reading an alternative implementation

Once the model is clear, reading a second implementation teaches more per hour
than any tutorial, because it separates the model from C++ Nix's accidents.

- Snix / Tvix: evaluator, builder and store split behind protocols.
  <https://snix.dev/blog/announcing-snix/>, <https://tvix.dev/>

**You understand this when** you can say which parts of `img-drv` should call
into an existing builder and which parts are genuinely ours.

## Deliberately skipped, for now

- **Flakes.** Useful in practice, still experimental, and orthogonal to the
  model. Learning them early confuses "the model" with "the current UX".
- **home-manager, nix-darwin, devenv.** Consumers of the model, not the model.

## Keep a log

Per the learning-log convention: every genuinely new concept gets a dated,
sourced entry. The test for whether a step is finished is whether you could
write that entry without looking anything up again.
