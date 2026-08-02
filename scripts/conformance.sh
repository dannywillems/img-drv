#!/usr/bin/env bash
#
# The experiment this project is a bet on.
#
# Each implementation DESCRIBES the same ten intents through its own eDSL and
# writes the derivations out. The bytes are then compared three ways:
#
#   1. every implementation against every other -- the portability claim;
#   2. each against docs/spec/examples, which real Nix produced -- the claim
#      that both are right rather than merely agreeing with each other.
#
# Two implementations agreeing on the wrong bytes would pass (1) and fail (2),
# which is why (2) exists. The comparison is BYTE-level and the filenames are
# the derivations' own computed store paths, so a wrong hash shows up as a
# missing file rather than as a diff.
#
# Usage: ./scripts/conformance.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="$REPO/build/conformance"
GOLDEN="$REPO/docs/spec/examples"

rm -rf "$OUT"
IMPLS="python rust go ocaml"
mkdir -p "$OUT/nix"
for impl in $IMPLS; do mkdir -p "$OUT/$impl"; done

echo ">> python emits the corpus"
"$HERE/py.sh" examples build/conformance/python

echo ">> rust emits the corpus"
"$HERE/rs.sh" examples build/conformance/rust

echo ">> go emits the corpus"
"$HERE/go.sh" examples build/conformance/go

echo ">> ocaml emits the corpus"
"$HERE/ml.sh" examples build/conformance/ocaml

# The golden files carry a trailing newline because they are text files in a
# repository; the store objects do not. Strip it so the comparison is against
# what Nix actually hashed.
for f in "$GOLDEN"/*.drv; do
  printf '%s' "$(cat "$f")" > "$OUT/nix/$(basename "$f")"
done

status=0

# Every implementation against the first one. Equality is transitive, so
# comparing each to python covers every pair, and naming python in the message
# would be misleading: a difference means the two disagree, not that python is
# right. The comparison against Nix below is what decides who is right.
for impl in $IMPLS; do
  [ "$impl" = python ] && continue
  echo ">> python vs $impl"
  if diff -r "$OUT/python" "$OUT/$impl"; then
    echo "   identical"
  else
    echo "   DIFFER: the portability claim just failed" >&2
    status=1
  fi
done

for impl in $IMPLS; do
  echo ">> $impl vs real Nix"
  if diff -r "$OUT/nix" "$OUT/$impl"; then
    echo "   identical"
  else
    echo "   DIFFER: $impl does not reproduce what Nix emitted" >&2
    status=1
  fi
done

n=$(find "$OUT/nix" -name '*.drv' | wc -l | tr -d ' ')
if [ "$status" -eq 0 ]; then
  count=0
  for impl in $IMPLS; do count=$((count + 1)); done
  echo ">> conformance: $n intents, $count implementations, byte-identical to Nix"
fi
exit "$status"
