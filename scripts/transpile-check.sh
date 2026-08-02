#!/usr/bin/env bash
#
# The COMMUTING SQUARE (docs/architecture.md).
#
# An implementation builds each conformance intent twice, by two different
# routes, and the two must meet:
#
#   intent --build IR--> .drv bytes                     (make conformance)
#   intent --print .nix--> real Nix --instantiate--> .drv bytes   (here)
#
# Passing means the transpiler emits Nix source that a real Nix turns into the
# very bytes we already know are correct, which is a much stronger claim than
# "Nix accepted the file". A file Nix accepts but that denotes a different
# derivation lands at a different store path, and that is caught here.
#
# Usage: ./scripts/transpile-check.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="$REPO/build/transpile"
GOLDEN="$REPO/docs/spec/examples"

# shellcheck source=scripts/pins.env
. "$HERE/pins.env"

rm -rf "$OUT"
mkdir -p "$OUT"

echo ">> ocaml emits the corpus as .nix expressions"
"$HERE/ml.sh" transpile build/transpile >/dev/null

echo ">> instantiating each with the pinned nix, and comparing to the goldens"
docker run --rm -v "$OUT:/out" -v "$GOLDEN:/golden:ro" "$NIX_IMAGE" sh -c '
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
echo ">> $ok/$((ok+bad)) intents: our .nix, through real Nix, reproduced the golden .drv"
[ "$bad" -eq 0 ]
'
