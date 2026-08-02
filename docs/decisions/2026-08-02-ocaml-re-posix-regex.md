# Use ocaml-re for `builtins.match` and `builtins.split`

**Date:** 2026-08-02
**Status:** accepted

## The question

`builtins.match` and `builtins.split` were the last two builtins blocking real
nixpkgs `lib`. They need POSIX extended regular expressions, which OCaml's
standard library does not provide, so this is the project's first non-toolchain
runtime dependency in any implementation.

The alternative was hand-rolling an engine. Earlier notes said a subtly
different regex engine is worse than none, because `lib` parses versions and
escapes shell arguments with these and a wrong answer becomes a wrong store
path. This records why the dependency won and what it costs.

## Decision

Add **`re >= 1.14.0`** (ocaml-re) to `impl/ocaml`, in the `img_drv_nix`
library only.

Use **`Re.Posix.compile`**, never `Re.compile`. See the footgun below.

## Why a dependency rather than 300 lines

The claim "a subtly different engine is worse than none" cuts against
hand-rolling, not for it. A hand-written engine is exactly the thing most
likely to be subtly different, and the difference would surface as a wrong
store path in a package nobody tested rather than as a compile error.

Concretely, the parts that are easy to get wrong and that we would have to get
right unaided: POSIX **leftmost-longest** submatch selection (not the
leftmost-first rule that PCRE, Python's `re`, and Rust's `regex` all use),
bracket expressions with named classes, interval expressions `{n,m}`, and the
interaction of alternation with capture-group numbering. Getting leftmost-
longest wrong is invisible on most patterns and decisive on
`(a|ab)(c|bcd)` against `abcd`.

## What the audit found

Verified against NVD, OSV.dev, the GitHub Advisory Database, and an exhaustive
read of all 22 entries in `ocaml/security-advisories`:

| criterion       | finding                                                       |
| --------------- | ------------------------------------------------------------- |
| version         | 1.14.0, released 2025-09-18                                    |
| licence         | `LGPL-2.1-or-later WITH OCaml-LGPL-linking-exception`           |
| CVEs            | **none**, in any of the four databases                         |
| C code          | **none**; pure OCaml                                           |
| runtime deps    | **none** beyond the compiler and dune                          |
| maintenance     | active, under the official `ocaml/` org, ~396 reverse deps      |
| algorithm       | lazy **DFA**, linear in the length of the subject              |

## Licence: why the linking exception is the load-bearing part

The project is MPL-2.0. Plain LGPL-2.1 in a statically linked OCaml program is
awkward, because OCaml links statically by default and the LGPL's relinking
requirement is hard to satisfy for a native binary.

ocaml-re carries the **OCaml LGPL linking exception**, whose text grants
permission to "link, statically or dynamically, a work that uses the Library
with a publicly distributed version of the Library". That is precisely the case
here. Modifications to `re` itself would remain copyleft; we make none.

## It is safer than the engine Nix itself uses

Nix implements these builtins with `std::regex` under `std::regex::extended`
(verified in `NixOS/nix`, `src/libexpr/primops.cc`), which is a **backtracking**
engine. Nix's own source catches the resulting resource exhaustion:

```cpp
} catch (std::regex_error & e) {
    if (e.code() == std::regex_constants::error_space) {
        // limit is _GLIBCXX_REGEX_STATE_LIMIT for libstdc++
        state.error<EvalError>("memory limit exceeded by regular expression '%s'", re)
```

That comment is direct evidence Nix hits libstdc++'s backtracking state limit
in practice. ocaml-re builds a DFA lazily and is linear in the subject length,
with no backreferences or lookaround (their absence is the price of the
guarantee). So on the denial-of-service axis this is a strict improvement.

The consequence to be honest about: **we may succeed where Nix errors.** A
pathological pattern that exhausts libstdc++ will simply match here. That is a
divergence, and it is in the direction of doing more work rather than producing
a different answer.

## The footgun, written down because it is silent

`Re.compile (Re.Posix.re s)` parses ERE **syntax** while keeping ocaml-re's own
**non-POSIX match semantics**. Only `Re.Posix.compile` applies `Re.longest` and
gives leftmost-longest. From `lib/posix.mli`:

```
(** [compile r] is defined as [Core.compile (Core.longest r)] *)
val compile : Core.t -> Core.re
```

Both spellings compile and both match. The wrong one gives different capture
groups on exactly the patterns where POSIX differs from everyone else, which is
the hardest kind of bug to notice.

Two smaller ones, also recorded rather than discovered later:

- POSIX ERE has **no non-capturing group**. Anchoring a pattern by wrapping it
  in `^(?:...)$` does not parse as ERE at all, and `^(...)$` would shift every
  capture index by one. `Re.whole_string` is the combinator that anchors
  without touching group numbering. `builtins.match` needs it, because Nix uses
  `std::regex_match` (whole string) and not `regex_search`.
- A group that did not participate must be **null**, not the empty string.
  `lib` branches on that distinction.

## Residual risk: submatch semantics, not safety

`posix.mli` documents four deviations from POSIX, tested against glibc and
Solaris, and warns that "the behavior of this library in these four cases may
change in future releases". Two of the four are cases where ocaml-re follows
the standard and glibc does not, and glibc is what `std::regex` implementations
are usually compared against. So those are the likeliest divergence points.

This is handled the way everything else in this project is handled: by
**differential testing against the pinned Nix**, not by assumption.
`scripts/probe-regex.nix` drives leftmost-longest, non-participating groups,
bracket classes, interval expressions, zero-width matches, and the `split`
alternation shape through derivation attributes, so a disagreement moves a
store path. If a future `re` changes one of the four cases, that gate fails.

## The dependency is scoped, and the IR core stays clean

`re` is a dependency of `img_drv_nix` (the Nix front end), not of `img_drv`
(the IR core). That split already existed, because the front end needs
ocamllex and menhir. The IR core, which every other implementation and every
conformance gate builds on, keeps its zero-dependency promise.

## This does not settle the other three languages

The per-language cost is not uniform, which is itself worth recording:

- **Go**: free. `regexp.CompilePOSIX` is in the standard library, is RE2
  (also a DFA, also linear), and is leftmost-longest.
- **Python**: the stdlib `re` is leftmost-**first** PCRE-style. It parses most
  ERE syntax but selects different submatches, so it is not a drop-in.
- **Rust**: the `regex` crate is leftmost-first with no POSIX mode.

So three of the four implementations will each need their own decision, and
only one of them is already answered by the standard library. That asymmetry is
the same shape as the parser-generator table in `docs/abstractions.md` entry 14:
what a language gives you for free is not distributed evenly, and the gaps are
where the interesting work is.

## Revisit if

- ocaml-re changes any of the four documented POSIX deviations (the regex gate
  fails loudly if so);
- OCaml's standard library gains a POSIX ERE engine (it will not soon);
- the project ever wants ONE regex implementation shared across four languages,
  which would mean the same argument as the shared-evaluator decision and the
  same answer: four implementations is the point.
