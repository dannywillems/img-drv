# Encode Go's JSON sum as a sealed interface, not a discriminant struct

**Date:** 2026-08-02
**Status:** accepted

## The question

`impl/go/json.go` encoded a seven-case sum as a struct with a `Kind`
discriminant and one field per case. `impl/go/nix/ast.go` later encoded a
twenty-one-case sum as a **sealed interface**: an interface with an unexported
marker method, which only types in the defining package can implement.

Two encodings of the same thing, in the same module, chosen months apart. This
records which one is right and why the first one was written.

## Decision

Use the **sealed interface**. `impl/go/json.go` is converted; `JSONValue`
becomes an interface with seven implementing types.

## Why

Go has exactly two ways to write a sum. They are not equivalent.

| property                           | discriminant struct       | sealed interface | OCaml/Rust variant |
| ---------------------------------- | ------------------------- | ---------------- | ------------------ |
| invalid combinations representable | **yes**                   | no               | no                 |
| a zero value that is not any case  | `JSONValue{}`             | `nil`            | none               |
| exhaustiveness checked             | no                        | no               | **yes**            |
| cost for N cases                   | N fields + N constructors | N marker methods | N                  |

The decisive row is the first. `JSONValue{Kind: JSONString, Int: 7}` was a
value the type system permitted and the code had to be trusted not to build.
With a sealed interface that combination cannot be written down at all.

So part of what `docs/abstractions.md` entry 9 charged to **Go** was really the
cost of the **encoding we picked**. The honest measurement is that Go's gap
from a variant is TWO things, not three: no exhaustiveness checking, and a
`nil` inhabitant. Neither costs expressiveness; both cost the compiler's help.

## Why the worse one was written first

Worth recording, because the reasoning was not stupid and would recur.

At **seven** cases both encodings are writable, and the discriminant struct
reads as the more explicit of the two: the cases are visible in one place as
constants, and the constructors are one line each. At **twenty-one** cases only
one is writable at all, because the struct would carry twenty-one mostly-nil
fields on every node.

Having written the twenty-one-case version, the comparison at seven becomes
obvious. That is the general shape: a design that is merely awkward at small N
is often WRONG at small N too, and the way to find out is to build the bigger
instance rather than to argue about the smaller one.

## Costs accepted

- **A breaking API change**, in principle. In practice free: the Go module has
  **no tags**, has never been released, and the call sites are four files.
- `v.JSON()` and `v.IsString()` were methods on a struct and cannot be methods
  on an interface without seven implementations each. They become the functions
  `JSON(v)` and `AsString(v)`. `AsString` returns `(string, bool)`, which is
  strictly more useful than the old `IsString`: the discriminant encoding could
  not hand back the value without a second field access that might not be the
  meaningful one.
- Every type switch still needs a panicking `default`. Go will not tell us a
  case is missing, and a missing case here would emit a syntactically valid but
  WRONG JSON document, therefore a wrong store path: the "right shape, wrong
  identity" failure `docs/spec/store-paths.md` warns about. A loud panic is the
  best this encoding allows.

## How it was verified as byte-neutral

An encoding change to a type that decides store paths has exactly one
acceptable outcome: nothing moves. Checked before and after:

- `make conformance`: 11 intents, 4 implementations, byte-identical to Nix;
- 2063 of 2063 output paths recomputed across a 1458-derivation real closure,
  456 of them `__structuredAttrs` and therefore routed through this file;
- 1458 of 1458 derivations round-trip byte-identically.

## Revisit if

Go gains exhaustiveness checking for type switches over sealed interfaces, in
which case the remaining gap from a variant closes to one item (`nil`) and the
comparison table in `docs/abstractions.md` entry 12 needs redoing.
