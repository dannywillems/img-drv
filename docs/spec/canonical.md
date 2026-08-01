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

### 1.2 inputDrvs

A list of pairs:

```
(drvPath, [outputName, ...])
```

The derivations this one depends on, each with the output names actually
needed. Verified in [`examples/dependent.drv`](examples/dependent.drv):
`[("/nix/store/...-dep-a.drv",["out"])]`.

OPEN: the sort order of this list, and of the inner output-name list, when
there is more than one entry.

### 1.3 inputSrcs

A list of store paths used directly as sources, not produced by a derivation.
Verified: passing a path literal produces
`["/nix/store/8bznhhm6dlj274in8lqs9av03bg1xdab-src.txt"]`.

OPEN: sort order with more than one entry.

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

**Store path computation is unresolved, and it blocks Phase 1.** Every `path`
in the outputs list, and the path of the `.drv` itself, is a hash. Reproducing
those requires the exact fingerprint construction (the `output:out:sha256:...`
scheme and the base-32 encoding Nix uses), which has not been verified here.

Until that is settled, an implementation can emit a derivation whose SHAPE is
right and whose PATHS are wrong, which is worse than useless because it looks
correct. Phase 1's differential test against `nix-instantiate` is what catches
that, and it cannot pass until this is done.

## 4. Reproducing the probes

```sh
docker run --rm nixos/nix:latest sh -c '
  cat > /tmp/x.nix <<EOF
derivation { name = "hello"; system = "x86_64-linux";
             builder = "/bin/sh"; args = [ "-c" "echo hi > \$out" ]; }
EOF
  cat $(nix-instantiate /tmp/x.nix)'
```

Pin the Nix version when this becomes a conformance oracle. `latest` was used
to derive the rules; it must not be used to test against.

## 5. Consequences for implementations

From [`../theory.md`](../theory.md) section 4, canonical serialization is the
well-definedness proof, so these are obligations rather than style:

1. Sort outputs by name; sort env by key; preserve args order; preserve the
   `outputs` env variable in declaration order.
2. Escape exactly the five bytes above and no others.
3. Emit no whitespace outside string literals.
4. Treat the byte sequence, not the parsed structure, as the artifact under
   test. The conformance suite compares bytes.
