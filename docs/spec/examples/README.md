# examples

Golden files. Every one of these was produced by REAL Nix
(`nix (Nix) 2.35.1`, image `nixos/nix:latest`), not written by hand, and each
demonstrates a rule in [`../canonical.md`](../canonical.md).

| file | demonstrates |
| --- | --- |
| `minimal.drv` | the seven-field `Derive(...)` shape |
| `ordering.drv` | env is sorted by key; declaration order is discarded |
| `multi.drv` | outputs sorted by name, while the `outputs` env var keeps declaration order |
| `dependent.drv` | `inputDrvs` as `(drvPath, [outputNames])` |
| `fixed.drv` | fixed-output: `hashAlgo`/`hash` populated, and the hash re-encoded as hex |

These are the seed of the Phase 2 conformance suite: an implementation is
correct when it emits these bytes for the corresponding intent.

They carry a trailing newline because they are text files in a repository; the
store objects themselves do not. Strip it before comparing.

Regenerate with the probe in [`../canonical.md`](../canonical.md) section 4.
Note that the store paths inside depend on the Nix version and will change if
the oracle is re-pinned, which is itself a reason to pin it.
