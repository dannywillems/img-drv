#!/usr/bin/env bash
#
# A worked example: a real package, through a real overlay, against real
# nixpkgs.
#
# The eleven conformance intents are derivations nobody would write: no
# dependencies, no stdenv, no composition. They pin the SERIALIZATION. This
# pins the SURFACE, which is where the project's claim actually lives and which
# had the least evidence behind it.
#
# The comparison is a STORE PATH, not text. docs/spec/examples/worked-example.nix
# is idiomatic hand-written Nix; each implementation builds the same package
# through its `surface` layer, and the two are required to instantiate to the
# same derivation. They are not textually similar and were never meant to be:
# the .drv is the normal form, for the same reason the transpiler's round-trip
# law lives there.
#
# nixpkgs is pinned by commit, so a failure reproduces.
#
# Usage: ./scripts/worked-example.sh [impl ...]     (default: all four)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
REFERENCE="$REPO/docs/spec/examples"

# shellcheck source=scripts/pins.env
. "$HERE/pins.env"

if [ "$#" -eq 0 ]; then
  set -- ocaml python rust go
fi

# A case rather than an associative array: macOS ships bash 3.2.
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
  rel="build/worked/$impl"
  out="$REPO/$rel"
  rm -rf "$out"
  mkdir -p "$out"

  echo ">> $impl builds the package through its surface"
  "$HERE/$(runner_for "$impl")" worked "$rel" >/dev/null

  if ! docker run --rm -v "$out:/w:ro" -v "$REFERENCE:/e:ro" \
    -e REV="$NIXPKGS_REV" "$NIX_IMAGE" sh -c '
set -eu
cd /tmp
curl -sSL "https://codeload.github.com/NixOS/nixpkgs/tar.gz/$REV" | tar xz
export NIX_PATH="nixpkgs=/tmp/nixpkgs-$REV"
want=$(nix-instantiate /e/worked-example.nix 2>/dev/null)
got=$(nix-instantiate /w/worked-example.nix 2>/tmp/err) || {
  echo "INSTANTIATE FAILED"; sed "s/^/    /" /tmp/err | head -5; exit 1; }
if [ "$want" != "$got" ]; then
  echo "DIFFERENT DERIVATION"
  echo "    hand-written $want"
  echo "    surface      $got"
  exit 1
fi
echo ">> the surface and the hand-written Nix denote the same derivation"
echo "   $want"
'; then
    fail=1
  fi
done

[ "$fail" -eq 0 ]
