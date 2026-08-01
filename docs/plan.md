# Plan

The point of this plan is to make the thesis **cheap to disprove**. Phases 0 to
2 are weeks, and they end with a yes or a no. Nothing after that is committed
to until they land.

## Thesis, stated so it can fail

> The same build intent, expressed in Go, OCaml and Rust through a
> first-order signature, serializes to BYTE-IDENTICAL intermediate
> representation, and that IR is accepted by an existing Nix builder as a valid
> derivation.

Two ways it fails, and both are informative:

- **Portability fails.** The signature cannot be expressed cleanly in Go
  without sum types or generics gymnastics. Then the Lawvere-theory argument in
  `theory.md` is wrong in practice, and we say so.
- **Canonicity fails.** Three implementations disagree byte-for-byte and the
  disagreements cannot be closed by tightening the spec. Then content
  addressing across languages is not achievable this way.

## Phase 0: specify (days)

Deliverable: `docs/spec/`, versioned, normative.

- [ ] The signature. First-order only: strings, integers, paths, lists,
      records, references. No floats. Justify anything else against
      `theory.md` section 1.
- [ ] Canonical serialization: key ordering, integer encoding, string
      normalization and escaping, list versus set semantics, how references are
      encoded.
- [ ] The hash: what exactly is hashed, in what encoding.
- [ ] A worked example, by hand, of one trivial derivation, in full.

Exit test: a human can serialize the worked example with a pencil and get the
documented bytes.

## Phase 1: OCaml reference, and a real build (1 to 2 weeks)

OCaml first because sum types and exhaustiveness make the normalizer honest.

- [ ] eDSL producing the IR value.
- [ ] Canonical serializer.
- [ ] ATerm emitter producing a `.drv`.
- [ ] Hand it to an existing Nix store and build something trivial.
- [ ] **Differential oracle**: the same package written in the Nix language,
      instantiated with `nix-instantiate`, compared byte-for-byte with ours.

Exit test: `hello`-scale derivation builds through the real Nix builder, and
our `.drv` is byte-identical to Nix's own for the equivalent expression.

That test is the whole project in miniature: if our derivation matches, we
inherit the sandbox, the store, garbage collection and every substituter,
without owning any of them.

## Phase 2: Rust and Go, and the conformance suite (1 to 2 weeks)

- [ ] Golden-file conformance suite: a set of intents, each with its expected
      canonical bytes and hash, language-independent.
- [ ] Rust eDSL passing it.
- [ ] Go eDSL passing it.

Go is the **falsification test**, not a third port. It has no sum types, no
higher-kinded types, minimal generics. If the signature needs more than finite
products, this is where it shows. Record honestly how ugly it gets; that
ugliness is the experimental result.

Exit test: all three emit identical bytes for every case in the suite.

## Phase 3 (conditional): the module system

Only if 0 to 2 succeed, and only if there is an appetite for months rather than
weeks.

A standalone, law-abiding module system: options with types, merge as a
join-semilattice, priorities as an explicit deviation from it, evaluation as a
fixed point. Property-test the laws (commutativity, associativity,
idempotence), which is exactly what Nix's own implementation does not do.

This is arguably the most reusable idea in NixOS and nobody has extracted it.

## Explicitly out of scope

- **An effect layer.** No `apply`, no machine convergence, no hypervisor
  drivers. See `theory.md` section 5: that is a different algebra and merging
  the two is the classic failure. `iso-img` keeps that job.
- **Our own store or builder.** Reuse Nix or Snix. The hard 90% is there.
- **A standalone language.** Settled in `iso-img`'s decision log: the surface
  is a library in languages people already use.
- **macOS provisioning.** No answer-file mechanism exists, and the EULA caps
  VMs at two per Mac on Apple hardware. Out of scope at any phase.

## Open questions

- **Licence.** GPL-3.0 as requested. Note the tension: the stated goal is that
  people embed these eDSLs in their own stacks, and strong copyleft on a
  library is a real adoption barrier, which is why libraries in this space
  usually pick LGPL, MPL-2.0 or Apache-2.0. Resolve deliberately. Whatever is
  chosen, decide BEFORE anyone else contributes, because relicensing later
  needs every contributor's agreement.
- **Which Nix version is the oracle**, and is its `.drv` output byte-stable
  across releases?
- **Daemon protocol or files?** Write `.drv` into the store and call
  `nix-store --realise`, or speak the daemon protocol directly. Files first.
- **Name.** `img-drv` says "image derivation". If the artifact layer turns out
  to be general rather than image-specific, revisit.

## How this repository is kept

- `docs/theory.md` is normative: design choices must trace back to it, or be
  labelled preferences.
- `docs/spec/` is versioned. Changing canonical bytes is a breaking change and
  gets a version bump.
- Decisions that would otherwise be re-litigated get a file under
  `docs/decisions/`, with costs and a revisit condition, following the same
  convention as `iso-img`.
