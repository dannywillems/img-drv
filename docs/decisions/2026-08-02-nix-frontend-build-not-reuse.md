# Build the Nix front-end, in all four languages, rather than reusing Snix

**Date:** 2026-08-02
**Status:** accepted

## The question

`PLAN.md` phase 4 gated itself: "Snix already has an evaluator. Reusing it may
beat writing one, and that comparison should be made BEFORE any parser is
started." This records the comparison and the decision.

## Decision

Implement the Nix language front-end ourselves, in **all four** languages, and
do not link Snix.

## Why, in order of decisiveness

### 1. The licences are incompatible with the point of this project

Snix is GPL-3.0 ("Snix is developed as a GPLv3-licensed free software project",
<https://snix.dev/about/>, checked 2026-08-02). This repository is MPL-2.0, and
[the licence decision](2026-08-01-licence-mpl-2.0.md) chose MPL specifically so
that **people can embed these libraries in their own stacks under any licence**.

Linking a GPL-3.0 evaluator into an img-drv library would make the combined work
GPL-3.0 and destroy exactly the property MPL was chosen for. That is not a
detail to be worked around; it is the licence decision being reversed by the
back door.

### 2. Reusing one Rust evaluator gives one implementation, not four

The entire thesis is that the same build intent, expressed through one
signature, produces byte-identical IR from four languages spanning the typing
axis. A single shared Rust evaluator behind four thin bindings is **one**
implementation with four call sites, and the conformance suite would compare it
against itself.

The front-end is the largest and most complex part of the project, so it is also
where the portability claim is most worth testing. Outsourcing it would be
outsourcing the experiment.

### 3. Snix is explicitly not stable

"None of our current APIs should be considered stable in any way", and there is
"no full-featured drop-in replacement for Nix" yet. Depending on an unstable
API for the largest component would import that instability into a project whose
subject is reproducibility.

## Costs accepted

- **This is the largest piece of work in the project by a wide margin**, and
  now it is four times over. Emitting derivations is a fraction of what a Nix
  evaluator does: laziness, string contexts, `import`, the module system's fixed
  point, and the whole of nixpkgs `lib`.
- **A partial evaluator is of limited use.** One that handles `flake.nix` but
  not nixpkgs does not read the ecosystem, which was the entire motivation.
- **Four parsers can drift.** Mitigated below, and the mitigation is stronger
  than the usual one.
- We give up whatever Snix has already solved, knowingly.

## How the four are kept honest

`nix-instantiate --parse` prints the parsed AST back, fully parenthesized and
partly desugared:

```
1 + 2 * 3   =>  (1 + (__mul 2 3))
-1          =>  (__sub 0 1)
x: y: x y   =>  (x: (y: (x y)))
```

That is a **differential oracle for a parser**, of the same kind
`make differential` already is for derivations, and it pins tree SHAPE rather
than merely "it parsed". Each implementation parses a real `.nix` file, prints
in that format, and must match the pinned Nix byte for byte. Run over nixpkgs,
that is tens of thousands of real vectors, which is a far better guarantee than
any single implementation's test suite.

This was not a prediction that aged well or badly, it was measured. The OCaml
parser passed 59 hand-written vectors and then scored **0 of 40** on real
nixpkgs files. Eight distinct rules of Nix were wrong or missing; the list is
in `docs/abstractions.md` entry 13. It is now 5000 of 5000, and `make
nixpkgs-parse` runs in CI on a fresh random sample of a commit-pinned tree.

The argument for writing our own front-end therefore comes with a warning it
did not originally carry: a parser that passes a curated vector set is not
close to done, and the gap is not in the exotic corners. It is in attribute
ordering, string chunking and path resolution, which every real file uses.

Two things to know about the oracle before relying on it:

- `--parse` performs **static scope resolution** and fails with "undefined
  variable" on a free variable, so probes have to be well-scoped.
- It prints a DESUGARED tree (`*` becomes `__mul`, unary minus becomes
  `__sub 0`), so our printer has to reproduce the desugaring, not just the
  parse.

## On parser technique: the standard tools, per language

Each implementation uses its language's STANDARD lexer and parser generator,
which is what AGENTS rule 1 requires ("a parser generator (menhir, and
equivalents elsewhere) for anything larger such as the Nix language") and what
Nix itself does: `parser.y` is Bison and `lexer.l` is Flex.

| language | lexer                                    | parser    |
| -------- | ---------------------------------------- | --------- |
| OCaml    | `ocamllex`                               | `menhir`  |
| Rust     | LALRPOP's own lexer, or `logos`          | `LALRPOP` |
| Go       | hand-written scanner in the goyacc idiom | `goyacc`  |
| Python   | `PLY` (`lex`/`yacc`), the classic port   | `PLY`     |

An earlier draft of this document argued for hand-written recursive descent
with Pratt precedence climbing, on the grounds that four generators mean four
grammars that can drift. That was wrong twice over. It is a deviation from a
rule this repository adopted for a reason, and the reason applies here more
than anywhere: the grammar being parsed is the largest in the project. And the
drift argument is backwards. A GENERATOR reports a conflict when the grammar is
ambiguous; a hand-written parser silently picks an associativity. The `!`
precedence trap recorded in `docs/nix-internals.md`, where `!` binds looser
than `+`, is exactly the sort of thing a hand-written parser gets wrong quietly
and an LR table refuses to accept.

Drift between the four is a real risk and is handled where it belongs, in
testing, not by weakening each parser. The twelve-level precedence table is
transcribed from `parser.y:208-219` into each generator's own declaration
syntax, and the differential oracle above checks the RESULT rather than the
transcription.

The same principle governs the evaluator. Laziness uses each language's
standard primitive rather than a hand-rolled thunk: OCaml's `Lazy.t`, Rust's
`OnceCell`/`LazyCell`, Go's `sync.Once`, and Python's own thunk-and-memo
idiom. Nix's semantics are call-by-need with update-in-place, and every one of
these gives exactly that, tested rather than reimplemented.

### Dependencies this implies

`menhir`, `LALRPOP`, `goyacc` and `PLY` are new dependencies and are subject to
the approval policy in `dependencies.md`. They are the standard, long-lived
tools of their ecosystems, they are build-time only (each generates source that
is compiled normally), and none appears in the runtime dependency set of the
published libraries. `goyacc` in particular is part of `golang.org/x/tools`
rather than a third-party project.

## Revisit if

- Snix relicenses to something MPL-compatible AND stabilises its API, in which
  case it becomes a reasonable fifth implementation to differentially test
  against, though still not a replacement for the four;
- the differential oracle turns out not to cover a class of parse the
  implementations disagree on, in which case the gap is in the corpus rather
  than in the parsers, and the corpus is what should grow;
- the evaluator (as opposed to the parser) proves genuinely intractable in Go,
  which would be a real result and belongs in `theory.md` rather than being
  worked around.

## Sources

- Snix project status and licence: <https://snix.dev/about/>
- Snix source: <https://git.snix.dev/snix/snix>
- Nix grammar and precedence: `NixOS/nix` at `a86a3638`,
  `src/libexpr/parser.y:208-219`
