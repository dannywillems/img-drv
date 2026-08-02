# img-drv (OCaml)

A portable, content-addressed IR for reproducible build descriptions. Describe
a build, compute its store paths, serialize it, and get bytes identical to what
Nix emits.

This is the **typed reference**, and the last of the four. Where Go asked
whether the signature can be expressed with almost no type system, OCaml asks
the opposite question: how much of the specification can a type system make
**unrepresentable** rather than merely checked?

**Status:** all eleven golden intents reproduce Nix's bytes, including each
derivation's own `.drv` store path. `make conformance` shows Python, Rust, Go
and OCaml emitting identical bytes.

## Install

```sh
opam install img_drv
```

OCaml 5.5.0. **Zero runtime dependencies**, like Python and Go.

## Describe a build

```ocaml
open Img_drv

let hello =
  match Types.Name.of_string "hello" with
  | Error e -> failwith e
  | Ok name ->
      Edsl.derive
        (Edsl.build ~name ~system:"x86_64-linux" ~builder:"/bin/sh"
           ~args:["-c"; "echo hi > $out"] ())
```

`hello.path` is `/nix/store/76w21n1f03fs5kw8fnffphx7qrqffw6r-hello.drv` and
`Edsl.output hello "out"` is
`/nix/store/mjs27ix6ig2bkbi3s3sm470vrv4lf7ic-hello`, both known before anything
is built.

## The result: one row moves

Every other implementation validates the derivation name inside its
constructor and carries an error case for the failure. OCaml does not, and the
difference is visible in the error type itself:

```ocaml
type error =
  | Empty_outputs
  | Duplicate_outputs of string list
  | Fixed_needs_one_output of string list
  | Reserved_env_keys of string list
  | No_such_output of {drv : string; wanted : string; have : string list}
  | Invalid_hash of string
  (* and no Invalid_name, because there is no such value *)
```

`Types.Name.t` is **abstract**, and the only way in is `Name.of_string`, which
validates. By the time `derive` is called, an invalid name is not a value that
can exist. Python, Rust and Go all carry an `Invalid_name` case; here the case
would be unreachable, so it is absent.

That is the whole point of the exercise, made concrete: an abstract type with a
smart constructor moves an invariant from "checked at construction" to
"unrepresentable", and you can see it happen in the shape of the error type.

Three distinct identifier types come from ONE generative functor applied three
times:

```ocaml
module Make_id () : ID = struct type t = string ... end
module Store_path = Make_id ()
module Sha256_hex = Make_id ()
module Output_name = Make_id ()
```

Rust needs three newtype declarations for that, Go three defined types.

## Where OCaml is NOT stronger

Being fair about it, three of the four rows OCaml wins are ties with Rust, and
the ones that matter most are ties with everyone:

- variants for `hash_algo`, `hash_mode` and the recursive `Json.t`: the same as
  Rust's `enum`, and the last of those is where Go pays most (a seven-case
  recursive sum becomes a struct with a discriminant and seven fields, in which
  an invalid shape is representable);
- native `option` for `outputs`: the same as Rust's `Option`, and only better
  than Go, which needed three encodings;
- structural equality with `=`: free, like Python and Rust, unlike Go.

And the last two rows of the typing table are identical in all four languages
and always will be. "Outputs non-empty", and above all "the recorded paths
match this derivation's own hash", are runtime checks everywhere, because they
compare a value against COMPUTED data. A type distinguishes what you construct;
a verifier is still required for what you compute.

The wire type shows the same limit from the other side. `Derivation.output`
carries `hash_algo : string`, not the variant, because parsing must be TOTAL
over whatever real Nix wrote. Strictness belongs on the construction side.

## One bug this implementation found

OCaml's `Digest` is MD5 only, so `Sha256` is written out here (see below). The
first version was wrong, and the reason is worth carrying:

> A custom infix operator's precedence comes from its **first character**, not
> from what it does.

`( &% ) = Int32.logand` therefore sits at the level of `&&`, *below* `^%`, so

```ocaml
let ch = !e &% !f ^% (Int32.lognot !e &% !g)
```

parses as `e AND (f XOR ...)`. Wrong tree, no warning. The FIPS 180-4 vectors in
the test suite caught it on the first run, which is exactly why they are the
first thing the suite checks. This is the OCaml member of the same family as the
Rust release-only shift and the Go nil-slice conflation: a language-specific
trap in the one function whose output nobody can sanity-check by eye.

## On writing our own SHA-256

Normally a bad idea. It is acceptable here for one reason: it has **no silent
failure mode**. It is checked against the published FIPS 180-4 vectors, then
against 12 golden store paths, 2516 real nixpkgs derivations, and byte-equality
with three other implementations. A wrong bit turns every one of those red at
once.

It is not offered as a general-purpose hash: no streaming interface, no
constant-time claims, nothing intended for a security boundary. If you would
rather depend on `digestif`, the swap is one module.

## The typing table

Which invariants each type system makes UNREPRESENTABLE, and which stay runtime
checks. This is one of the real outputs of the project, now complete.

| invariant | Python | Rust | Go | OCaml |
| --- | --- | --- | --- | --- |
| store path vs digest vs output name not confused | `NewType`, erased | newtypes | defined types | one generative functor, applied 3x |
| hash algorithm is one of four | `Literal`, erased; runtime check | `enum` | defined string; runtime check | variant |
| ingestion mode is flat or recursive | `Literal`, erased | `enum` | defined string; runtime check | variant |
| `outputs` is an Option | `Sequence \| None` | `Option<Vec<_>>` | struct with a discriminant | native `option` |
| env keys are unique | free | free | free | list + explicit check |
| env insertion order not observable | property test | free | free, enforced by randomised iteration | property test |
| structural equality | free | free | hand-written per type | free |
| exhaustiveness over failure cases | n/a | `match` | sentinels, no check | `match` |
| a recursive 7-case sum (a JSON value) | recursive `TypeAlias`, erased | 7-variant `enum` | **struct + discriminant + 7 fields; an invalid shape is representable** | 7-case variant |
| **name is a valid store name** | runtime | runtime | runtime | **unrepresentable** |
| outputs non-empty, one fixed output | runtime | runtime | runtime | runtime |
| recorded paths match the derivation's own hash | runtime | runtime | runtime | runtime |

## A deliberate deviation from the house rules

`ocaml.md` says exceptions are for bugs only. The recursive-descent parser
raises `Parse_error` internally and catches it at the module boundary, so the
PUBLIC surface is `parse : string -> (t, string) result` with no exception
escaping. Threading a result monad through nine grammar productions would
roughly double the parser for no change in the interface. The containment is
the point; if the exception could escape, this would be wrong.

Also: `.ocamlformat` pins **0.29.0**, not the 0.27.0 the house rules suggest.
ocamlformat 0.27 requires OCaml < 5.4 and this project pins 5.5.0, so the two
cannot both hold.

## Develop

```sh
make -C ../.. ocaml-test      # dune test (alcotest), in a container
make -C ../.. ocaml-lint      # ocamlformat
make -C ../.. conformance     # OCaml vs Go vs Rust vs Python vs real Nix
```

Docker is the only prerequisite. The image ships no build tool, so dune,
alcotest and ocamlformat are installed into a named cache volume on first use;
see `scripts/ml-check.sh`.

## Licence

MPL-2.0. Embedding it in a larger work, under any licence, is fine and is the
point. See [`docs/decisions/`](../../docs/decisions/).
