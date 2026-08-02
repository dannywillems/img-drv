# Canonical serialization: the ATerm derivation format

**Status:** empirically derived, not guessed. Every rule below was established
by generating derivations with real Nix (`nix (Nix) 2.35.1`, image
`nixos/nix:latest`) and reading the bytes. The probes are reproducible; the
resulting files are in [`examples/`](examples/).

The Nix manual documents that derivations are serialised in ATerm format and
that the `Derive(...)` form is the stable one, but it does NOT publish the
grammar. So the grammar here comes from observation, and anything not observed
is marked OPEN rather than assumed.

## 1. Grammar

```
Derive( [outputs], [inputDrvs], [inputSrcs], system, builder, [args], [env] )
```

Exactly seven positional fields, in that order. No whitespace anywhere outside
string literals. No trailing newline inside the term (the files in
`examples/` carry one only because a text file ought to end with one; the
store object itself does not).

### 1.1 outputs

A list of 4-tuples:

```
(name, path, hashAlgo, hash)
```

- `name`: output name, e.g. `out`, `dev`, `lib`.
- `path`: the store path this output will occupy.
- `hashAlgo`, `hash`: empty strings for an ordinary derivation. For a
  fixed-output derivation, the algorithm and the hash.

**Sorted by output NAME, ascending.** Verified: a derivation declaring
`outputs = [ "out" "dev" "lib" ]` emits `dev`, `lib`, `out`
([`examples/multi.drv`](examples/multi.drv)).

**The `outputs` environment variable keeps DECLARATION order**, space
separated: the same derivation carries `("outputs","out dev lib")` in its env
while the outputs list is sorted. Two different orders in one file, and getting
this wrong changes bytes.

**Fixed-output hashes are re-encoded.** An `outputHash` given as 52 characters
appears in `env` exactly as written, but in the outputs tuple as 64 lowercase
hex characters ([`examples/fixed.drv`](examples/fixed.drv)). So the hash is
decoded from whatever representation was supplied and re-encoded as hex.

Precisely, verified on all 93 fixed-output derivations in the real corpus:

```
hash     = hex(decode(env.outputHash))
hashAlgo = ("r:" if env.outputHashMode == "recursive" else "") + algo
algo     = env.outputHashAlgo, or the prefix of an SRI outputHash when absent
```

`decode` accepts hex, Nix base-32, base-64, and SRI (`<algo>-<base64>`). The
corpus exercises SRI (74) and base-32 (19); none of the real ones were written
in hex, so an implementation that only accepts hex parses nothing real. The
`r:` prefix is what selects the entirely different path scheme documented in
[`store-paths.md`](store-paths.md).

### 1.2 inputDrvs

A list of pairs:

```
(drvPath, [outputName, ...])
```

The derivations this one depends on, each with the output names actually
needed. Verified in [`examples/dependent.drv`](examples/dependent.drv):
`[("/nix/store/...-dep-a.drv",["out"])]`.

**Sorted by drvPath, ascending, and the inner output-name list is sorted
ascending too.** Measured over the real corpus: 1293 of 1293 derivations have
their `inputDrvs` in path order, and 9983 of 9983 inner name lists are sorted.
Paths are unique within the list: 1293 of 1293.

Independent of use order, which is what makes it a canonicalization rather than
a coincidence: [`examples/many.drv`](examples/many.drv) lists `aaa`, `zzz`,
`mmm` by path while its `args` reference them as `zzz`, `aaa`, `mmm`.

Do not confuse this with the order of the HASHED form, which re-sorts the same
list by each input's hash. One derivation, two orderings; see
[`store-paths.md`](store-paths.md).

### 1.3 inputSrcs

A list of store paths used directly as sources, not produced by a derivation.
Verified: passing a path literal produces
`["/nix/store/8bznhhm6dlj274in8lqs9av03bg1xdab-src.txt"]`.

**Sorted ascending**: 1293 of 1293 in the real corpus.

### 1.4 system, builder

Plain strings, e.g. `"x86_64-linux"` and `"/bin/sh"`.

### 1.5 args

A list of strings, in order. Order is significant and is NOT sorted.

### 1.6 env

A list of `(key, value)` pairs, **sorted by key, ascending**.

Verified decisively: a derivation declaring `zzz`, then `aaa`, then `mmm`
emits `aaa`, `builder`, `mmm`, `name`, `out`, `system`, `zzz`
([`examples/ordering.drv`](examples/ordering.drv)). Declaration order is
discarded.

Note that the derivation's own outputs appear in `env` as well, one variable
per output name.

### 1.7 Which env entries are synthesized

An eDSL does not receive `env` verbatim: some entries are derived from the
other fields, and an implementation that omits them emits a different
derivation. Measured over the 1293 corpus derivations that use the
one-variable-per-attribute encoding (see section 1.8):

| entry | rule | verified |
| --- | --- | --- |
| `name` | the derivation name | 1293 of 1293 |
| `system` | equals the `system` field | 1293 of 1293 |
| `builder` | equals the `builder` field | 1293 of 1293 |
| one per output name | equals that output's path | 2310 of 2310 |
| `outputs` | present **iff the caller declared outputs**, in DECLARATION order, space separated | see below |

`args` is **not** mirrored into `env`: 1293 of 1293.

The `outputs` entry is the subtle one, and the rule is not "present when there
is more than one output". It is present exactly when the caller wrote an
`outputs` attribute at all, because Nix turns that attribute into an env
variable like any other. Of the 1197 corpus derivations that declare it, 605
declare a single `out`; 96 single-output derivations omit it entirely, which is
what a bare `derivation { ... }` with no `outputs` attribute produces
([`examples/hello.drv`](examples/hello.drv)).

So an implementation needs `outputs` to be an OPTION, not a list with a
default. Modelling it as "defaults to `["out"]`" makes `hello.drv`
unreproducible; modelling it as "emit when longer than one" makes the 605
single-output nixpkgs derivations unreproducible.

Its order is the caller's, not the sorted order of the outputs list: they
differ in 575 of 1197 corpus cases, so this is a rule real packages exercise
constantly rather than a curiosity of `multi.drv`.

For a fixed-output derivation, `outputHash` and `outputHashMode` are always
present (93 of 93) and `outputHashAlgo` usually is (82 of 93; it is omitted
when the algorithm is already carried by an SRI-format `outputHash`).

### 1.8 A second env encoding: `__structuredAttrs`

1223 of the 2516 real derivations in the corpus do not use the encoding above
at all. They carry a single `__json` entry holding the attributes as JSON,
plus one entry per output. This is `__structuredAttrs = true`, now the nixpkgs
default for many builders, and it exists because the flat encoding can only
carry strings: a list, a boolean or a nested attribute set has to be flattened
to a string and re-parsed by the builder. The JSON encoding keeps the types.

Every rule below was established by instantiating probes with the pinned Nix
([`../../scripts/probe-structured.nix`](../../scripts/probe-structured.nix))
and by measuring the 456 structured derivations in a real closure.

**The env is exactly `__json` plus one entry per output name**, sorted by key
like any other env. Measured: of the 456, the key sets are `__json` plus the
declared outputs, with nothing else. Verified on 456 of 456.

**Output paths are NOT in the JSON.** They stay as ordinary env entries keyed
by output name, exactly as in the flat encoding. That is why the masking rule
in [`store-paths.md`](store-paths.md) needs no special case: blanking env
entries whose KEY is an output name still finds them. Confirmed by recomputing
paths for a 1458-derivation closure containing 456 structured derivations:
2063 of 2063.

**The JSON is canonical**, and its form is pinned:

| rule | verified |
| --- | --- |
| object keys sorted ascending | 456 of 456 |
| compact separators, `,` and `:`, no spaces | 456 of 456 |
| non-ASCII emitted raw, not `\uXXXX` escaped | 456 of 456 |

**What the JSON contains**: every user attribute WITH ITS TYPE PRESERVED
(string, integer, boolean, list, nested object), plus the synthesized `name`,
`system` and `builder`. `args` is absent, as in the flat encoding, because it
is a positional field of the derivation rather than an attribute.
`__structuredAttrs` itself is consumed and does not appear.

**`outputs` inside the JSON follows the same OPTION rule** as the flat
encoding's `outputs` env variable: present, in DECLARATION order, exactly when
the caller declared it. A probe declaring `outputs = [ "out" "dev" ]` yields
`"outputs":["out","dev"]` while the outputs tuple is sorted `dev`, `out`; a
probe declaring nothing yields a JSON with no `outputs` key at all. See
[`examples/structured.drv`](examples/sqgix69fbs6hjh5kmf2pb1zvfmi5d0am-structured.drv).

**A fixed-output structured derivation puts `outputHash`, `outputHashAlgo` and
`outputHashMode` INSIDE the JSON**, not in the env, while the outputs tuple
still carries the hash re-encoded as hex per section 1.1. This is why a reader
that looks for `outputHash` as an env key finds nothing on 1146 of the corpus's
1239 fixed-output derivations.

**Consequence for the signature.** The flat encoding needs only
`[(String, String)]`. This one needs a JSON value, which is a RECURSIVE sum:
`null | bool | int | float | string | [value] | {string: value}`. That is the
first recursive type in `docs/spec/signature.md`, and the first place the
signature needs more than products, finite sums and lists of primitives. It is
still a first-order algebraic datatype, so `theory.md` section 1 survives, but
it is a genuine extension and it is where a language without sum types has to
work hardest.

## 2. String escaping

Strings are double-quoted. Exactly five escapes are applied, and **nothing
else is escaped**:

| byte | emitted as |
| --- | --- |
| `"` | `\"` |
| `\` | `\\` |
| LF (0x0A) | `\n` |
| CR (0x0D) | `\r` |
| TAB (0x09) | `\t` |

**Every other byte is emitted raw, including other control characters.**
Verified by embedding BEL (0x07) in a value and dumping the result with `od`:
the byte appears literally in the file, unescaped, while CR in the same string
became `\r`.

This matters, and it is the rule most likely to be got wrong from memory: an
implementation that escapes control characters generally (as JSON does, with
``) produces different bytes and therefore a different derivation.

OPEN: whether non-UTF-8 byte sequences are permitted in values, and whether
they round-trip.

## 3. What is NOT yet specified

Store path computation, which used to be the blocker here, is solved and
verified: see [`store-paths.md`](store-paths.md). The sort order of `inputDrvs`
and `inputSrcs` is now measured rather than open (sections 1.2 and 1.3). What
remains open:

- `__structuredAttrs`, the second env encoding, used by 1223 of the 2516 real
  derivations in the corpus (section 1.8);
- NAR serialization, needed for `inputSrcs` computed from local files rather
  than referenced by path;
- whether non-UTF-8 byte sequences are permitted in values, and round-trip.

The failure this section exists to prevent has not changed: an implementation
can emit a derivation whose SHAPE is right and whose PATHS are wrong, which is
worse than useless because it looks correct. `make differential` is what
catches it.

## 4. Reproducing the probes

The probe is checked in as [`../../scripts/probe.nix`](../../scripts/probe.nix)
and run by `make differential` against the pinned oracle. Ad hoc:

```sh
docker run --rm nixos/nix:2.35.1 sh -c '
  cat > /tmp/x.nix <<EOF
derivation { name = "hello"; system = "x86_64-linux";
             builder = "/bin/sh"; args = [ "-c" "echo hi > \$out" ]; }
EOF
  cat $(nix-instantiate /tmp/x.nix)'
```

The oracle IS pinned, by digest, in
[`../../scripts/pins.env`](../../scripts/pins.env). `latest` was used to derive
the rules and must never be used to test against: a tag is a mutable pointer,
and a moving oracle cannot distinguish "we broke it" from "upstream changed".

Measured rather than assumed: Nix 2.34.8 and 2.35.1 emit byte-identical
derivations for a probe exercising multiple outputs, a dependency edge and
unsorted env keys. So the format is stable across at least one minor release.

## 5. Consequences for implementations

From [`../theory.md`](../theory.md) section 4, canonical serialization is the
well-definedness proof, so these are obligations rather than style:

1. Sort outputs by name; sort env by key; preserve args order; preserve the
   `outputs` env variable in declaration order.
2. Escape exactly the five bytes above and no others.
3. Emit no whitespace outside string literals.
4. Treat the byte sequence, not the parsed structure, as the artifact under
   test. The conformance suite compares bytes.
