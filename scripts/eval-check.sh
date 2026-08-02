#!/usr/bin/env bash
#
# The arrow the project existed to build.
#
#     .nix TEXT  --parse-->  EXPR  --eval-->  DRV  --bytes-->  .drv
#
# No eDSL anywhere in it. A real Nix expression is read, evaluated by our own
# evaluator, and the derivations that evaluation produced are written out; the
# pinned nix-instantiate is asked for the same file, and the whole closure is
# diffed BYTE FOR BYTE.
#
# Why this gate and not a unit test on the evaluator: a derivation of the right
# SHAPE with the wrong identity is the failure mode this project exists to
# prevent, and only bytes can tell the difference. The dependency edges in
# particular are never written by the caller here. They are computed, by the
# string-context homomorphism (impl/*/value.*), so an edge that is quietly lost
# shows up as a different input hash and therefore a different path, and cannot
# show up as anything else.
#
# The probe is scripts/probe.nix, the same file `make differential` uses, so
# the two gates ask different questions about identical input: that one asks
# whether our HASHING matches, this one whether our EVALUATION does.
#
# Usage: ./scripts/eval-check.sh [impl ...]     (default: the ones that have an
#                                                evaluator)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="$REPO/build/eval"

# shellcheck source=scripts/pins.env
. "$HERE/pins.env"

if [ "$#" -eq 0 ]; then
  set -- ocaml
fi

runner_for() {
  case "$1" in
    ocaml) echo ml.sh ;;
    python) echo py.sh ;;
    rust) echo rs.sh ;;
    go) echo go.sh ;;
    *) echo "unknown implementation: $1" >&2; exit 2 ;;
  esac
}

# Two probes, because they exercise different halves of the seam. probe.nix has
# multiple outputs, a fixed-output derivation, and two inputDrvs edges, so it
# tests the context homomorphism on the Built case. probe-src.nix interpolates
# a PATH LITERAL, which the evaluator has to copy into the store through NAR
# before it can even name it, so it tests the Opaque case and joins this gate to
# nar-check. probe-builtins.nix drives every builtin through a derivation
# ATTRIBUTE, so the question asked of each is not "is the value right" but
# "does the store path move", which is stronger and leaves a wrong answer
# nowhere to hide. probe-structured.nix uses the SECOND env encoding
# (__structuredAttrs, 1223 of 2516 real derivations) plus `import`, and it is
# the one that catches an implementation that coerces every value to a string.
PROBES="${PROBE:-probe.nix probe-src.nix probe-builtins.nix probe-structured.nix}"

run_probe() {
  local PROBE="$1"
  shift

rm -rf "${OUT:?}"
mkdir -p "$OUT/expected"

echo ">> asking the pinned nix to instantiate $PROBE"
# --add-root would need a writable store root; instead copy the closure out.
docker run --rm -v "$HERE:/s:ro" -v "$OUT:/out" "$NIX_IMAGE" sh -c "
set -eu
cp /s/probe*.nix /s/probe-src.txt /tmp/
top=\$(nix-instantiate /tmp/$PROBE 2>/dev/null | head -1)
# The whole closure, not just the top: a dependency is a derivation too, and
# a wrong edge shows up in the dependency's bytes as readily as in the top's.
for d in \$(nix-store --query --requisites \"\$top\" | grep '\\.drv\$'); do
  cp \"\$d\" /out/expected/
done
"
want=$(find "$OUT/expected" -name '*.drv' | wc -l | tr -d ' ')
echo "   $want derivations in the closure"

  fail=0
  for impl in "$@"; do
  echo ">> $impl: evaluating $PROBE with our own evaluator"
  mkdir -p "$OUT/$impl"
  if ! EVAL_FILE="/w/scripts/$PROBE" "$HERE/$(runner_for "$impl")" eval "build/eval/$impl"; then
    fail=1
    continue
  fi
  ok=0
  for f in "$OUT/expected"/*.drv; do
    b=$(basename "$f")
    if [ ! -f "$OUT/$impl/$b" ]; then
      echo "!! missing $b (a wrong path, so a wrong identity)"
      fail=1
    elif cmp -s "$f" "$OUT/$impl/$b"; then
      ok=$((ok + 1))
    else
      echo "!! $b: right path, different bytes"
      diff <(tr ',' '\n' < "$f") <(tr ',' '\n' < "$OUT/$impl/$b") | head -8
      fail=1
    fi
  done
  extra=$(( $(find "$OUT/$impl" -name '*.drv' | wc -l) - want ))
  if [ "$extra" -gt 0 ]; then
    echo "!! $extra derivation(s) nix did not produce"
    fail=1
  fi
  echo "   $ok/$want byte-identical to nix-instantiate"
done
return "$fail"
}

status=0
for probe in $PROBES; do
  run_probe "$probe" "$@" || status=1
done
[ "$status" -eq 0 ]
