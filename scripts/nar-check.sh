#!/usr/bin/env bash
#
# NAR, and the half of the references rule nothing else could reach.
#
# Two differential checks against the pinned Nix, neither of which uses a
# committed golden.
#
# 1. SOURCE PATHS. A tree of awkward cases is serialized to NAR by each
#    implementation, hashed, and turned into a store path; `nix-store --add`
#    computes the same path from the same bytes. The cases are chosen for what
#    NAR discards and what it keeps: an empty file, an executable bit, a nested
#    directory, a symlink, and a name whose byte order differs from its locale
#    order.
#
# 2. inputSrcs. A derivation's own store path lists the paths it REFERENCES,
#    which is inputDrvs UNION inputSrcs. Every derivation this project could
#    previously build had an EMPTY inputSrcs, so that half of the rule was
#    verified only by reading real files. Here we build one, and both its bytes
#    and its own path have to match what nix-instantiate produces.
#
# Usage: ./scripts/nar-check.sh [impl ...]     (default: all four)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TREE="$REPO/build/nar-tree"
OUT="$REPO/build/nar"

# shellcheck source=scripts/pins.env
. "$HERE/pins.env"

if [ "$#" -eq 0 ]; then
  set -- ocaml python rust go
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

# The tree is BUILT here rather than committed, because git cannot carry an
# executable bit reliably across platforms and stores no symlink the same way
# everywhere. What NAR keeps is exactly what git is least reliable about.
rm -rf "${TREE:?}" "${OUT:?}"
mkdir -p "$TREE/dir/nested" "$OUT"
printf '' > "$TREE/empty"
printf 'hello\n' > "$TREE/plain"
printf 'aligned to eight' > "$TREE/aligned"
printf '#!/bin/sh\necho hi\n' > "$TREE/exec"
chmod +x "$TREE/exec"
printf 'nested\n' > "$TREE/dir/nested/deep"
ln -s ../plain "$TREE/dir/link"
# Byte order and locale order disagree on these two, which is why they are here.
printf 'Z\n' > "$TREE/dir/Zed"
printf 'a\n' > "$TREE/dir/apple"

echo ">> asking the pinned nix what it would call each of these"
docker run --rm -v "$TREE:/t:ro" -v "$OUT:/out" -v "$HERE:/s:ro" "$NIX_IMAGE" sh -c '
set -eu
cp -r /t /tmp/tree
cd /tmp/tree
for e in $(ls -1 | sort); do
  printf "%s\t%s\n" "$e" "$(nix-store --add "$e")"
done > /out/expected-sources
cp /s/probe-src.nix /s/probe-src.txt /tmp/
nix-store --add /tmp/probe-src.txt > /out/expected-src-path
nix-instantiate /tmp/probe-src.nix 2>/dev/null > /out/expected-drv-path
cp "$(cat /out/expected-drv-path)" /out/expected-with-src.drv
'

fail=0
for impl in "$@"; do
  echo ">> $impl: source paths, via its own NAR"
  if ! "$HERE/$(runner_for "$impl")" source build/nar-tree > "$OUT/got-$impl"; then
    fail=1
    continue
  fi
  if diff -u "$OUT/expected-sources" "$OUT/got-$impl" > "$OUT/diff-$impl"; then
    echo "   $(wc -l < "$OUT/expected-sources" | tr -d ' ')/$(wc -l < "$OUT/expected-sources" | tr -d ' ') match nix-store --add"
  else
    echo "!! $impl disagrees with nix-store --add"
    head -12 "$OUT/diff-$impl"
    fail=1
  fi

  echo ">> $impl: a derivation with a non-empty inputSrcs"
  rm -rf "${OUT:?}/$impl"
  mkdir -p "$OUT/$impl"
  "$HERE/$(runner_for "$impl")" srcdrv "build/nar/$impl" > "$OUT/srcdrv-$impl"
  want_drv=$(basename "$(cat "$OUT/expected-drv-path")")
  if [ ! -f "$OUT/$impl/$want_drv" ]; then
    echo "!! $impl computed a different .drv path"
    echo "    nix  $want_drv"
    echo "    ours $(basename "$OUT/$impl"/*.drv)"
    fail=1
  elif cmp -s "$OUT/$impl/$want_drv" "$OUT/expected-with-src.drv"; then
    echo "   same path AND same bytes as nix-instantiate"
  else
    echo "!! $impl: right path, different bytes"
    fail=1
  fi
done

[ "$fail" -eq 0 ]
