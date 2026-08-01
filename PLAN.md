# PLAN

**This file is the living plan, and the single source of tasks.** It is updated
every time a decision is made or a piece of work lands, and any task worth doing
should be derivable from it without asking anyone.

How it is used:

- **Now** is the ordered list of what to do next. Work is taken from the top.
- Checkboxes move to `[x]` only when the exit test passes, not when the code is
  written.
- When something is learned that changes the plan, change the plan in the same
  commit, and add a line to **Plan log** at the bottom.
- Reasoning that would otherwise be re-litigated goes to `docs/decisions/`, not
  here. This file says WHAT and WHEN; the decisions say WHY.

---

## Now

Ordered. The top item is the next thing to do.

1. **Work out store path computation empirically.** BLOCKING Phase 1, and the
   only thing standing between the spec and a first implementation. Probe real
   Nix until the `output:out:sha256:...` fingerprint and the base-32 encoding
   reproduce exactly. Until this is done, any implementation can emit a
   derivation with the right shape and wrong paths, which looks correct and is
   not.
2. **Pin the oracle.** Choose the Nix version the differential test compares
   against, and check whether `.drv` output is byte-stable across releases.
   `latest` was used to derive the rules and must not be used to test against.
3. **Decide the licence** before anyone else contributes. See Open questions.
4. **Scaffold Python**: `impl/python/`, pinned 3.14.6, `mypy --strict`, and the
   `ci.yml` skeleton calling Makefile targets.

## State

- [x] Thesis stated so it can fail.
- [x] The mathematics that constrains the design (`docs/theory.md`).
- [x] Signature drafted (`docs/spec/signature.md`).
- [x] Serialization derived EMPIRICALLY from real Nix, with golden files
      (`docs/spec/canonical.md`, `docs/spec/examples/`).
- [ ] Store path computation. **Blocking.**
- [ ] Any implementation at all.

---

The point of this plan is to make the thesis **cheap to disprove**. Phases 0 to
2 are weeks, and they end with a yes or a no. Nothing after that is committed
to until they land.

## Thesis, stated so it can fail

> The same build intent, expressed in Python, Go, OCaml and Rust through a
> first-order signature, serializes to BYTE-IDENTICAL intermediate
> representation, and that IR is accepted by an existing Nix builder as a valid
> derivation.

Two ways it fails, and both are informative:

- **Portability fails.** The signature cannot be expressed cleanly in Go
  without sum types or generics gymnastics. Then the Lawvere-theory argument in
  `theory.md` is wrong in practice, and we say so.
- **Canonicity fails.** The implementations disagree byte-for-byte and the
  disagreements cannot be closed by tightening the spec. Then content
  addressing across languages is not achievable this way.

## Phase 0: specify (days)

Deliverable: `docs/spec/`, versioned, normative.

- [x] The signature. See `docs/spec/signature.md`.
- [x] Canonical serialization: field order, sorting, escaping. Derived
      EMPIRICALLY from real Nix rather than guessed, and recorded with the
      probes that established each rule. See `docs/spec/canonical.md`.
- [x] Golden files from real Nix for five cases. See `docs/spec/examples/`.
- [ ] **The hash. STILL OPEN, and it blocks Phase 1.** Store path computation
      (the `output:out:sha256:...` fingerprint and Nix's base-32 encoding) is
      not yet verified. Until it is, an implementation can emit a derivation
      with the right shape and wrong paths, which looks correct and is not.

Exit test: a human can serialize the worked example with a pencil and get the
documented bytes. Currently reachable for everything EXCEPT the store paths.

## Phase 1: Python first, then OCaml, and a real build (1 to 2 weeks)

Python first because the spec is still moving and Python is the cheapest place
to discover that a rule is wrong. It doubles as executable documentation: the
serializer should read like `canonical.md`.

OCaml second, as the typed reference, because sum types and exhaustiveness are
what make the normalizer honest once the rules have stopped changing.

- [ ] eDSL producing the IR value, fully typed (`mypy --strict` clean).
- [ ] Canonical serializer.
- [ ] ATerm emitter producing a `.drv`.
- [ ] `ci.yml` running the Python jobs through Makefile targets.
- [ ] `impl/python/README.md` and the first real-world example.
- [ ] Hand it to an existing Nix store and build something trivial.
- [ ] **Differential oracle**: the same package written in the Nix language,
      instantiated with `nix-instantiate`, compared byte-for-byte with ours.

Exit test: `hello`-scale derivation builds through the real Nix builder, and
our `.drv` is byte-identical to Nix's own for the equivalent expression.

That test is the whole project in miniature: if our derivation matches, we
inherit the sandbox, the store, garbage collection and every substituter,
without owning any of them.

## Phase 2: Rust and Go, and the conformance suite (1 to 2 weeks)

Four implementations now span the typing axis end to end: Python (gradual),
Go (weak static), Rust (strong static), OCaml (strong static with inference).
If all four agree byte for byte, the portability claim is as well supported as
this kind of claim can be.

- [ ] Golden-file conformance suite: a set of intents, each with its expected
      canonical bytes and hash, language-independent. Seeded by
      `docs/spec/examples/`, which already holds five cases from real Nix.
- [ ] Rust eDSL passing it, `deny(warnings)`, newtypes, no `unwrap`.
- [ ] Go eDSL passing it, no `any` in the signature.
- [ ] CI matrix covering all four pinned toolchains.
- [ ] Per-language docs, and the typing table recording which invariants each
      type system makes unrepresentable.
- [ ] The six real-world examples, in all four languages, byte-identical.

Go is the **falsification test**, not a fourth port. It has no sum types, no
higher-kinded types, minimal generics. If the signature needs more than finite
products, this is where it shows. Record honestly how ugly it gets; that
ugliness is the experimental result.

Exit test: all four emit identical bytes for every case in the suite.

## Engineering baseline (runs alongside every phase)

Not a phase, because none of it can be deferred to the end without becoming a
rewrite. Each phase adds its language's slice of all four.

### Toolchain: latest stable, pinned, and bumped deliberately

Every implementation targets the LATEST STABLE release of its language, pinned
in a file, and CI uses that same pin. Versions verified upstream on
2026-08-01:

| language | version | pinned in |
| --- | --- | --- |
| Python | 3.14.6 | `.python-version` |
| Go | 1.26.5 | `go.mod` |
| Rust | 1.97.1 | `rust-toolchain.toml` |
| OCaml | 5.5.0 | `dune-project` / opam switch |

Rule: no floor-version ranges, no "whatever is installed". A version moves in
its own commit, with the diff readable, exactly as `iso-img` treats pins. A
project whose entire subject is reproducibility cannot have a fuzzy toolchain.

### Typing: as strong as each language permits, enforced in CI

The point of four languages is to span the typing axis, which only means
something if each implementation is as typed as its language ALLOWS. A
dynamically-typed Python implementation would make the comparison meaningless.

- **Python**: full annotations on every function and field; `mypy --strict`
  passing, with no `Any` in the public surface and no bare `dict`/`list`.
  Prefer `@dataclass(frozen=True)` and `Literal`/`Enum` over strings, and
  `TypedDict` or explicit classes over free-form mappings.
- **Go**: no `interface{}`/`any` in the signature. Named types over bare
  `string` for `OutputName`, `StorePath`, `System`. Where the signature needs a
  sum, model it explicitly (a sealed interface, or a struct with a discriminant
  plus a constructor per case) and RECORD how bad it is; that discomfort is the
  falsification test doing its job.
- **Rust**: `#![deny(warnings)]`, newtypes rather than `String` aliases,
  `enum` for every sum, no `unwrap` outside tests.
- **OCaml**: abstract types in `.mli` files so invalid values are
  unconstructible, variants for every sum, warnings as errors.

The interesting result to record: WHICH invariants from `spec/signature.md`
each type system can make unrepresentable, and which have to stay runtime
checks. That table is a genuine research output, not bookkeeping.

### CI: GitHub Actions, every check through a Makefile target

CI never invokes a raw tool. Every job calls `make <target>` so that a local
run and a CI run are identical, and the Makefile is the single answer to "how
do I run X".

- `ci.yml`: per-language `build`, `lint`, `typecheck`, `test`, run on a matrix
  of the pinned versions; plus `conformance` and `differential` once they
  exist.
- `pr-hygiene.yaml`: PR size, commit title length, no fixup commits, commit
  bodies for large changes (scripts from the toolbox repo).
- `changelog.yaml`: changelog hygiene, dedicated commits, valid hashes.
- `shellcheck.yaml`: every shell script.
- Actions pinned to a full commit SHA with a version comment, least-privilege
  `permissions`, `persist-credentials: false` on checkout, and no
  `${{ }}` interpolation inside `run:` blocks.
- Dependabot weekly for the actions and each language ecosystem.

The `conformance` job is the one that matters: it must fail loudly and
readably, showing the byte-level diff between implementations rather than just
a red cross.

### Documentation: one guide per language, plus the shared spec

The spec says what the bytes are. Per-language documentation says what it feels
like to USE the eDSL, and it is where the portability claim is either obviously
true or obviously strained.

For each of Python, Go, Rust and OCaml:

- `impl/<lang>/README.md`: install, build, test, and a five-line example.
- Idiomatic usage: what the eDSL looks like in that language's own style,
  rather than a transliteration of another language's.
- The typing table: which invariants are compile-time here and which are not.
- Generated API docs where the ecosystem expects them (pdoc, godoc, rustdoc,
  odoc), built in CI so they cannot rot.

A rule worth keeping: if an example needs a paragraph of explanation in one
language and one line in another, that asymmetry belongs in the docs, because
it is evidence about the thesis.

### Real-world examples, in the spirit of nixpkgs

Toy derivations prove the format; real ones prove the design. nixpkgs is
convincing because it packages actual software, and the same standard applies
here. Each example is written in ALL FOUR languages and must produce identical
bytes.

Ordered by what they stress:

1. **hello**: the smallest real package. Fetch, configure, make, install.
2. **A fixed-output fetch**: `fetchurl` with a declared hash. Exercises the
   network escape hatch and the hash re-encoding rule.
3. **A dependency chain**: three derivations deep, so `inputDrvs` is exercised
   with more than one entry, which is where the open sorting question bites.
4. **A multi-output package**: `out`, `dev`, `lib`, exercising the two
   different orderings in one file.
5. **A patched package**: source plus a patch applied, exercising `inputSrcs`
   with several entries.
6. **Something with a real dependency graph**: a small C program linking a
   library built by another derivation.

Each example carries the equivalent Nix expression next to it, so the
differential test covers it too. An example is not finished until it BUILDS
through a real Nix store, not merely until it serialises.

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

---

## Plan log

Newest first. One line per change, so the shape of the thinking is recoverable
without reading every commit.

- **2026-08-01** Added the engineering baseline: pinned latest-stable
  toolchains (Python 3.14.6, Go 1.26.5, Rust 1.97.1, OCaml 5.5.0), a typing
  requirement per language enforced in CI, GitHub Actions with every job going
  through a Makefile target, per-language documentation, and six real-world
  examples in the spirit of nixpkgs.
- **2026-08-01** Added Python as a fourth language, first in Phase 1, because
  the spec is still moving and Python is the cheapest place to discover a rule
  is wrong.
- **2026-08-01** Phase 0 mostly done. The serialization rules were DERIVED from
  real Nix rather than written from memory, because the manual does not publish
  the grammar. Store path computation found to be still open, and promoted to
  blocking.
- **2026-08-01** Repository created. Plan built to be cheap to disprove:
  phases 0 to 2 are weeks and end in a yes or a no.
