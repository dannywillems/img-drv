# Store path computation

**Status: solved, and verified against real derivations.**

- **2063 of 2063** output paths reproduced across a **1458-derivation** real
  nixpkgs closure, 456 of them `__structuredAttrs`.
- **1458 of 1458** `.drv` paths recomputed from the files' own bytes.
- **11 of 11** golden examples, and **11 of 11** through real Nix end to end.
- Every corpus derivation round-trips byte-identically through the parser.

The history is kept deliberately. This document first said "solved and
verified" on the strength of hand-written examples, which agreed 12 times out
of 12. Real derivations then disagreed **323 times out of 403**. Three distinct
bugs have now hidden behind examples that never exercised them, and all three
are documented below under "The three that hid".

Nothing here came from memory. The manual does not document this, so each rule
was established by reproducing known outputs and rejecting the variants that
did not.

## The outer step, shared by everything

```
fingerprint = "<kind>:sha256:<inner hex>:<store dir>:<name>"
path        = <store dir>/<base32(compress(sha256(fingerprint), 20))>-<name>
```

Only `kind` and `inner hex` vary. `kind` is:

- `text` for a `.drv` file,
- `output:<output name>` for a build output,
- `source` for a file added directly to the store.

### base32

Nix's own alphabet, `0123456789abcdfghijklmnpqrsvwxyz`, which omits **e, o, u
and t** so that no store path accidentally spells a word.

The encoding is **not RFC 4648**. Digits are emitted from the END of the buffer
backwards, five bits at a time. A stock base-32 library gives a different
string, and this is the first thing to check when a path is close but wrong.

### compress

A store path carries 20 bytes, not 32, and the sha256 is **XOR-folded** rather
than truncated: byte `i` of the digest is XORed into byte `i mod 20`. Truncating
gives a plausible-looking path that is wrong.

## The `.drv` path

A `.drv` file is a `text` store object, so the inner hash is the sha256 of the
derivation text and the name is suffixed `.drv`. But `kind` is **not** the bare
string `text`: a text store object's fingerprint also lists every store path the
file REFERENCES, sorted, colon-separated, appended to the kind.

For a derivation, the references are its `inputDrvs` and its `inputSrcs`:

```
refs     = sorted(set(inputDrvs paths) | set(inputSrcs))
kind     = "text"  if refs is empty
           "text:" + ":".join(refs)  otherwise
drv_path = store_path(kind, sha256(aterm), name + ".drv")
```

The references are **not** in the outer `name` position and **not** in the inner
hash; they sit between the kind and the literal `sha256`, so the full
fingerprint of a derivation with two inputs reads:

```
text:/nix/store/aaa...-a.drv:/nix/store/bbb...-b.drv:sha256:<inner>:/nix/store:foo.drv
```

### Why this was wrong here for a long time

Omitting the references is right for a derivation with **no inputs** and wrong
for every other one, so a hand-written corpus of leaf derivations agrees with
the broken rule perfectly. It survived `make conformance`, `make differential`,
`make corpus` and `make spec-check` because each of those compared our
computation against filenames we had also computed. Only the transpiler's
commuting square asked **real Nix** what the path should be, and the answer
differed.

The measurement, against 1458 real nixpkgs `.drv` files whose filenames were
chosen by real Nix:

| rule               | paths reproduced |
| ------------------ | ---------------- |
| with references    | **1458 of 1458** |
| without references | 149 of 1458      |

The 149 are exactly the derivations with no inputs.

Two files in `docs/spec/examples/` had to be RENAMED as part of the fix, because
they had been named by our own wrong computation rather than by Nix. That is the
general hazard of a golden corpus you generate yourself, and the reason
`make transpile-check` exists.

`make drvpath-check` now recomputes every corpus filename from its own bytes, so
this class of error cannot return silently.

## Output paths, and the asymmetry that matters

Output paths come from `hashDerivationModulo`, which exists in **two variants**,
and the difference is the single subtlest thing in this document:

> **Mask your own outputs. Do not mask your inputs'.**

- Computing a derivation's OWN output paths: serialize it with every output
  path replaced by the empty string, in the outputs list _and_ in `env`. They
  must be masked because they are precisely what is being computed.
- Using a derivation as an INPUT of another: serialize it with its output paths
  **intact**, so for a derivation with no inputs this is just the sha256 of its
  `.drv` text.

In both cases, each `inputDrvs` entry has its store PATH replaced by that
input's own hash (hex), recursively.

```
output_path(out) = store_path("output:" + out, self_hash, output_store_name)
self_hash        = sha256(aterm with own outputs masked,
                          inputDrv paths replaced by their input-hashes)
```

Getting this backwards produces a syntactically perfect derivation with wrong
paths. Verified by testing all four combinations of (mask, do not mask) against
`dependent.drv`; only this one reproduces Nix's output.

### Output names

`out` keeps the plain package name; every other output is suffixed. Package
`multi` with outputs `out`, `dev`, `lib` yields store names `multi`,
`multi-dev`, `multi-lib`.

## Fixed-output derivations

A fixed-output derivation declares its result in advance, so its identity comes
from the declared hash rather than from how it is written:

```
inner    = sha256("fixed:out:" + algo + ":" + hash_hex + ":")
out_path = store_path("output:out", inner, name)
```

The same value is used when it appears as an input. The consequence is a
feature, not an accident: **two fixed-output derivations fetching the same bytes
are interchangeable**, however differently they are expressed. That is what lets
every `fetchurl` in nixpkgs share a cache entry.

## Why this matters more than it looks

Input addressing means the output path is known **before anything is built**.
That is what lets a binary cache answer "I already have that" without ever
seeing your source, and it is why most Nix users never compile anything.

So an implementation that emits the right ATerm shape with wrong hashes is worse
than one that fails loudly: it produces a derivation that no cache can ever
satisfy, that silently rebuilds the world, and whose outputs land at paths
nothing else refers to. **Right shape, wrong identity.** The differential test
against `nix-instantiate` exists to catch exactly this.

## Verified cases

| case        | what it pins down                                                                   |
| ----------- | ----------------------------------------------------------------------------------- |
| `minimal`   | the `text` kind, and the basic output path                                          |
| `ordering`  | that env sorting does not disturb the hash                                          |
| `multi`     | per-output names and the `-dev`/`-lib` suffix rule                                  |
| `fixed`     | the fixed-output scheme                                                             |
| `dep-a`     | reconstructed from scratch; its computed paths match what `dependent.drv` refers to |
| `dependent` | the mask/do-not-mask asymmetry                                                      |

## The three that hid

All three were invisible to hand-written examples, and all three are the kind of
thing that produces a plausible wrong answer rather than an error. The third is
the sharpest, because it was invisible to the automated gates too; see
`docs/abstractions.md` entry 10 for why.

### A fixed-output derivation has TWO different hash strings

```
its own path :  sha256("fixed:out:" + algo + ":" + hash + ":")
as an input  :  sha256("fixed:out:" + algo + ":" + hash + ":" + output path)
```

The second appends the store path; the first cannot, because that path is what
is being computed.

Using the first in both places leaves every fetch's own path correct and every
path DOWNSTREAM of a fetch wrong. That is exactly the pattern the first real
corpus showed: 80 fixed-output derivations passing, and all 145 that depended
on them failing. No example written by hand had a dependency on a fetch.

### `r:sha256` uses an entirely different scheme

Recursive (NAR) ingestion with sha256 takes the **`source`** kind and uses the
declared hash **directly** as the inner hash, with no `fixed:out:` fingerprint
at all:

```
r:sha256  ->  store_path("source", declared hash, name)
otherwise ->  store_path("output:out", sha256("fixed:out:..."), name)
```

Exactly one derivation in a 226-derivation closure exercised this. A corpus of
six hand-written examples would never have contained it, and a corpus of six
hundred real ones contains it by accident.

## Still open

- [x] Sort order of `inputDrvs` when there is more than one entry. Settled, and
      it is two rules rather than one: the serialized `.drv` sorts by store
      PATH (1293 of 1293 real derivations, `canonical.md` section 1.2), while
      the form that gets HASHED re-sorts the same list by each input's hash.
      A textual substitution preserves path order and so silently breaks every
      derivation with more than one input.
- [ ] `source` paths: NAR serialization and recursive hashing, needed for
      `inputSrcs` computed from local files rather than referenced by path.
- [ ] Whether any of this shifts in newer Nix versions, which is the reason to
      pin the oracle.

### A `.drv` path names what it references

The `text` kind carries the sorted references, which are the derivation's
`inputDrvs` and `inputSrcs`. Documented in full under "The `.drv` path" above.

What makes this one different from the other two: they were caught the first
time a REAL closure was run through the checker, which is exactly what that
check is for. This one survived real closures, because no gate ever recomputed
a derivation's own filename. Every gate compared our arithmetic against a name
we had also chosen. The oracle that found it was the one that let Nix choose the
name.
