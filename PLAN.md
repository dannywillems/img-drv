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

1. **The evaluator, widened FURTHER.** Fifty builtins now exist, including
   `import` and `__structuredAttrs`, and `make eval-check` pins them at 10 of
   10 against a live `nix-instantiate`. What is still missing for a real
   package: `builtins.split` and `match`, which need a POSIX regex engine (a
   dependency, so an approval); `<nixpkgs>` search paths; and then enough of
   `lib` and `stdenv`. (`builtins.match`/`split` are DONE: `re` was approved
   and audited, see `docs/decisions/2026-08-02-ocaml-re-posix-regex.md`.)
2. **Port the evaluator to Python, Rust and Go.** Deliberately AFTER widening
   it in one language: the parser was ported once its eight bug classes were
   written down as a specification, and the same discipline applies here.

Done and no longer on this list: NAR serialization and `inputSrcs`, which was
the last unspecified corner of the format and the one gap in the `.drv` path
rule. See the State entry below.

## State

- [x] Thesis stated so it can fail.
- [x] The mathematics that constrains the design (`docs/theory.md`).
- [x] Signature drafted (`docs/spec/signature.md`).
- [x] Serialization derived EMPIRICALLY from real Nix, with golden files
      (`docs/spec/canonical.md`, `docs/spec/examples/`).
- [x] Real nixpkgs `lib` evaluates byte-identically (`make lib-check`), which
      is the first input to the evaluator not chosen to be evaluable. It found
      a bug on its first run: `substring` with a NEGATIVE length means "to the
      end", and `lib.removePrefix` is written that way.
- [x] `builtins.match` and `split`, on `re` (ocaml-re) with `Re.Posix.compile`
      for leftmost-longest. Audited and approved; the decision record covers
      the licence, the DFA-vs-backtracking difference from Nix's own engine,
      and the fact that Go gets POSIX ERE free while Python and Rust do not.
- [x] Fifty builtins, gated on BYTES rather than on values: each one drives a
      derivation attribute in `scripts/probe-builtins.nix`, so a subtly wrong
      answer moves a store path instead of hiding in a value. Found one real
      semantic error that way (`toString ./x` must NOT copy the file into the
      store, while `"${./x}"` must), and covers `import` and the second env
      encoding.
- [x] The EVALUATOR seam, in OCaml. `derivation` as a primop emitting the IR,
      with laziness on `Lazy.t` (blackholing free, since `Lazy.Undefined` is
      exactly "infinite recursion encountered") and string contexts as a
      three-case variant. `make eval-check` reads two real `.nix` files,
      evaluates them, and diffs the WHOLE resulting closure against a live
      `nix-instantiate`: 6 of 6 byte-identical. The dependency edges are not
      supplied by the caller as they are in the eDSLs; they are computed by the
      string-context homomorphism (`docs/abstractions.md` entry 18).
- [x] NAR, in four languages, written as a catamorphism over the filesystem
      object rather than as a directory walk (`docs/spec/canonical.md` section
      3, `docs/abstractions.md` entry 17). `make nar-check` diffs five source
      paths per implementation against a live `nix-store --add`, on a
      deliberately awkward tree, plus one derivation with a non-empty
      `inputSrcs` against `nix-instantiate` in BYTES and in path. That closes
      the half of the `.drv` references rule nothing we could build exercised.
- [x] An ATerm parser: recursive descent, no regexes. 805 of 805 real nixpkgs
      derivations round-trip BYTE-IDENTICALLY.
- [x] A real-vector harness: pull random nixpkgs packages, export their .drv
      closures, verify against them (`scripts/fetch-corpus.sh`).
- [x] Store path computation. Verified against real derivations: 2063 of 2063
      output paths across a 1458-derivation closure, and 1458 of 1458 `.drv`
      paths recomputed from the files' own bytes. The `.drv` path rule was
      WRONG until the transpiler found it (references were omitted); see
      `docs/abstractions.md` entry 10.
- [x] **The commuting square closes, in all four languages.**
      `make transpile-check`: 44 of 44 (11 intents times 4 implementations)
      printed to `.nix`, instantiated by real Nix, reproduce the golden `.drv`.
      This is the first oracle in the project where NIX chooses the answer
      rather than validating one we chose, and it found a bug four green gates
      had missed.
- [x] **The parser, in ALL FOUR languages, against real nixpkgs.**
      `make nixpkgs-parse`: every implementation reproduces the tree
      `nix-instantiate --parse` prints, on every file sampled, plus all 59
      hand-written vectors. OCaml scored 0 of 40 on its first run and needed
      eight distinct corrections, one of them a missing AST distinction rather
      than a printer bug; writing those eight down as a specification is what
      made the other three pass first time. See `docs/abstractions.md` entries
      13 and 14.
- [x] **The eDSL has a LIVE oracle.** `make differential` now describes the
      probe's five derivations through all four eDSLs and diffs them against
      bytes a real `nix-instantiate` produced moments earlier, rather than
      against a committed golden. A frozen golden cannot notice the oracle
      moving; `docs/abstractions.md` entry 16.
- [x] **Go's sum encoding decided and converted.** `impl/go/json.go` uses a
      sealed interface, like `impl/go/nix/`; verified byte-neutral, which is
      the only acceptable outcome for a type that decides store paths.
      `docs/decisions/2026-08-02-go-json-sealed-interface.md`.
- [x] **The SURFACE is tested against a real package.** `make worked-example`:
      one package using `stdenv.mkDerivation`, a nixpkgs dependency, an overlay
      and a fixed point, built through each language's `surface` and required
      to instantiate to the same store path as the hand-written Nix beside it.
      All four agree with the reference. The eleven intents pin the
      serialization; this pins the part the project's claim actually rests on.
- [x] **The two arrows compose.** `parse (emit e) = e`, up to three semantic
      no-ops, checked over the whole parser corpus by `make nixpkgs-parse`.
      This is what moved the corpus from the well-tested arrow to the
      under-tested one; the transpiler had been checked on eleven intents.
- [x] **The generated Go parser cannot go stale.** Go has no build step, so
      `impl/go/nix/grammar.go` is committed; `make check-parser` regenerates
      and diffs it in CI, because an un-regenerated `grammar.y` still compiles
      and still parses the OLD language.
- [x] **The transpiler in all four languages**: `ast`, `emit`, `surface` and
      the overlay monoid, with the one-way dependency on the IR that
      `docs/architecture.md` requires. No parser generator is a dependency of
      any of them, because the transpiler is only the arrow `EXPR -> .nix`.
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
- [x] **OCaml, the typed reference** (`impl/ocaml/`), and with it all four
      implementations. Abstract validated names make one invariant
      UNREPRESENTABLE rather than checked, visible as a missing error case.
- [x] **`make conformance` across all FOUR implementations**: 10 intents,
      Python, Rust, Go and OCaml, byte-identical to each other and to real Nix.
      This is the phase 2 exit test.
- [x] **`__structuredAttrs`**, the second env encoding, in all four
      implementations. It forces the first RECURSIVE type into the signature,
      and produced the sharpest typing-table row yet: a seven-case recursive
      sum is 7 lines in OCaml and Rust, one alias in Python, and ~40 lines plus
      a representable-but-invalid state in Go.

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
- [ ] The first real-world example.
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
- [x] CI matrix covering all four pinned toolchains.
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

| language | version | pinned in                    |
| -------- | ------- | ---------------------------- |
| Python   | 3.14.6  | `.python-version`            |
| Go       | 1.26.5  | `go.mod`                     |
| Rust     | 1.97.1  | `rust-toolchain.toml`        |
| OCaml    | 5.5.0   | `dune-project` / opam switch |

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

## Phase 4: the Nix language as a front-end, and round trips

Promoted from speculative. All four eDSLs exist and agree, so the IR is real;
what it cannot yet do is READ the ecosystem it is compatible with.

The concrete case that motivated this: `cnijfilter_2_80`'s `default.nix` is a
Nix EXPRESSION, and nothing here can parse it. Instantiating it with the pinned
Nix and running all four implementations over the resulting closure gives
1458 of 1458 round-tripped byte-identically and 2063 of 2063 output paths
reproduced. So the gap is exactly and only the evaluator: we can read every
derivation Nix produces, and no expression that produces one.

If the IR is genuinely the initial object, the Nix language is another
presentation of it, and two things follow:

- **A front-end.** Parse the Nix language, evaluate it, emit our IR. In ALL
  FOUR languages, decided in
  [`decisions/2026-08-02-nix-frontend-build-not-reuse.md`](decisions/2026-08-02-nix-frontend-build-not-reuse.md):
  Snix's evaluator is GPL-3.0, which would force the combined work to GPL-3.0
  and reverse the MPL decision, and a single shared evaluator behind four
  bindings would be ONE implementation with four call sites, so the conformance
  suite would be comparing it against itself.
- **Round trips.** Lower the IR back into whichever surface a person prefers.
  From the theory this is not a separate feature: every backend is an algebra,
  and a pretty-printer for language X is the algebra whose carrier is X's
  syntax. The uniqueness of the homomorphism out of the initial object is what
  makes "IR to any language" well posed at all.

Ordered by what each step buys, so the work can stop at any point and still
have delivered something:

- [x] **OCaml lexer and parser** (`impl/ocaml/nix/`): `ocamllex` plus
      `menhir`, conflict-free under `--strict`, printing in
      `nix-instantiate --parse` form and matching it on 59 differential
      vectors.
- [ ] **The other three lexers and parsers**, using each language's STANDARD
      tools, per AGENTS rule 1 and as
      Nix itself does (Flex plus Bison): `ocamllex`/`menhir`, `LALRPOP`,
      `goyacc`, `PLY`. A generator REPORTS an ambiguity where a hand-written
      parser silently picks an associativity, and the `!`-binds-looser-than-`+`
      trap in `docs/nix-internals.md` is exactly that failure. Deliverable on
      its own: a formatter and a linter.
- [x] **A parser differential oracle** (`docs/spec/nix-parse/vectors.tsv`,
      regenerated by `scripts/nix-parse-vectors.sh`). `nix-instantiate --parse` prints the
      AST back, fully parenthesized and partly desugared (`1 + 2 * 3` becomes
      `(1 + (__mul 2 3))`), so it pins tree SHAPE rather than "it parsed". Run
      each implementation over real nixpkgs `.nix` files and compare byte for
      byte. Two gotchas: `--parse` does STATIC SCOPE RESOLUTION and rejects
      free variables, and it prints a DESUGARED tree, so the printer has to
      reproduce the desugaring.
- [ ] **Evaluator core**: laziness using each language's STANDARD primitive
      (`Lazy.t`, `OnceCell`, `sync.Once`, and Python's thunk-and-memo idiom)
      rather than a hand-rolled one, plus blackholing, attribute sets,
      functions with default and `@`-patterns, `let`/`with`/`rec`, string
      interpolation, and the `builtins` a derivation actually reaches.
- [ ] **String contexts.** The mechanism by which interpolating a derivation
      into a string ADDS a dependency. This is what the eDSLs deliberately do
      not have (the caller writes the edge by hand), so it is the first place
      the front-end needs something the signature does not.
- [ ] **`derivation` as a primop** emitting our IR, checked by the existing
      conformance gate: for a given expression, our IR must equal what
      `nix-instantiate` writes, byte for byte. The gate already exists; only
      the input side is new.
- [ ] **Enough of nixpkgs `lib` and `stdenv`** to evaluate one real package.
      `cnijfilter_2_80` is the checked-in target because its closure is already
      known to verify: 1458 derivations, 456 of them `__structuredAttrs`, and
      fixed-output hashes in SRI, base-32, hex and `r:sha256`.
- [ ] **IR to Nix**, and the round-trip law: IR to Nix to IR is the identity ON
      THE QUOTIENT of `theory.md` section 4.

Honest caveats, since this is the part most likely to be underestimated:

- Emitting derivations is a FRACTION of what a Nix evaluator does. Laziness,
  the fixed-point module system, `import`, string contexts and the whole of
  nixpkgs' `lib` are the real surface, and a partial evaluator that handles
  `flake.nix` but not nixpkgs is of limited use.
- Round trips are only faithful up to the congruence in `theory.md` section 4.
  Expecting the original TEXT back is a category error; saying so up front
  avoids a disappointment later.
- ~~**Snix already has an evaluator.**~~ Comparison made and decided against
  reuse: GPL-3.0 against our MPL-2.0, and one shared evaluator would collapse
  four implementations into one. See the decision record. The cost of that
  choice is that this is now four evaluators, and it is accepted with eyes
  open.

Exit test: `nix-instantiate` and our front-end produce byte-identical `.drv`
files for the same expression, on a package with a real dependency graph.

## Phase 3 (conditional): the module system

Only if 0 to 2 succeed, and only with appetite for months rather than weeks.

A standalone, law-abiding module system. NOT an extension of the IR: a module
is a FUNCTION of the final config, and `theory.md` section 1 restricts the
signature to finite products. The module layer sits ABOVE the eDSL, evaluates
to a config, and host-language code then calls `derivation(...)`. Keeping that
boundary is the whole design.

This is the SECOND falsification test, and a sharper one than Go was. An option
type is existentially quantified over its value type. Rust reaches it with trait
objects, OCaml with first-class modules or GADTs, Python with a Protocol; Go has
no existentials and degrades to `any` plus runtime type assertions. Prediction
recorded IN ADVANCE, so it can be scored honestly: this is where Go breaks
rather than merely getting verbose. Go survived phase 2 because the IR is
first-order; an option type is not.

- [ ] Option types as n-ary merge algebras: check, merge, default, docs.
- [ ] Priorities as a lexicographic product of a min-semilattice with the value
      semilattice (`mkDefault`/`mkForce`/`mkOverride`), NOT as a deviation from
      the laws: it preserves them. See `theory.md` section 6.
- [ ] Definitions carry their SOURCE, so a conflict names both modules. This is
      the thing NixOS users actually complain about.
- [ ] Evaluation by STATIC dependency declaration and topological sort, not by a
      lazy knot: termination and a cycle error naming the two options, which is
      a real improvement over "infinite recursion encountered". The cost is
      dynamically computed dependency sets; the shape is applicative rather
      than monadic.
- [ ] The laws, property-tested, which Nix does not do: commutativity and
      idempotence per type (`listOf` and `unique` expected to FAIL, and marked
      so); `mkForce` absorption; empty set yields the declared default;
      idempotence of evaluation; and module order unobservable for any config
      built only from non-concatenating types. That last one is the same shape
      as the "env insertion order is not observable" law already in all four
      eDSL suites.
- [ ] The documented NON-law, with a countermodel test:
      `merge(A union B) != merge({merge A, merge B})`. The n-ary merge does not
      decompose into binary merges, because an intermediate result loses its
      priority. Any implementation that folds pairwise gets `mkForce` wrong.
- [ ] Generated docs and a JSON schema from the option tree, and a config diff.

Exit test: two modules that set the same option, one with `mkForce`, merge to
the same config regardless of import order, and the property suite is green with
the `listOf` and `unique` failures explicitly EXPECTED rather than absent.

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

- **2026-08-02** The probe described through all four eDSLs, making
  `make differential` a live oracle for the eDSL rather than only for the path
  computation. It caught a transcription error on its first run: one trailing
  newline on an indented string, which moved an input hash and therefore three
  output paths, and which no committed golden could have caught.

- **2026-08-02** Converted Go's JSON sum from a discriminant struct to a sealed
  interface. It had been held back as needing a decision, and the reason did not
  survive checking: the Go module has no tags and has never been released, so
  there was no published API to break. The finding it settles is that part of
  what entry 9 charged to GO was the cost of the encoding WE picked.

- **2026-08-02** A worked example that is not a conformance intent: a real
  package through `surface` in all four languages, compared against
  hand-written Nix by STORE PATH rather than by text. All four agree. Building
  it surfaced one thing worth fixing: `fix` inlined `base` once per mention
  instead of binding it, so the emitted source grew with the number of times an
  overlay read `prev`.

- **2026-08-02** Composed the two arrows for the first time: `parse . emit`.
  The retraction law went 197 of 300 to 1200 of 1200 and found three bugs the
  eleven conformance intents could never reach, one of them semantic (a float
  emitted as an integer changes what `/` means). It holds only up to three
  quotients, and each one turned out to name a node we invented that Nix does
  not keep. `docs/abstractions.md` entry 15.

- **2026-08-02** The parser landed in Python (PLY), Rust (LALRPOP + logos) and
  Go (hand-written scanner + goyacc). All three passed the nixpkgs corpus on
  the first run, which measures the specification rather than the ports: the
  eight rules were already written down. Entry 14 compares the four toolchains;
  the sharpest differences are that PLY matches FIRST rather than longest, only
  Python has lexer lookahead, only LALRPOP has no precedence declarations, and
  only Go has no lexer generator at all.

- **2026-08-02** Pointed the parser at real nixpkgs and it scored 0 of 40,
  having passed 59 hand-written vectors. Eight rules of Nix were wrong or
  missing, from attribute-set sort order to the fact that an escape-produced
  chunk takes no part in an indented string's dedenting. Now 5000 of 5000, with
  the corpus wired into CI the same way `make corpus` is: tree pinned by commit
  so failures reproduce, sample random so coverage keeps growing.

- **2026-08-02** The transpiler landed in all four languages and the commuting
  square closes 44 of 44. Two measurements came out of the ports. Emitted
  `.nix` is NOT comparable across languages, because a HOAS binder has no name
  until the surface invents one and the host's evaluation order decides which
  representative of the alpha-class you get; equality belongs at the IR, which
  is also what makes conformance linear in the number of languages. And Go has
  two encodings of a sum, of which `impl/go/json.go` picked the worse one;
  `docs/abstractions.md` entry 12 corrects entry 9 accordingly.

- **2026-08-02** The commuting square closed on 11 of 11 intents, and failed 10
  of 11 on its first run. The cause was ours: a `.drv` store path's fingerprint
  lists the paths the file REFERENCES, and we omitted them. 1458 of 1458 real
  nixpkgs filenames reproduce with the rule, 149 of 1458 without. Four green
  gates had missed it because each compared our computation against a name we
  had also computed. `make drvpath-check` now recomputes every corpus filename
  from its own bytes; `docs/abstractions.md` entry 10 records why the gap was
  structural rather than an oversight.

- **2026-08-02** The goal restated, and the mathematics that decides whether it
  is reachable. The end state is not "read nixpkgs"; it is that people WRITE
  Nix expressions in OCaml, Rust, Go or Python and the tool prints `.nix`, so
  the language stops being the barrier to NixOS.

  Sections 1 to 4 do not carry over unchanged, and pretending otherwise would
  be the error. A Lawvere theory is generated by a bare object, which is why
  "the host has records" sufficed for derivations. Nix expressions have
  BINDERS, and the exact generalization is a SECOND-ORDER ALGEBRAIC THEORY
  (Fiore and Mahmoud, MFCS 2010), which nLab defines as "a generalization of
  the notion of Lawvere theory to describe algebraic structures with variable
  binding", differing in that the generating object is EXPONENTIABLE. So the
  requirement moves from "finite products" to "function spaces for the
  generator", which all four languages have. Phase 2's risk was Go's missing
  sum types; this risk is lighter, because closures are the one thing Go has
  always had.

  Composability resolves into three different algebras, and conflating them is
  the standard mistake: `//` is a MONOID (not idempotent, not commutative);
  overlays are MIXINS in Cook and Palsberg's sense (OOPSLA 1989), a wrapper
  over a generator closed by a fixed point, composing as a monoid; and the
  module system is the n-ary merge of section 6. The trait or signature a user
  implements is the MIXIN, and that is where most of nixpkgs' composability
  actually lives.

  Recorded as `docs/theory.md` section 8 and `docs/architecture.md`. The
  correctness criterion is a COMMUTING SQUARE rather than a new test suite:
  print a term to `.nix`, instantiate with real Nix, and get the same `.drv`
  our evaluator produces. Every side of that square already exists in some
  form.

- **2026-08-02** The OCaml Nix parser landed: `ocamllex` + `menhir`,
  conflict-free under `--strict`, matching `nix-instantiate --parse` on 59
  differential vectors produced by the pinned Nix.

  Using a generator paid for itself immediately, which is the point of AGENTS
  rule 1. It reported a reduce/reduce conflict on `{`, because `{}` is an empty
  attribute set in expression position and an empty formal set before a `:`,
  and LR(1) cannot tell them apart until after the brace. Factoring the shared
  prefix into its own nonterminal defers the decision one token and makes the
  grammar LR(1); Nix's own parser.y has the same shape and declares `%expect 0`.
  It then reported a shift/reduce conflict on `,` in formals, fixed by using
  LEFT recursion exactly as parser.y:578 does. A hand-written parser would have
  resolved both silently and differently.

  The printer had to reproduce nine desugarings, every one of them measured
  rather than guessed, and several are not what a rule would predict: `*` and
  `/` and binary `-` become `__mul`/`__div`/`__sub` but `+` does not; `<`
  becomes `__lessThan` and `>=` becomes `(! (__lessThan a b))` but `!=` stays
  `!=`; `<nixpkgs>` becomes `(__findFile __nixPath "nixpkgs")`; floats print
  with C `%g` so `3.0` is `3` and `0.5e10` is `5e+09`; and a dotted binding
  expands into nested sets with siblings MERGED, so `{ a.b = 1; a.c = 2; }`
  becomes `{ a = { b = 1; c = 2; }; }`.

  Two vectors had to be dropped as not portable, and the reasons are worth
  keeping: `./relative` resolves at PARSE time against the source file's
  directory, so its expected output depends on where the probe lives; and a
  `#` comment needs a newline, which the one-line-per-vector format cannot
  carry.

- **2026-08-02** Phase 4's gate resolved: BUILD the Nix front-end, in all four
  languages, rather than reusing Snix. Two decisive reasons. Snix is GPL-3.0
  (verified at snix.dev/about), which would force any img-drv library linking
  it to GPL-3.0 and reverse the MPL-2.0 decision whose entire purpose was that
  people can embed these libraries; and a single shared Rust evaluator behind
  four bindings is ONE implementation with four call sites, so the conformance
  suite would compare it against itself. Snix also states its APIs are not
  stable. Recorded in
  `docs/decisions/2026-08-02-nix-frontend-build-not-reuse.md`.

  Found the oracle that makes four parsers tractable: `nix-instantiate --parse`
  prints the AST back, fully parenthesized and partly desugared, so it pins
  tree SHAPE and can be run over real nixpkgs files. That buys back what a
  parser generator's conflict detection would have given, and more, which is
  what justifies hand-written recursive descent plus Pratt in four languages
  instead of four different parser generators.

- **2026-08-02** `__structuredAttrs` supported in all four implementations, so
  conformance is now 11 intents rather than 10. The rules were measured before
  any code was written: the env is exactly `__json` plus one entry per output
  (456 of 456), the JSON is sorted-compact-unicode (456 of 456), output PATHS
  stay outside the JSON so the masking rule needs no special case (confirmed by
  2063 of 2063 recomputed paths), `outputs` inside the JSON follows the same
  OPTION rule as the flat encoding, and a fixed-output hash moves INSIDE the
  JSON. A new golden was generated with the pinned Nix rather than written by
  hand (`scripts/probe-structured.nix`).

  It forces the first RECURSIVE type into the signature. Everything until now
  was a product of primitives and lists of them; a JSON value is a least fixed
  point. Still first-order and still algebraic, so `theory.md` section 1
  survives, but the restriction now reads "and least fixed points of those".

  And it produced the cleanest measurement in the project. Earlier typing-table
  rows compared how an invariant is CHECKED; this one compares how a TYPE is
  spelled. Seven-case recursive sum: 7 lines in OCaml and Rust with exhaustive
  matching, one alias in Python, and in Go a struct with a discriminant plus
  seven fields plus seven constructors, in which `JSONValue{}` is a
  representable value of an invalid shape. That is what "no sum types" costs,
  and it took a recursive sum to make it visible.

- **2026-08-02** Verified against a real, awkward nixpkgs package rather than
  our own examples: `cnijfilter_2_80`, a 32-bit unfree Canon printer driver.
  Its `default.nix` is a Nix EXPRESSION and nothing here can parse it, which is
  the honest limit; the closure it INSTANTIATES to verifies completely, in all
  four languages: 1458 of 1458 round-tripped byte-identically and 2063 of 2063
  output paths reproduced, 1458 of 1458 already canonical.

  So the gap is exactly and only the evaluator, which is why Phase 4 is
  promoted out of "speculative" and to the top of Now. That closure also widened
  the corpus: 456 of its 1458 derivations use `__structuredAttrs`, and it
  contains the first HEX-written fixed-output hash seen anywhere here (1 of
  464), alongside SRI, base-32 and `r:sha256`. `system` is `i686-linux`, and it
  declares `outputs = [ "out" ]` explicitly, which is the case a defaulted
  model cannot express.

- **2026-08-02** OCaml landed, and with it the phase 2 exit test: ten intents,
  FOUR implementations, byte-identical to each other and to what real Nix
  emitted. The portability claim is now as well supported as this kind of claim
  can be.

  OCaml is the far end of the typing axis, and exactly one row of the table
  moves there. `Name.t` is abstract with a validating constructor, so an
  invalid name is not a value that can exist, and `Edsl.error` has no
  `Invalid_name` case where the other three do. The receipt for "unrepresentable
  rather than checked" is the missing case.

  What does NOT move, now checked across the whole axis rather than conjectured:
  "outputs non-empty" and "the recorded paths match this derivation's own hash"
  are runtime checks in all four. A type system distinguishes what you
  CONSTRUCT; a verifier is still required for what you COMPUTE.

  Third language-specific trap, completing a pattern with Rust's release-only
  shift and Go's nil-slice conflation: a custom OCaml operator takes its
  precedence from its FIRST CHARACTER, so `&%` sits below `^%` and the sha256
  round parsed into the wrong tree with no warning. The FIPS 180-4 vectors
  caught it on the first run, which is the argument for writing the vectors
  before the code. See `docs/abstractions.md` entry 8.

- **2026-08-02** Corrected `theory.md` section 6, which blamed the wrong thing.
  Priorities do NOT break the module system's algebra: keeping only the
  minimum-priority definitions is a lexicographic product of a min-semilattice
  with the value semilattice, and it preserves commutativity, associativity and
  idempotence. What actually leaves the semilattice is the TYPES, `listOf`
  (concatenation: associative, not commutative, not idempotent) and `unique`
  (errors on two EQUAL definitions, so not idempotent).

  Two further corrections. The merge is genuinely N-ARY and does not decompose
  into binary merges, because an intermediate result loses its priority, so
  `merge(A union B) != merge({merge A, merge B})` and any pairwise fold gets
  `mkForce` wrong. And the knot is LAZINESS, not Kleene iteration on a cpo:
  Knaster-Tarski gives existence for monotone maps, Nix gives "infinite
  recursion encountered".

  Every number was verified against nixpkgs master rather than recalled, since
  the previous text was wrong from memory: priorities at `lib/modules.nix`
  1569-1574, the `min` fold at 1433, order defaults at 1605-1606,
  `mergeEqualOption` for the scalars at `lib/types.nix` 376/399/482/519, and
  `mergeOneOption` at `lib/options.nix:451`. One correction to the question as
  asked: `imports` depending on `config` is NOT statically forbidden, it fails
  as infinite recursion with an `addErrorContext` hint (`modules.nix:269`).

  Phase 3 rewritten accordingly, and it now records a PREDICTION in advance:
  an option type is existentially quantified over its value type, Go has no
  existentials, so phase 3 is where Go breaks rather than merely getting
  verbose. Go survived phase 2 because the IR is first-order; an option type
  is not.

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
