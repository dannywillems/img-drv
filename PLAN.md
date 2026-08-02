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

1. **OCaml**, the typed reference, with abstract types in `.mli` files. The
   last of the four, and the only one left that could still surprise us: it is
   the one language where the signature could be made unrepresentably wrong
   rather than merely checked.
2. **Describe `scripts/probe.nix` in the eDSL** so `make differential` becomes
   a LIVE oracle for the eDSL rather than only for the parser. The ten golden
   examples already pin the eDSL against real Nix, but they are checked-in
   files; the probe runs against a real `nix-instantiate` on every push.
3. **`__structuredAttrs`**, the second env encoding, which 1223 of the 2516
   real derivations in the corpus use (`docs/spec/canonical.md` section 1.8).
   Until it is specified the eDSL cannot express a modern nixpkgs package.
4. **NAR serialization and `inputSrcs`**, the last unspecified corner of the
   format (`docs/spec/canonical.md` section 3).

## State

- [x] Thesis stated so it can fail.
- [x] The mathematics that constrains the design (`docs/theory.md`).
- [x] Signature drafted (`docs/spec/signature.md`).
- [x] Serialization derived EMPIRICALLY from real Nix, with golden files
      (`docs/spec/canonical.md`, `docs/spec/examples/`).
- [x] An ATerm parser: recursive descent, no regexes. 805 of 805 real nixpkgs
      derivations round-trip BYTE-IDENTICALLY.
- [x] A real-vector harness: pull random nixpkgs packages, export their .drv
      closures, verify against them (`scripts/fetch-corpus.sh`).
- [x] Store path computation. SOLVED and verified against real derivations:
      1259 of 1259 output paths across 805 real nixpkgs derivations, plus
      12 of 12 golden examples.
- [x] CI: GitHub Actions, SHA-pinned, every job through a Makefile target.
- [x] Oracle pinned by DIGEST (`scripts/pins.env`), with byte-stability
      measured across two Nix releases rather than assumed.
- [x] `make differential` implemented: instantiate a probe with the pinned Nix,
      recompute every store path in the closure, compare. 7 of 7.
- [x] Licence decided: MPL-2.0 for code, CC0 for the spec
      (`docs/decisions/2026-08-01-licence-mpl-2.0.md`).
- [x] **Python library** (`impl/python/`): the verified reference, as a typed,
      packaged, semver'd library. `mypy --strict` clean, 32 tests including
      property-based ones, wheel and sdist build.
- [x] **The Python eDSL surface** (`impl/python/src/img_drv/edsl.py`). All ten
      golden examples reproduced BYTE-IDENTICALLY from intent, including each
      derivation's own `.drv` store path. The laws are property-tested with
      Hypothesis over generated intents, not examples.
- [x] The canonical form shown to be NIX's rather than ours: canonicalizing is
      the identity on 2516 of 2516 real derivations, and `make corpus` now
      gates it on a fresh random sample.
- [x] **A second implementation** (`impl/rust/`): a reusable crate,
      `deny(warnings)`, newtypes, enums for the sums, no `unwrap` outside
      tests, 41 tests including the same property-based laws as Python.
- [x] **`make conformance` is real, and has been seen to FAIL.** 10 intents, 2
      implementations, byte-identical to each other AND to what real Nix
      emitted. Sabotaging one ordering rule moves a store path and the target
      reports which implementation stopped matching Nix.
- [x] **Go, the falsification test, came back NEGATIVE** (`impl/go/`). The
      signature needed nothing beyond finite products; four generic functions,
      all of the weak kind. What Go costs is enforcement and uniformity, not
      expressiveness, and the tally is in `impl/go/README.md`.
- [x] **`make conformance` across THREE implementations**: 10 intents, Python,
      Rust and Go, byte-identical to each other and to real Nix.
- [ ] `__structuredAttrs`, without which the eDSL cannot express a modern
      nixpkgs package.

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
- [x] **The hash.** Store path computation (the `output:out:sha256:...`
      fingerprint and Nix's base-32 encoding) verified against real
      derivations: 1259 of 1259 output paths across 805 real nixpkgs
      derivations, plus 12 of 12 golden examples. See `docs/spec/store-paths.md`.
      This was the Phase 1 blocker, and it is closed.

Exit test: a human can serialize the worked example with a pencil and get the
documented bytes. Reachable, including the store paths.

## Phase 1: Python first, then OCaml, and a real build (1 to 2 weeks)

Python first because the spec is still moving and Python is the cheapest place
to discover that a rule is wrong. It doubles as executable documentation: the
serializer should read like `canonical.md`.

OCaml second, as the typed reference, because sum types and exhaustiveness are
what make the normalizer honest once the rules have stopped changing.

- [x] eDSL producing the IR value, fully typed (`mypy --strict` clean).
- [x] Canonical serializer, shown to be the identity on real Nix output.
- [x] ATerm emitter producing a `.drv`.
- [x] `ci.yml` running the Python jobs through Makefile targets.
- [x] `impl/python/README.md`.
- [ ] The first real-world example (needs `__structuredAttrs`).
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

- [x] Golden-file conformance suite: a set of intents, each with its expected
      canonical bytes and hash. Lives in each implementation as an `examples`
      module so that the tests, the `examples` CLI command and
      `make conformance` all consume the SAME ten intents.
- [x] Rust eDSL passing it, `deny(warnings)`, newtypes, no `unwrap`.
- [x] Go eDSL passing it, no `any` in the signature. The only `reflect` in the
      implementation is in its property-test generator, which stdlib
      `testing/quick` forces.
- [ ] CI matrix covering all four pinned toolchains. Python, Rust and Go done.
- [x] Per-language docs, and the typing table recording which invariants each
      type system makes unrepresentable (`impl/rust/README.md`). The first
      result: a stronger type system removes the checks you make on values you
      CONSTRUCT, and none of the checks on values you COMPUTE.
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

## Phase 4 (speculative): the Nix language as a front-end, and round trips

Only once the IR exists in all four languages, and clearly after Phase 3. Noted
now because it changes what the IR is FOR, and that is worth knowing early.

If the IR is genuinely the initial object, then the Nix language is just
another presentation of it, and two things follow:

- **A Nix front-end.** Parse the Nix language, evaluate it, emit our IR. OCaml
  is the natural host: the grammar and the evaluator are exactly what ML was
  designed for. This would let existing Nix code, including `flake.nix`, be
  compiled to the IR and consumed by any of the four eDSLs.
- **Round trips.** Lower the IR back into whichever surface a person prefers.
  From the theory this is not a separate feature: every backend is an algebra,
  and a pretty-printer for language X is just the algebra whose carrier is
  X's syntax. The uniqueness of the homomorphism out of the initial object is
  what makes "IR to any language" well posed at all.

Honest caveats, since this is the part most likely to be underestimated:

- Emitting derivations is a fraction of what a Nix EVALUATOR does. Laziness,
  the fixed-point module system, `import`, string contexts and the whole of
  nixpkgs' `lib` are the real surface, and a partial evaluator that handles
  `flake.nix` but not nixpkgs is of limited use.
- Round trips are only faithful up to the congruence in `theory.md` section 4.
  IR to Nix to IR should be the identity ON THE QUOTIENT; expecting the
  original TEXT back is a category error, and saying so up front avoids a
  disappointment later.
- Snix already has an evaluator. Reusing it may beat writing one, and that
  comparison should be made before any parser is started.

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

- **Daemon protocol or files?** Write `.drv` into the store and call
  `nix-store --realise`, or speak the daemon protocol directly. Files first.
- **`__structuredAttrs`.** 1223 of 2516 real derivations in the corpus collapse
  their whole env into a single `__json` entry instead of one variable per
  attribute. That is a second env encoding, and the eDSL does not emit it. It
  has to be specified before the eDSL can express a modern nixpkgs package.
- **Name.** `img-drv` says "image derivation". If the artifact layer turns out
  to be general rather than image-specific, revisit.

Resolved, kept here only so the resolution is findable:

- ~~**Licence.**~~ MPL-2.0 for code, CC0-1.0 for `docs/spec/`
  (`docs/decisions/2026-08-01-licence-mpl-2.0.md`).
- ~~**Which Nix version is the oracle**, and is it byte-stable?~~ `nixos/nix`
  2.35.1, pinned BY DIGEST in `scripts/pins.env`. Byte-stability measured
  across 2.34.8 and 2.35.1 rather than assumed.

## How this repository is kept

- `docs/theory.md` is normative: design choices must trace back to it, or be
  labelled preferences.
- `docs/abstractions.md` is the running record of which structure each piece of
  the implementation realizes, its laws, and where each law is tested. A
  feature larger than a refactor adds an entry in the same commit.
- `docs/spec/` is versioned. Changing canonical bytes is a breaking change and
  gets a version bump.
- Decisions that would otherwise be re-litigated get a file under
  `docs/decisions/`, with costs and a revisit condition, following the same
  convention as `iso-img`.

---

## Plan log

- **2026-08-02** Go landed, and the falsification test came back NEGATIVE: the
  first-order signature needed nothing beyond finite products, and three
  implementations now emit byte-identical IR for the same ten intents,
  byte-identical to real Nix. `theory.md` section 1 survived the test it was
  most likely to fail.

  The honest cost is in ENFORCEMENT, not expressiveness. A finite sum becomes a
  defined string type that accepts any string, so `HashAlgo("sha3")` compiles;
  `Option` has no single spelling, so one concept became three encodings; and
  structural equality is hand-written because a struct holding a slice is not
  comparable. Roughly 2x Python's line count, almost none of it about the
  signature.

  The finding that would have been a BUG rather than bulk: the obvious Go
  encoding of `outputs` is a nil slice for "not declared", and Go deliberately
  makes nil and empty slices behave alike, so the one distinction the bytes
  depend on is the one the language encourages you to ignore. An explicit
  discriminant is the only safe encoding.

  Go is also BETTER in two places worth recording: randomised map iteration
  turns a missing sort from a silent bug into a flaky one, so the determinism
  law is a real test here and nearly vacuous elsewhere; and Go defines
  over-wide shifts as zero, so the release-only `base32` bug the Rust port hit
  cannot occur. See `docs/abstractions.md` entry 7 and `impl/go/README.md`.

- **2026-08-02** Rust port landed, and `make conformance` is real: 10 intents,
  2 implementations, byte-identical to each other AND to what real Nix
  emitted. The three-way diff is deliberate, since two implementations
  agreeing on the wrong bytes would pass a two-way one. The target was then
  SABOTAGED to check it can fail: emitting the `outputs` env variable sorted
  instead of in declaration order moves `multi` from `v27a4...` to `hm669...`
  and conformance names Rust as the implementation that stopped matching Nix.

  Porting found a bug testing one implementation never would: `base32` shifts
  a `u8` by `8 - offset`, which is a shift by 8 when `offset` is 0. Python is
  correct without a guard because its integers are unbounded; Rust PANICS in
  debug and silently MASKS the shift to 0 in release. The release build was
  clean. A release-only wrong answer inside a hash function is the worst
  available failure mode.

  First entry in the typing table: Rust turns three of Python's runtime checks
  into compile-time impossibilities and one property test into a non-property
  (`BTreeMap` has no insertion order to leak), and turns NONE of the checks
  that compare a value against computed data. Those need a checker rather than
  a type, in any language. Recorded in `impl/rust/README.md` and
  `docs/abstractions.md` entry 6.

- **2026-08-02** The Python eDSL surface landed: a build can now be DESCRIBED,
  not only read. Every one of the ten golden examples is reproduced
  byte-identically from intent, including its own `.drv` store path, so the
  eDSL is pinned against real Nix rather than against our own reader. Three
  rules had to be established from the corpus first, because the two golden
  files that exercise them do not distinguish the alternatives: `inputDrvs` is
  sorted by store PATH with each inner name list sorted (1293 of 1293 real
  derivations, 9983 of 9983 inner lists), `inputSrcs` ascending (1293 of 1293),
  and the fixed-output `hashAlgo`/`hash` re-encoding (93 of 93). All three were
  OPEN in `canonical.md` and are now measured.

  The finding that changed the API: `outputs` is an OPTION, not a list
  defaulting to `["out"]`. Nix emits an `outputs` env variable exactly when the
  caller DECLARED the attribute, so `None` and `["out"]` are different
  derivations with different store paths, and 96 single-output derivations in
  the corpus do the first while 605 do the second. Modelling it either way as a
  default makes one of the two unreproducible.

  Also found: 1223 of the 2516 corpus derivations use `__structuredAttrs`,
  collapsing the whole env into one `__json` entry. That is a second env
  encoding, it is not specified, and it is why "the first real-world example"
  is not simply the next task.

- **2026-08-01** Oracle pinned to `nixos/nix:2.35.1` BY DIGEST. Byte-stability
  measured, not assumed: 2.34.8 and 2.35.1 emit byte-identical derivations for
  a probe exercising multiple outputs, a dependency edge and unsorted env keys.
  `make differential` now instantiates `scripts/probe.nix` with that pinned Nix
  and recomputes every store path in the closure: 7 of 7, including the
  `r:sha256` case that only one derivation in 226 exercised. The target used to
  `exit 1`, so the CI job had never passed.
- **2026-08-01** Licence decided: MPL-2.0 for code, CC0-1.0 for `docs/spec/`.
  GPL-3.0 was self-defeating for a library whose purpose is embedding, and LGPL
  fits badly because three of the four target languages link statically, making
  its relinking clause burdensome and arguable. File-level copyleft keeps
  changes to the IR open without any linking analysis.
- **2026-08-01** Python library landed at `impl/python/`, replacing the two
  scripts. Same verified logic, now typed (`NewType` for store paths, digests
  and output names, since confusing two 64-character strings is a bug this
  project has already paid for), `mypy --strict` clean, and packaged. The
  serialization laws are property-tested with Hypothesis: `parse . unparse =
  id` universally, `unparse . parse = id` on canonical text only, which is what
  a canonical form MEANS.

- **2026-08-01** Store path computation SOLVED: 1259 of 1259 output paths
  across 805 real nixpkgs derivations. The two bugs that hand-written examples
  could never have caught: a fixed-output derivation has two different hash
  strings, the one identifying it as an INPUT appending the output path, which
  left every fetch correct and everything downstream of a fetch wrong; and
  `r:sha256` uses the `source` kind with the declared hash directly rather than
  a `fixed:out:` fingerprint, exercised by exactly one derivation in a
  226-derivation closure. Added AGENTS.md so neither is rediscovered.

- **2026-08-01** Real nixpkgs derivations DISPROVED the store-path claim: 12/12
  on hand-written examples, 80/403 on a real closure. Replaced the regex
  pseudo-parser with a real recursive-descent one, which now round-trips 226 of
  226 real derivations byte-identically, and added a harness that pulls RANDOM
  packages so CI keeps finding cases a fixed corpus never would. Also settled
  multi-entry inputDrvs ordering: the .drv sorts by store PATH, the hashed form
  re-sorts by input HASH, and a textual substitution silently gets this wrong
  on anything with more than one input.

- **2026-08-01** Store path computation SOLVED and verified: 8/8 golden paths
  reproduced from derivation text alone, including a derivation reconstructed
  from scratch. The subtle part is an asymmetry, mask your own outputs but not
  your inputs', established by testing all four combinations and keeping the
  only one that reproduces Nix. Phase 1 is unblocked. Also added a Phase 4
  sketch: a Nix front-end in OCaml and IR-to-any-language round trips, which
  the initial-object argument makes well posed.

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
