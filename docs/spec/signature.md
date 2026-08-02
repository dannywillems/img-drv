# The signature

**Status:** draft. This is the first-order algebraic signature every eDSL
presents. It is deliberately smaller than Nix's language, because it describes
DERIVATIONS, not a way of computing them.

The constraint from [`../theory.md`](../theory.md) section 1: sorts and
operations may use only products, finite sums, lists and primitives. Anything
requiring more is a red flag, and Go is where it will show first.

## Sorts

| sort | is | notes |
| --- | --- | --- |
| `String` | UTF-8 byte string | see the escaping caveat in `canonical.md` |
| `OutputName` | `String` | e.g. `out`, `dev`, `lib` |
| `StorePath` | `String` | absolute, under the store root |
| `System` | `String` | e.g. `x86_64-linux` |
| `HashAlgo` | one of `sha256`, `sha512`, `sha1`, `md5` | a finite sum |
| `Derivation` | the term being built | |
| `DrvRef` | reference to another `Derivation`, plus the outputs needed | a product |

Note what is absent: no functions, no laziness, no recursion, no arithmetic, no
conditionals. Those belong to the HOST language. The signature describes the
result of computing, not the computation. This is the whole reason the
embedding is cheap.

## Operations

```
derivation :
    name    : String
  , system  : System
  , builder : String
  , args    : [String]
  , env     : [(String, String)]
  , outputs : Option [OutputName]       -- declaration order is significant,
                                        -- and ABSENT differs from ["out"]
  , inputDrvs : [(DrvRef, [OutputName])]
  , inputSrcs : [StorePath]
  , fixedOutput : Option (HashAlgo, String)
  -> Derivation
```

Everything is a product of primitives and lists of them. `Option` is a
two-case finite sum, which Go models with a nullable pointer or an explicit
`present bool` field. Nothing here needs generics.

## Invariants

To be enforced by every implementation, and property-tested:

1. `outputs` is non-empty; `out` is conventional but not required.
2. Output names are unique.
3. Env keys are unique. Duplicate keys are a construction error, not a
   last-one-wins merge, because a merge would make the term depend on
   insertion order and break the quotient in `theory.md` section 4.
4. `name` must be a valid store path name.
5. A fixed-output derivation has exactly one output.
6. The derivation's own outputs appear as env variables, one per output name,
   holding that output's path.
7. `outputs` is an OPTION, and the two cases are distinguishable in the bytes:
   when present, an `outputs` env variable lists the names in DECLARATION
   order, space separated, while the serialised outputs list is sorted by name
   ([`examples/multi.drv`](examples/multi.drv)); when absent, there is no such
   variable and the single output is `out`
   ([`examples/hello.drv`](examples/hello.drv)). `Some ["out"]` and `None` are
   therefore different derivations with different store paths, and both occur
   in real nixpkgs. See `canonical.md` section 1.7 for the counts.
8. `system` and `builder` appear as env variables equal to their own fields,
   and `args` does not appear in env at all.

## What is deliberately not here

- **Anything that computes.** No `map`, no string interpolation, no imports.
  The host language does that, and the eDSL receives the results.
- **`stdenv` and the nixpkgs conventions.** Those are a library ON TOP of
  derivations, and reimplementing them is not in scope at any phase.
- **Content-addressed derivations.** Experimental in Nix; revisit later.

## Open

- [ ] Exact validity rules for `name` as a store path component. The predicate
      currently enforced (non-empty, at most 211 characters, not `.` or `..`,
      no leading `.`, characters drawn from `[A-Za-z0-9+._?=-]`) accepts every
      name in the real corpus, which shows it is not too strict but not that it
      is not too permissive.
- [x] `env` is a MAP in the host language, sorted at serialization time. That
      makes invariant 3 free rather than a check, and the wire order is
      recovered by sorting, so nothing is lost.
- [x] The outputs needed belong to the EDGE, not to the reference: depending on
      `dev` alone is common, and two dependents of the same derivation
      routinely need different outputs.
- [ ] `__structuredAttrs`: the second env encoding (`canonical.md` section
      1.8), which 1223 of 2516 real derivations use and this signature cannot
      currently express.
