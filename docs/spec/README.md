# spec

Normative. Everything here defines bytes, and changing bytes is a breaking
change.

Empty until Phase 0 (see [`../plan.md`](../plan.md)). It will hold:

- `signature.md`   the first-order signature: sorts, operations, arities
- `canonical.md`   serialization: ordering, encoding, escaping, hashing
- `examples/`      worked examples with their expected bytes and hashes

The rule that governs this directory comes from
[`../theory.md`](../theory.md) section 4: reproducibility is the
well-definedness of a quotient, and it holds only if normalization is confluent
and terminating. So canonical serialization is not a formatting preference, it
is the proof obligation. If two implementations can disagree on bytes for the
same intent, this directory has a bug, regardless of what the implementations
do.
