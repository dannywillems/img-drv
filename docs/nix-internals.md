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
- [ ] Exact store path hash computation for input-addressed derivations,
      including the `output:out:sha256:...` style fingerprint strings.
- [x] How `inputDrvs` names outputs: `(drvPath, [outputNames])`. Multi-entry
      sort order is still open.
- [ ] Whether `nix-instantiate` output is byte-stable across Nix versions, and
      which version we pin as the differential oracle.
- [ ] Whether to target the Nix daemon protocol or simply write `.drv` files
      into the store and invoke `nix-store --realise`.
