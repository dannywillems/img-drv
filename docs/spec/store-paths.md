# Store path computation

**Status: PARTLY solved. Do not trust this yet.**

Corrected 2026-08-01. This document previously said "solved and verified" on
the strength of hand-written examples, which agreed 12 times out of 12. Real
nixpkgs derivations then disagreed **323 times out of 403**, and the earlier
claim was simply wrong.

What holds up against real derivations:

- the outer step, base-32 and XOR-folding: **verified**;
- fixed-output derivations: **80 of 80 in a real closure**;
- non-fixed derivations with NO inputs: verified on the examples here.

What does not:

- **non-fixed derivations WITH inputs: 0 of 145.** The input-folding rule below
  is wrong or incomplete, and finding out how is the current top task.

The lesson is recorded rather than buried: hand-made examples only exercise the
cases you already thought of. See `scripts/fetch-corpus.sh`, which now pulls
random real packages so CI keeps finding cases a fixed corpus never would.

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

`kind` is `text`, and the inner hash is simply the sha256 of the derivation
text, with the name suffixed `.drv`:

```
drv_path = store_path("text", sha256(aterm), name + ".drv")
```

## Output paths, and the asymmetry that matters

Output paths come from `hashDerivationModulo`, which exists in **two variants**,
and the difference is the single subtlest thing in this document:

> **Mask your own outputs. Do not mask your inputs'.**

- Computing a derivation's OWN output paths: serialize it with every output
  path replaced by the empty string, in the outputs list *and* in `env`. They
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

| case | what it pins down |
| --- | --- |
| `minimal` | the `text` kind, and the basic output path |
| `ordering` | that env sorting does not disturb the hash |
| `multi` | per-output names and the `-dev`/`-lib` suffix rule |
| `fixed` | the fixed-output scheme |
| `dep-a` | reconstructed from scratch; its computed paths match what `dependent.drv` refers to |
| `dependent` | the mask/do-not-mask asymmetry |

## The open problem

Non-fixed derivations with inputs do not reproduce. What has been ruled out by
experiment:

- the parser: 226 of 226 real derivations round-trip byte-identically, so
  reading and writing the format is not the issue;
- the outer machinery: fixed-output paths reproduce exactly, so base-32,
  XOR-folding and the fingerprint layout are right;
- three input-hash variants (masked, unmasked, raw text) on a real case with
  only fixed-output inputs, which isolates the masked serialization step and
  still mismatches.

That last point is the useful one: with all inputs fixed-output, the input
hashes are unambiguous, so the remaining error is in how the derivation ITSELF
is serialized for hashing, not in how its inputs are folded in. Suspects, in
order: whether env entries keyed by an output name are blanked exactly as
assumed, whether `inputSrcs` participate differently, and whether newer Nix
computes output paths by a route this model does not capture at all.

## Still open

- [ ] Sort order of `inputDrvs` when there is more than one entry. The map is
      keyed by the input HASH, not the path, so the order is by hash and
      changes as inputs change.
- [ ] `source` paths: NAR serialization and recursive hashing, needed for
      `inputSrcs` computed from local files rather than referenced by path.
- [ ] Whether any of this shifts in newer Nix versions, which is the reason to
      pin the oracle.
