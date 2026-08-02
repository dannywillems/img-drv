# How Nix actually works

Written to be implementable against, not to sell anything. Every claim here
should carry a source; where one is missing it is marked UNVERIFIED and must be
checked before code depends on it.

## The three systems people call "Nix"

1. **The evaluator.** Reads the Nix language, produces derivations. Lazy, pure,
   dynamically typed. Its only output that matters is `.drv` files.
2. **The store and the daemon.** Realizes derivations: sandboxed builds, the
   content-addressed store, garbage collection, substituters, remote builders.
3. **NixOS.** A module system on top, producing a system closure and an
   activation script.

`img-drv` replaces (1), reuses (2), and defers (3).

## Expressions, derivations, outputs: three stages, not two

The single most common confusion, and the one that decides what this project
can and cannot read. These are three different things with three different
representations:

| stage | what it is | representation |
| --- | --- | --- |
| **expression** | source in the Nix LANGUAGE | `default.nix`, `flake.nix`: text in a lazy functional language |
| **derivation** | a build recipe, first-order DATA | `/nix/store/<hash>-name.drv`, an ATerm |
| **output** | the built files | `/nix/store/<hash>-name/`, a directory |

and two transitions between them:

```
expression --[ evaluate ]--> derivation --[ realise ]--> output
              nix-instantiate              nix-store --realise
```

So yes: **an expression produces a derivation**, by evaluation. It is not a
different notation for one. `pkgs/.../cnijfilter_2_80/default.nix` is 140 lines
of Nix calling `stdenv.mkDerivation`; evaluating it yields ONE `.drv` whose
closure is 1458 derivations, because `stdenv`, its inputs, and their inputs are
all expressions that evaluate to derivations too.

The evaluation is where nearly all of Nix's complexity lives: laziness, the
module system's fixed point, `import`, string contexts, and the whole of
nixpkgs' `lib`. The derivation, by contrast, is inert first-order data with a
documented on-disk format, which is exactly why `img-drv` targets it.

**What that means for this project.** The four implementations here read and
write DERIVATIONS. None of them can parse an expression, and that is a design
choice rather than an omission: the eDSLs replace the evaluator, so a build is
described in Python, Rust, Go or OCaml and emitted straight as a `.drv`. The
gap is visible and measurable: `cnijfilter_2_80`'s expression cannot be parsed
by anything here, while its instantiated closure verifies completely (1458 of
1458 round-tripped byte-identically, 2063 of 2063 output paths reproduced, in
all four languages).

Closing that gap means writing an evaluator, which is `PLAN.md` phase 4 and is
deliberately the largest remaining item.

## Derivations: the IR

A **store derivation** is the reified build description. It is stored on disk in
**ATerm** format, and the derivation itself is content-addressed using the
"text" method of content addressing.
Source: <https://nix.dev/manual/nix/2.34/store/derivation/> and the derivation
ATerm format page in the same manual.

Fields (to be confirmed field-by-field against the manual before implementing):

- `outputs`: named outputs and their paths
- `inputDrvs`: other derivations this one depends on, with the outputs needed
- `inputSrcs`: store paths used directly as sources
- `system`: e.g. `x86_64-linux`
- `builder`: the executable to run
- `args`: its arguments
- `env`: the environment it runs under

Note from the manual worth remembering: the ATerm format does NOT contain the
derivation's name, on the assumption that a store path is supplied
out-of-band.

## Input addressing: why paths are known before building

In the default (input-addressed) scheme, a store path is computed from a hash
over the derivation, which transitively includes the hashes of every input
derivation. So the output path is determined BEFORE anything is built.

That single property is what makes substitution possible: Nix can ask a binary
cache "do you have this path?" without building, because it already knows the
path it would produce.

Content-addressed derivations, where the path is derived from the built output
instead, exist but are experimental.

## Purity comes from the sandbox, not the language

The Nix language being pure is not what makes builds reproducible. The BUILDER
is sandboxed: no network access, a fixed environment, an isolated filesystem,
timestamps normalized. The escape hatch is the **fixed-output derivation**,
which is allowed network access precisely because it declares the hash of what
it will fetch up front, so the result is still verified.

This is the piece `img-drv` most wants to reuse rather than reimplement.

## Realisation: turning the recipe into files

A derivation is inert data. `minimal.drv` says: run `/bin/sh` with
`["-c","echo hi > $out"]` and this environment. Nothing has executed.
`nix-instantiate` stops here, having evaluated the language down to
derivations and written them to the store. The output path is nevertheless
already fixed, even though nothing exists there yet: that is input addressing,
the path is a hash of the RECIPE, not of the result.

`nix-store --realise` (or `nix build`) turns a recipe into files. For each
output path:

1. **Does the path already exist?** If so, done, nothing runs. This is why
   rebuilding an unchanged package is instant.
2. **Can a substituter provide it?** Nix asks a binary cache "do you have this
   path?", and because the path was computed from the recipe the cache can
   answer WITHOUT building anything. If yes, it downloads a prebuilt result.
   This is why most Nix users never compile anything.
3. **Otherwise build it**, having first realised every `inputDrvs` entry
   recursively, which is the dependency graph doing its work.

The build itself runs `builder` with `args` in a sandbox:

- a fresh mount namespace containing only the declared inputs, the closure of
  `inputDrvs` and `inputSrcs`, and nothing else from the system
- no network, which is why a plain build cannot fetch anything
- a scrubbed environment holding exactly the derivation's `env`
- an empty writable `$TMPDIR`, typically an unprivileged build user, and
  timestamps normalised to 1970 so archives and mtimes are deterministic

The builder writes to `$out`, which is just an environment variable holding the
predetermined path. That is why `echo hi > $out` works at all.

For a real package the builder is not `/bin/sh` directly but bash from the
store, running a script that does the familiar `./configure && make && make
install` with `--prefix=$out`. Nothing exotic: real compilers producing real
binaries. The only unusual parts are WHERE the inputs come from (store paths,
not `/usr`) and WHERE the output goes.

When the builder exits, Nix makes the output read-only, scans it for references
to other store paths (the runtime closure is discovered by literally looking
for store path strings inside the files), and registers it in its database.

### The fixed-output escape hatch

Something has to download source tarballs, and builds have no network. Hence
the fixed-output derivation, which declares its result hash UP FRONT. Because
the output is verified against that hash, network access is safe: nothing can
be smuggled in, since the bytes must match. Every `fetchurl` in nixpkgs is one
of these.

### Why this is exactly what img-drv reuses

The sandboxing, the store database, garbage collection, the substituter
protocol and reference scanning are the hard 90%, and none of it is being
rebuilt. Emitting a byte-correct `.drv` is the whole interface: hand it to
`nix-store --realise` and all of that comes for free.

Which is why store path computation had to be exactly right. Wrong hashes
produce a syntactically valid derivation that no cache can ever satisfy, that
silently rebuilds the world, and whose outputs land at paths nothing else
refers to. Right shape, wrong identity. See
[`spec/store-paths.md`](spec/store-paths.md).

## Atomic activation is a symlink rename

`/run/current-system` points at a store path. A "generation" is a symlink.
Switching is repointing it plus running an activation script; rolling back is
repointing it at the previous one. Bootloader entries are generated per
generation.

Worth internalizing: the celebrated atomic rollback is mostly **a symlink swap
over an immutable store**. It is cheap to copy conceptually, and it is the
property `iso-img` most lacks.

## The module system is a fixed point

NixOS modules are functions of the FINAL configuration. Evaluation computes the
fixed point of that system of equations. Option declarations carry a type, and
the type supplies a merge function; `mkDefault`, `mkForce` and `mkOrder` adjust
priority when several modules define the same option.

Implementation entry points, for reading:
`nixpkgs/lib/modules.nix` and `nixpkgs/nixos/lib/eval-config.nix`.

The law that makes module ORDER irrelevant is that the merge be commutative,
associative and idempotent, i.e. a join-semilattice. See `theory.md` section 6.

## What is genuinely hard, and therefore reused

- sandboxing per platform (namespaces on Linux, `sandbox-exec` on macOS)
- the store, its database, and garbage collection with roots
- substituters, signatures and trust
- remote and distributed builds
- twenty years of accumulated corner cases in nixpkgs' stdenv

**Snix** and **Tvix** matter here: they split Nix into evaluator, builder and
store behind defined protocols, explicitly so alternative front-ends can plug
in. That is what makes a foreign front-end tractable rather than a rewrite.
Source: <https://snix.dev/blog/announcing-snix/>, <https://tvix.dev/>

## Open questions to resolve before Phase 1

- [x] Exact ATerm grammar and escaping rules, field by field. DONE, and
      derived empirically because the manual does not publish the grammar.
      See `spec/canonical.md`.
- [x] Exact store path hash computation. SOLVED and verified against real
      Nix; see `spec/store-paths.md` and `scripts/store_paths.py`.
- [x] How `inputDrvs` names outputs: `(drvPath, [outputNames])`. Multi-entry
      sort order is still open.
- [ ] Whether `nix-instantiate` output is byte-stable across Nix versions, and
      which version we pin as the differential oracle.
- [ ] Whether to target the Nix daemon protocol or simply write `.drv` files
      into the store and invoke `nix-store --realise`.
