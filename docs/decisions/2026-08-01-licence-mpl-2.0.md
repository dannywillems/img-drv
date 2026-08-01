# Licence: MPL-2.0 for the code, CC0 for the specification

**Date:** 2026-08-01
**Status:** decided, and cheap to revisit until there is a second contributor

## Motivation

The repository was created under GPL-3.0, chosen before the shape of the
project was clear. The stated goal since then has been specific: *"For each
language, think about making libraries that can be reused"*, four
implementations shipped to PyPI, crates.io, opam and the Go module proxy, so
that other people embed this in their own stacks.

The licence has to serve that goal, and it has to be settled before anyone
else contributes, because relicensing later needs the agreement of every
copyright holder. Right now there is exactly one.

## Problems

**GPL-3.0 is self-defeating for this project.** A strong copyleft licence on a
library means every application linking it must itself be GPL-3.0. For an IR
library whose entire purpose is to be embedded in other people's build
tooling, most of it commercial, that is not a safeguard: it is a decision that
the library will not be adopted. The one thing the project cannot survive is
being un-embeddable.

**LGPL is the usual answer and it is a poor fit here specifically.** LGPL
assumes dynamic linking: §4 lets a proprietary work use the library provided
the user can relink it against a modified version. Three of the four target
languages, Go, Rust and OCaml, link statically by default, so satisfying §4
means distributing object files or equivalent so a user can relink. That is
burdensome, rarely done correctly, and its application to Rust and Go is
argued over rather than settled. Choosing a licence whose central mechanism
does not match how the artifacts are actually built means shipping a legal
question with every release.

**Permissive alone gives up something worth keeping.** Under Apache-2.0 or
MIT, a vendor can fork the IR, fix a store path bug privately, and ship a
divergent implementation. For a project whose value is that every
implementation produces identical bytes, silent divergence is the specific
failure mode to guard against.

**A specification is not a library, and encumbering it is worse than useless.**
`docs/spec/` defines bytes. Independent implementations of it are the point of
the project, and nobody should have to reason about whether reading the spec
taints their code.

## Decision

**MPL-2.0 for all code**, and **CC0-1.0 for `docs/spec/`.**

MPL-2.0 is file-level copyleft. Modifications to img-drv's own files must be
published under MPL-2.0; combining those files with anything else, under any
licence, proprietary included, is explicitly permitted by §3.3 with no linking
analysis at all. Static linking is a non-question, which is exactly the
problem LGPL creates for Go, Rust and OCaml.

That maps onto what the project actually wants:

| want | MPL-2.0 gives it |
| --- | --- |
| anyone can embed the library, including commercially | yes, §3.3, and no linking distinction |
| a fix to the IR comes back | yes, §3.2, modified files stay open |
| four implementations, one behaviour | divergence must be published, so it is visible |
| no legal question shipped with each release | yes: file-level, so static linking is irrelevant |

It is not a novel choice: Firefox, Terraform before its relicensing, and much
of the Rust ecosystem's copyleft tail use it, so it is familiar to legal
reviewers and pre-approved at many companies. That matters more than elegance
for a library nobody has heard of yet.

CC0 on the specification removes the question entirely for implementers. The
spec is a description of a format, largely one that already exists; claiming
rights over it would only deter the independent implementations that give the
project its meaning.

## Costs accepted

- A vendor may build a proprietary product on top without contributing
  anything back, provided they do not modify img-drv's own files. This is the
  deliberate trade: adoption is worth more than the tax.
- Two licences in one repository is mild extra explaining, mitigated by
  `docs/spec/README.md` stating it plainly.
- MPL-2.0 is not GPL-compatible in the naive direction, though §1.12's
  secondary-licence clause allows GPL combination, and the LICENSE file keeps
  that option available.

## Revisit if

- A vendor ships a materially divergent implementation and refuses to
  contribute back, which would mean the file-level boundary is too weak.
- A concrete adoption blocker appears that only Apache-2.0 clears, most likely
  patent-grant language a specific legal team requires. Apache-2.0 has an
  explicit patent grant; MPL-2.0's §2.1(b) grant is real but less familiar.

Either way, relicensing gets harder with each new contributor. That is why
this was settled now rather than later.

## References

- MPL-2.0 FAQ, on the file-level boundary and why linking is not the test:
  <https://www.mozilla.org/en-US/MPL/2.0/FAQ/>
- MPL-2.0 §3.3 (larger works) and §3.2 (distribution of modifications):
  <https://www.mozilla.org/en-US/MPL/2.0/>
- FSF on LGPL and static linking, the source of the §4 relinking obligation:
  <https://www.gnu.org/licenses/gpl-faq.html#LGPLStaticVsDynamic>
