# img-drv (Go)

A portable, content-addressed IR for reproducible build descriptions. Describe
a build, compute its store paths, serialize it, and get bytes identical to what
Nix emits.

**This implementation is the falsification test**, and is the most important of
the four. Go has no sum types, no higher-kinded types and minimal generics. If
the first-order signature in [`docs/spec/signature.md`](../../docs/spec/signature.md)
needs anything beyond finite products, this is where it breaks. A clean
embedding is the empirical evidence for [`docs/theory.md`](../../docs/theory.md);
an ugly one is the refutation.

So the result comes first, and the rest of this file is the evidence.

## The result

**The signature needed nothing beyond finite products.** Every operation and
every sort in the specification is expressible in Go, and all ten golden
intents reproduce Nix's bytes exactly, including each derivation's own `.drv`
store path. `make conformance` shows Python, Rust and Go emitting identical
bytes.

Nothing turned out to be INEXPRESSIBLE. What Go loses is **enforcement** and
**uniformity**:

- a finite sum becomes a defined string type that accepts any string, so the
  compiler stops checking what Rust's `enum` and Python's `Literal` check, and
  a runtime validation takes over;
- `Option` has no single spelling, so one concept in the other two
  implementations becomes **three different encodings** in this one.

That is a real cost and it is measurable, but it is a cost in CHECKING, not in
EXPRESSIVENESS. The Lawvere-theory argument in `theory.md` section 1 survives
its sharpest test.

## Install

```sh
go get github.com/dannywillems/img-drv/impl/go
```

Go 1.26.5. **Zero dependencies**: hashing and base-64 are both in the standard
library, so this matches Python and beats Rust, which needs `sha2`.

## Describe a build

```go
import imgdrv "github.com/dannywillems/img-drv/impl/go"

hello, err := imgdrv.Derive(imgdrv.Build{
    Name:    "hello",
    System:  "x86_64-linux",
    Builder: "/bin/sh",
    Args:    []string{"-c", "echo hi > $out"},
})

hello.MustOutput("out") // /nix/store/mjs27ix6ig2bkbi3s3sm470vrv4lf7ic-hello
hello.Path()            // /nix/store/76w21n1f03fs5kw8fnffphx7qrqffw6r-hello.drv
hello.ATerm()           // the bytes, byte-identical to nix-instantiate's
```

A struct literal with the zero value supplying every default is arguably the
most honest translation of the four: `spec/signature.md` **is** a finite
product, and here it is written as one with no ceremony at all.

Depending on something means naming the outputs you need:

```go
dependent := imgdrv.MustDerive(imgdrv.Build{
    Name:      "dependent",
    System:    "x86_64-linux",
    Builder:   "/bin/sh",
    Args:      []string{"-c", "cat " + string(hello.MustOutput("out")) + " > $out"},
    InputDrvs: []imgdrv.Dep{hello.MustNeed()},
})
```

## What it cost, item by item

Each of these is a place the language shaped the code. They are listed because
counting them is this implementation's job.

### 1. Finite sums become unchecked strings

`HashAlgo` and `HashMode` are finite sums. Go has none, so they are defined
string types with constants. Two things follow:

- `HashAlgo("sha3")` **compiles**. In Rust the equivalent does not exist and in
  Python `mypy` rejects it. There is a test asserting that this is caught at
  runtime instead, `TestAnInvalidAlgorithmIsOnlyCaughtAtRuntime`, which exists
  only in this implementation.
- a `switch` over one has no exhaustiveness check, so adding a fifth algorithm
  compiles everywhere and is simply not handled.

The compensation is a `Valid()` method and a check on every construction path.

### 2. `Option` has three spellings

Go has no `Option`, and the three optional things in this API each ended up
encoded differently:

| what | encoding | why not the others |
| --- | --- | --- |
| `Outputs` (declared or not) | struct with a `Declared bool` | see below; the obvious encoding is unsafe |
| `Build.FixedOutput` | `*FixedOutput`, nil for none | a pointer is the idiom for an optional struct |
| `FixedOutput.Mode` | `""` zero value means `Flat` | a zero value that means the default is idiomatic and convenient |

In Python and Rust all three are one type. Go does not stop you saying any of
it; it stops you saying it the **same way** twice.

### 3. The nil-slice trap, and the one that would have been a real bug

The obvious encoding for `outputs` is `[]OutputName` with `nil` meaning "not
declared". It is **wrong**, and quietly so.

Nix emits an `outputs` env variable exactly when the caller declared the
attribute, so undeclared and `["out"]` are different derivations with different
store paths (96 of the corpus's single-output derivations take the first, 605
take the second). But Go deliberately makes `nil` and empty slices behave
identically under `len`, `range` and `append`. **The distinction the bytes
depend on is exactly the distinction the language encourages you to ignore.**

The safe encoding is an explicit discriminant, which is precisely the "struct
with a discriminant plus a constructor per case" that `AGENTS.md` predicts a
sum type degrades into. Of everything in this file, this is the one that would
have produced wrong bytes rather than merely more code.

### 4. Structural equality is hand-written

A Go struct containing a slice is not comparable with `==`, and there is no
derivable equality. `reflect.DeepEqual` would do it in one line at the cost of
dropping to runtime-typed comparison, which is what this implementation exists
to avoid. So `Derivation.Equal` and `InputDrv.Equal` are written out, over a
generic `equalSlice` helper.

Python gets this from `@dataclass`, Rust from `#[derive(PartialEq)]`.

### 5. Error plumbing dominates the parser

Go has no `?`. `Parse` contains **16** `if err != nil` blocks for a nine-step
grammar. That is verbosity rather than weakness (nothing is unexpressible), and
it is the single largest source of bulk here.

### 6. The constructor cannot share the type's name

Visibility in Go is capitalisation, and a package has one exported namespace,
so the type `Derivation` and a constructor called `Derivation` would collide.
The function is `Derive`. Python and Rust both call it `derivation`.

Trivial, and worth recording: a "portable" API turns out not to be quite
portable in its **spelling** even where it is exactly portable in its meaning.

### 7. Fallible accessors need panicking twins

`Output(name)` can fail, and Go has no `?` and no exceptions, so using it inside
an expression forces a temporary variable per use. The examples would be three
times their length, so there are **3** `Must*` helpers that panic. Python needs
none; Rust needs none in tests because `?` and `.expect()` compose in
expression position.

### 8. Property-based testing is the one place types are lost

The generator is stdlib `testing/quick`, per `go.md`. Its `Generate` method
returns a `reflect.Value`, so the single place this implementation touches
runtime typing is its **property tests**. `quick` also does not shrink, so a
failure reports whatever value happened to break rather than the smallest one.

### 9. Generics were needed, barely, and only the weak kind

Four generic functions: `equalSlice`, `sortedCopy`, `dedupe`, `listOf`. Every
one has an identical body for every type parameter, constrained by
`comparable`, `~string` or `any`. That is exactly the case Go's own guidance
permits ("write code, not types"), and nothing here wanted a higher-kinded type
or a type class. **The signature did not need generics gymnastics.**

## Where Go is BETTER

Reporting only the costs would be dishonest, and two of these are genuine
advantages for this specific problem.

- **Map iteration is randomised on purpose.** Forgetting to sort `env` before
  serializing is a silent bug in Python (insertion-ordered `dict`) and in Rust
  (`BTreeMap` is already sorted). In Go it is a loudly flaky one, so the law
  "describing the same intent twice gives the same bytes" is a real test of
  canonicalization here and nearly vacuous in the other two.
- **Over-wide shifts are defined as zero.** The bug the Rust port hit, where
  `u8 << 8` panics in debug and is silently masked to `<< 0` in release, cannot
  happen here: Go defines the result as 0. The guard is kept anyway so all three
  implementations read alike, because relying on a language-specific shift rule
  inside a hash function is how you get an answer that is right in one language
  only.
- **Defined string types** catch the `StorePath` / `Sha256Hex` / `OutputName`
  confusion at compile time, exactly as Rust's newtypes do and unlike Python's
  erased `NewType`. This is the one typing-table row where Go is as strong as
  Rust.
- **Zero dependencies.**

## Size

Non-blank lines of library source, all three heavily commented, so treat this as
an order-of-magnitude comparison rather than a benchmark.

| implementation | non-blank lines |
| --- | --- |
| Python | 1305 |
| Rust | 1881 |
| Go | 2594 |

Roughly **2x** Python for the same behaviour. Items 4, 5 and 7 above account for
most of the difference, and none of them is about the signature.

## The typing table

Which invariants each type system makes UNREPRESENTABLE, and which stay runtime
checks. This is one of the real outputs of the project.

| invariant | Python | Rust | Go |
| --- | --- | --- | --- |
| store path vs digest vs output name not confused | `NewType`, erased; mypy only | distinct types | defined types |
| hash algorithm is one of four | `Literal`, erased; runtime check | `enum` | **defined string; runtime check** |
| ingestion mode is flat or recursive | `Literal`, erased | `enum` | **defined string; runtime check** |
| `outputs` is an Option, not a defaulted list | `Sequence \| None` | `Option<Vec<_>>` | **struct with a discriminant** |
| env keys are unique | free (`Mapping`) | free (`BTreeMap`) | free (`map`) |
| env insertion order not observable | property test | free (`BTreeMap`) | free, and enforced by randomised iteration |
| structural equality | free (`@dataclass`) | free (`derive`) | **hand-written per type** |
| exhaustiveness over failure cases | n/a | `match` on an enum | **sentinel errors, no check** |
| outputs non-empty, names valid, one fixed output | runtime | runtime | runtime |
| recorded paths match the derivation's own hash | runtime | runtime | runtime |

The pattern, now visible across three languages: **a stronger type system
removes checks on values you CONSTRUCT, and none of the checks on values you
COMPUTE.** The last two rows are identical in all three and always will be.

## Develop

```sh
make -C ../.. go-test        # go test -race, in a container
make -C ../.. go-lint        # gofmt + go vet
make -C ../.. conformance    # Go vs Rust vs Python vs real Nix
```

Docker is the only prerequisite; the toolchain is a pinned image
(`scripts/pins.env`). Note that the image is `bookworm` rather than `alpine`
deliberately: `go test -race` needs cgo and therefore a C toolchain, and the
race detector is not optional.

## Licence

MPL-2.0. Embedding it in a larger work, under any licence, is fine and is the
point; changes to these files themselves stay open. See
[`docs/decisions/`](../../docs/decisions/) for the reasoning.
