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
REL="${CORPUS_DIR:-build/corpus}"
OUT="$REPO/$REL"

# The oracle is pinned by digest in one place; see scripts/oracle.env.
# shellcheck source=scripts/pins.env
. "$HERE/pins.env"

mkdir -p "$OUT"
rm -f "$OUT"/*.drv 2>/dev/null || true

echo ">> pulling $COUNT random nixpkgs packages"

# Everything runs in the pinned Nix image: nothing is installed on the host,
# and the same command works on a laptop and on a CI runner.
docker run --rm -v "$OUT:/out" -e COUNT="$COUNT" "$NIX_IMAGE" sh -c '
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

# Both checks run through the library, so the corpus gate and the unit tests
# exercise exactly the same code.
echo ">> round-trip check (parse then serialize must be byte-identical)"
"$HERE/py.sh" roundtrip "$REL"

echo ">> store path check"
"$HERE/py.sh" verify "$REL"

# The eDSL emits CANONICAL bytes, so each ordering rule it applies is a claim
# about Nix. Checking it here means a fresh random sample gets a vote on that
# claim, rather than only the ten examples checked into docs/spec.
echo ">> canonical form check (canonicalizing real derivations must be a no-op)"
"$HERE/py.sh" canonical "$REL"

# The corpus filenames ARE real Nix store paths, so recomputing them is free
# verification. Nothing did it until the transpiler's commuting square exposed
# that a .drv path includes the paths it REFERENCES; before that fix this check
# passed on 149 of 1458.
echo ">> .drv path check (each derivation's own store path, from its bytes)"
"$HERE/py.sh" drvpaths "$REL"
