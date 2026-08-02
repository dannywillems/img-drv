#!/usr/bin/env bash
#
# Real nixpkgs `lib`, through our evaluator.
#
# Every other gate here runs on input this project wrote. This one runs on tens
# of thousands of lines of Nix that nobody here designed, using every corner of
# the language, and it is the first input to the evaluator that was not chosen
# to be evaluable. The parser learned the same lesson the same way
# (docs/abstractions.md entry 13): a curated corpus tells you about the curator.
#
# The gate is still bytes. A lib function that returns a subtly different string
# moves the derivation's store path, so there is nothing to assert by hand.
#
# Usage: ./scripts/lib-check.sh [impl ...]     (default: ocaml)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="$REPO/build/lib-check"
TREE="$REPO/build/nixpkgs-tree"

# shellcheck source=scripts/pins.env
. "$HERE/pins.env"

if [ "$#" -eq 0 ]; then
  set -- ocaml
fi

# Pinned by commit, so a failure reproduces. Cached, because it is a large
# download and this gate is meant to be runnable on a laptop.
if [ ! -d "$TREE/lib" ]; then
  echo ">> fetching nixpkgs $NIXPKGS_REV"
  mkdir -p "$TREE"
  curl -sSL "https://codeload.github.com/NixOS/nixpkgs/tar.gz/$NIXPKGS_REV" \
    | tar xz -C "$TREE" --strip-components=1
fi

rm -rf "${OUT:?}"
mkdir -p "$OUT/expected" "$OUT/ocaml"

echo ">> asking the pinned nix to instantiate probe-lib.nix"
docker run --rm -v "$HERE:/s:ro" -v "$TREE:/nixpkgs:ro" -v "$OUT:/out" \
  -e NIX_PATH=nixpkgs=/nixpkgs "$NIX_IMAGE" sh -c '
set -eu
cp /s/probe-lib.nix /tmp/
top=$(nix-instantiate /tmp/probe-lib.nix 2>/dev/null | head -1)
cp "$top" /out/expected/
'
want=$(basename "$(find "$OUT/expected" -name '*.drv' | head -1)")
echo "   $want"

fail=0
for impl in "$@"; do
  echo ">> $impl: evaluating probe-lib.nix with our own evaluator"
  mkdir -p "$OUT/$impl"
  if ! EVAL_FILE=/w/scripts/probe-lib.nix \
       EVAL_EXTRA_MOUNT="$TREE:/nixpkgs:ro" \
       EVAL_NIX_PATH=nixpkgs=/nixpkgs \
       "$HERE/ml.sh" eval "build/lib-check/$impl"; then
    fail=1
    continue
  fi
  if [ ! -f "$OUT/$impl/$want" ]; then
    echo "!! $impl computed a different .drv path"
    fail=1
  elif cmp -s "$OUT/expected/$want" "$OUT/$impl/$want"; then
    echo "   byte-identical to nix-instantiate, through real nixpkgs lib"
  else
    echo "!! right path, different bytes"
    diff <(tr ',' '\n' < "$OUT/expected/$want") \
         <(tr ',' '\n' < "$OUT/$impl/$want") | head -10
    fail=1
  fi
done

[ "$fail" -eq 0 ]
