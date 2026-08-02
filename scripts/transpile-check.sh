#!/usr/bin/env bash
#
# The COMMUTING SQUARE (docs/architecture.md), for every implementation.
#
# Each one builds the conformance intents twice, by two different routes, and
# the two must meet:
#
#   intent --build IR--> .drv bytes                                (make conformance)
#   intent --print .nix--> real Nix --instantiate--> .drv bytes    (here)
#
# Passing means the transpiler emits Nix source that a real Nix turns into the
# very bytes we already know are correct, which is a much stronger claim than
# "Nix accepted the file". A file Nix accepts but that denotes a different
# derivation lands at a different store path, and that is caught here.
#
# WHY THE COMPARISON IS ON .drv AND NOT ON THE .nix SOURCE.
#
# `make conformance` can demand that four implementations emit byte-identical
# .drv files. This layer cannot demand byte-identical .nix, and asking for it
# would be a category error. A lambda written HOAS has no name until the
# surface invents one, so the emitted source is a CHOICE OF REPRESENTATIVE from
# an alpha-equivalence class, and which representative you get depends on the
# host's evaluation order: OCaml evaluates list elements right to left, Python
# left to right, so the same corpus comes out with `a4` where the other has
# `a1`. Both are correct, and both denote the same derivation.
#
# So the law at this layer is alpha-equivalence, and instantiating is how it is
# decided: Nix quotients the names away, and the .drv is the normal form. That
# makes this check STRONGER than a source diff rather than weaker, because it
# compares meaning instead of spelling.
#
# Usage: ./scripts/transpile-check.sh [impl ...]     (default: all four)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
GOLDEN="$REPO/docs/spec/examples"

# shellcheck source=scripts/pins.env
. "$HERE/pins.env"

if [ "$#" -eq 0 ]; then
  set -- ocaml python rust go
fi

# A case rather than an associative array: macOS ships bash 3.2, which has
# neither `declare -A` nor a safe empty-array expansion under `set -u`.
runner_for() {
  case "$1" in
    ocaml) echo ml.sh ;;
    python) echo py.sh ;;
    rust) echo rs.sh ;;
    go) echo go.sh ;;
    *) echo "unknown implementation: $1" >&2; exit 2 ;;
  esac
}

fail=0
for impl in "$@"; do
  rel="build/transpile/$impl"
  out="$REPO/$rel"
  rm -rf "$out"
  mkdir -p "$out"

  echo ">> $impl emits the corpus as .nix expressions"
  "$HERE/$(runner_for "$impl")" transpile "$rel" >/dev/null

  echo ">> instantiating each with the pinned nix, and comparing to the goldens"
  if ! docker run --rm -v "$out:/out" -v "$GOLDEN:/golden:ro" "$NIX_IMAGE" sh -c '
ok=0; bad=0
for f in /out/*.nix; do
  want=$(basename "$f" .nix).drv
  got=$(nix-instantiate "$f" 2>/tmp/err | head -1) || {
    echo "INSTANTIATE FAILED: $want"; sed "s/^/    /" /tmp/err | head -3; bad=$((bad+1)); continue; }
  if [ "$(basename "$got")" != "$want" ]; then
    echo "WRONG STORE PATH for $want"
    echo "    got  $(basename "$got")"
    bad=$((bad+1)); continue
  fi
  # The golden carries a trailing newline because it is a file in a repo; the
  # store object does not.
  if [ "$(cat "$got")" != "$(cat "/golden/$want")" ]; then
    echo "BYTES DIFFER for $want"; bad=$((bad+1)); continue
  fi
  ok=$((ok+1))
done
echo ">> '"$impl"': $ok/$((ok+bad)) intents through real Nix reproduced the golden .drv"
[ "$bad" -eq 0 ]
'; then
    fail=1
  fi
done

[ "$fail" -eq 0 ]
