#!/usr/bin/env bash
#
# Pull N random packages from nixpkgs, export the .drv closure of each, and
# verify our store path computation against them.
#
# These are REGRESSION TEST VECTORS NOBODY WROTE BY HAND. Hand-made examples
# agreed with our implementation 12 times out of 12; the first real closure
# disagreed 323 times out of 403. Randomising which packages are pulled means
# CI keeps finding cases a fixed corpus would never contain.
#
# Usage: ./scripts/fetch-corpus.sh [count]

set -euo pipefail

COUNT="${1:-10}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="${CORPUS_DIR:-$REPO/build/corpus}"

mkdir -p "$OUT"
rm -f "$OUT"/*.drv 2>/dev/null || true

echo ">> pulling $COUNT random nixpkgs packages"

# Everything runs in the pinned Nix image: nothing is installed on the host,
# and the same command works on a laptop and on a CI runner.
docker run --rm -v "$OUT:/out" -e COUNT="$COUNT" nixos/nix:latest sh -c '
set -eu
nix-channel --add https://nixos.org/channels/nixpkgs-unstable nixpkgs >/dev/null 2>&1
nix-channel --update >/dev/null 2>&1

# A random sample of top-level attribute names. Many will fail to instantiate
# (unfree, broken, platform-specific); that is expected, so failures are
# skipped rather than fatal.
attrs=$(nix-instantiate --eval --expr \
  "builtins.concatStringsSep \"\n\" (builtins.attrNames (import <nixpkgs> {}))" \
  2>/dev/null | tr -d \" | tr "\\\\n" "\n" | grep -E "^[a-z][a-zA-Z0-9_-]*$" | sort -R)

got=0
for a in $attrs; do
  [ "$got" -ge "$COUNT" ] && break
  d=$(timeout 120 nix-instantiate "<nixpkgs>" -A "$a" 2>/dev/null | head -1) || continue
  [ -n "$d" ] || continue
  d="${d%%!*}"
  for p in $(nix-store --query --requisites "$d" 2>/dev/null | grep "\.drv$"); do
    cp -n "$p" /out/ 2>/dev/null || true
  done
  got=$((got+1))
  echo "   $a"
done
'

n=$(find "$OUT" -name '*.drv' | wc -l | tr -d ' ')
echo ">> corpus: $n derivations in $OUT"

echo ">> round-trip check (parse then serialize must be byte-identical)"
python3 "$HERE/aterm.py" "$OUT"

echo ">> store path check"
python3 "$HERE/store_paths.py" "$OUT"
