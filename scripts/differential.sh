#!/usr/bin/env bash
#
# The differential test: our store path computation against real Nix.
#
# Instantiate scripts/probe.nix with the PINNED oracle, export the closure, and
# recompute every store path in it. Nix recorded those paths; we recompute them
# from the derivation text alone. Agreement means the implementation is right.
# Disagreement means either we broke something or upstream Nix changed how
# paths are derived, and the pin is what tells the two apart.
#
# This is the gate that catches "right shape, wrong identity": a derivation
# whose bytes look perfect and whose paths no cache can ever satisfy.
#
# Usage: ./scripts/differential.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
REL="${DIFF_DIR:-build/differential}"
OUT="$REPO/$REL"

# shellcheck source=scripts/pins.env
. "$HERE/pins.env"

mkdir -p "$OUT"
rm -f "$OUT"/*.drv 2>/dev/null || true

echo ">> instantiating probe with nix $NIX_VERSION (pinned by digest)"

# --pure is not enough on its own: the probe deliberately avoids nixpkgs so
# that no channel and no network are needed, which also keeps this fast.
docker run --rm \
  -v "$OUT:/out" \
  -v "$HERE/probe.nix:/probe.nix:ro" \
  "$NIX_IMAGE" sh -c '
set -eu
drv=$(nix-instantiate /probe.nix)
for p in $(nix-store --query --requisites "$drv" | grep "\.drv$"); do
  cp -n "$p" /out/
done
' >/dev/null

n=$(find "$OUT" -name '*.drv' | wc -l | tr -d ' ')
if [ "$n" -eq 0 ]; then
  echo "!! the oracle produced no derivations; the probe or the image is broken"
  exit 1
fi
echo ">> closure: $n derivations"

echo ">> round-trip check (parse then serialize must be byte-identical)"
"$HERE/py.sh" roundtrip "$REL"

echo ">> store path check (ours vs what Nix recorded)"
"$HERE/py.sh" verify "$REL"

# The eDSL against a LIVE oracle.
#
# Everything above checks the PATH COMPUTATION: parse what Nix emitted,
# recompute, compare. The eDSL itself was checked only against the golden files
# in docs/spec/examples/, which are committed and therefore frozen, and a frozen
# golden cannot notice the ORACLE moving. Here each implementation describes the
# probe's five derivations through its eDSL and the bytes are diffed against
# what nix-instantiate produced moments ago.
#
# It earned this on its first run: a transcription that added one trailing
# newline to an indented string, which no committed golden would ever have
# caught because no committed golden contains that string.
for impl in ocaml python rust go; do
  case "$impl" in
    ocaml) runner=ml.sh ;;
    python) runner=py.sh ;;
    rust) runner=rs.sh ;;
    go) runner=go.sh ;;
  esac
  emitted="$REPO/build/probe-$impl"
  rm -rf "$emitted"
  mkdir -p "$emitted"
  "$HERE/$runner" probe "build/probe-$impl" >/dev/null
  ok=0
  bad=0
  for f in "$emitted"/*.drv; do
    base=$(basename "$f")
    if cmp -s "$f" "$OUT/$base"; then
      ok=$((ok + 1))
    else
      bad=$((bad + 1))
      echo "!! $impl: $base differs from what Nix just emitted"
    fi
  done
  echo ">> $impl eDSL: $ok/$((ok + bad)) byte-identical to a live nix-instantiate"
  [ "$bad" -eq 0 ] || exit 1
done
