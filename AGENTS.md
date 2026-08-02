# AGENTS.md

Instructions for anyone, human or agent, working in this repository. Read this
before the code. The rules below are not style preferences: each one was
learned by getting something wrong here, and the cost of relearning them is
measured in hours.

## What this project is

A portable, content-addressed IR for reproducible build descriptions, with thin
embedded DSLs in Python, Go, Rust and OCaml. The thesis, the mathematics and
the plan live in [`README.md`](README.md), [`docs/theory.md`](docs/theory.md)
and [`PLAN.md`](PLAN.md).

**Tasks come from [`PLAN.md`](PLAN.md).** Take the top item of `Now`. When
something lands, update `PLAN.md` in the same commit and add a line to its plan
log.

## The rules

### 1. Never parse with regexes

Use a lexer and a real parser: a hand-written recursive descent for a grammar
as small as ATerm, a parser generator (menhir, and equivalents elsewhere) for
anything larger such as the Nix language.

This is not theoretical. A regex-based reader of derivations passed 12 of 12
hand-written examples and then failed 323 of 403 real ones, because real
derivations contain escaped quotes inside values, store paths embedded in
unrelated environment variables, and `],[` sequences inside strings. The
replacement, [`scripts/aterm.py`](scripts/aterm.py), round-trips 805 of 805
real derivations byte-identically.

### 2. Verify against REAL vectors, never only your own examples

Examples you write test the cases you already thought of. That is precisely
the set of cases that are already right.

`make corpus` pulls random packages from nixpkgs, exports the `.drv` closure of
each, and checks every store path in it. CI runs it on every push with a fresh
random sample, so it keeps finding cases a fixed corpus never would.

Every time hand-written examples and real derivations have disagreed in this
repository, the hand-written ones were wrong.

### 3. Do not claim something is verified until it is verified

`docs/spec/store-paths.md` said "solved and verified" on the strength of
examples, and was wrong by 323 cases. The correction is still in the file's
history on purpose.

State what was checked, against what, and how many. "12 of 12 hand-written" and
"1259 of 1259 real" are different claims, and only the second one means the
implementation works.

### 4. Everything is typed, as strongly as the language permits

- **Python**: full annotations, `mypy --strict` clean, no `Any` in the public
  surface, frozen dataclasses over dicts.
- **Go**: no `any` in the signature, named types over bare `string`, sums
  modelled explicitly.
- **Rust**: `deny(warnings)`, newtypes over `String` aliases, `enum` for sums,
  no `unwrap` outside tests.
- **OCaml**: abstract types in `.mli`, variants for sums, warnings as errors.

The point of four implementations is to span the typing axis. That only means
something if each is as typed as its language allows.

### 5. Latest stable toolchains, pinned, and running in containers

Python 3.14.6, Go 1.26.5, Rust 1.97.1, OCaml 5.5.0. Tool IMAGES are pinned by
DIGEST in [`scripts/pins.env`](scripts/pins.env), including the Nix oracle,
because a tag is a mutable pointer and a moving oracle cannot distinguish "we
broke it" from "upstream changed". A version moves in its own commit with a
readable diff.

Nothing is installed on the host. Every target runs in a pinned container, so
a laptop and a CI runner execute the same bytes, and `actions/setup-python`
does not appear in any workflow.

### 6. Every check is a Makefile target

CI never invokes a raw tool. If CI needs a check, add the target first, then
call it. A local run and a CI run must be the same run.

### 7. Each implementation is a reusable LIBRARY

Not a script. PyPI, opam, crates.io and a Go module, each semver'd with a
documented public surface. Other people embedding these is the point of the
project, and it is why the licence is MPL-2.0 rather than GPL: see
[`docs/decisions/2026-08-01-licence-mpl-2.0.md`](docs/decisions/2026-08-01-licence-mpl-2.0.md).

The bytes are the artifact. A change to what a serializer emits changes the
identity of every build that uses it, so it is a MAJOR version bump, never an
implementation detail. `docs/spec/` is CC0 so that independent implementations
need no permission.

### 8. Write down what you learned, where it will be found again

- `PLAN.md` for what and when.
- `docs/decisions/` for why, with costs accepted and a revisit condition.
- `docs/spec/` for anything that defines bytes. Changing bytes is a breaking
  change.
- `docs/theory.md` for a result that FORCES a design constraint. Normative, and
  meant to stay small.
- `docs/abstractions.md` for which structure a piece of code realizes, its
  laws, and where each law is tested. **Append an entry whenever a feature
  larger than a refactor lands.** A structure is a specification: every law it
  obeys is a property the code owes, and the entries have already found a real
  over-claim and a real bug.

## Traps already paid for

Do not rediscover these.

- **Two orderings live in one derivation.** The serialized `.drv` sorts
  `inputDrvs` by store PATH; the form that gets hashed re-sorts them by the
  input's HASH. A textual substitution preserves path order and silently
  breaks every derivation with more than one input, which is why single-input
  examples hid it.
- **Mask your own outputs, not your inputs'.** Computing a derivation's own
  output paths masks them; using a derivation as someone's input does not.
- **A fixed-output derivation has two different hash strings.** The one that
  computes its own path ends at a colon; the one identifying it as an input
  appends the output path. Confusing them is invisible until something depends
  on a fetch, because the fetch's own path stays correct. This accounted for
  all 145 downstream failures in the first real corpus.
- **`r:sha256` takes a different path scheme entirely**, the `source` kind with
  the declared hash used directly. Exactly one derivation in a 226-derivation
  closure exercised it.
- **Nix base-32 is not RFC 4648**, and the sha256 is XOR-folded to 20 bytes
  rather than truncated.
- **The env `outputs` variable keeps DECLARATION order** while the outputs list
  is sorted by name, so one file carries two orderings of the same list.

## Running things

```sh
make spec-check      # recompute every golden store path from text alone
make differential    # instantiate a probe with the PINNED Nix, compare paths
make corpus N=10     # pull N random nixpkgs packages and verify against them
make python-lint     # ruff + mypy --strict
make python-test     # pytest, including the property-based laws
make python-build    # wheel + sdist, twine-checked
make lint-shell
```

**Docker is the only prerequisite.** Not Nix, not Python, not shellcheck: each
target runs in a pinned image. `make differential` is the sharpest gate, since
it compares against real Nix rather than against ourselves.
