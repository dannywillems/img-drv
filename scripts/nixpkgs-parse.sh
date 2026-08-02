#!/usr/bin/env bash
#
# Differential-test the Nix PARSER against real nixpkgs.
#
# This is the corpus that docs/decisions/2026-08-02-nix-frontend-build-not-reuse.md
# promised when it argued for writing our own front-end instead of linking
# Snix: "Run over nixpkgs, that is tens of thousands of real vectors, which is
# a far better guarantee than any single implementation's test suite."
#
# The oracle is `nix-instantiate --parse`, which re-prints the AST it parsed.
# That pins tree SHAPE and not merely "it parsed", so it catches a precedence
# or associativity error that a yes/no parse check would wave through. The
# hand-written vectors in docs/spec/nix-parse/vectors.tsv are 59 cases someone
# thought of; this is every construction nixpkgs actually uses.
#
# Two properties of the oracle the harness has to work around, both recorded in
# that decision file:
#
#   - `--parse` performs STATIC SCOPE RESOLUTION and fails with "undefined
#     variable" on a free variable. Most nixpkgs files are lambdas taking their
#     dependencies, so they are fine, but any file Nix itself refuses is SKIPPED
#     rather than counted as our failure. The skip count is reported, because a
#     harness that silently drops most of its corpus looks identical to one that
#     passes.
#   - it prints a DESUGARED tree (`*` becomes `__mul`, unary minus becomes
#     `__sub 0`), so our printer has to reproduce the desugaring too.
#
# The tree is pinned by commit (NIXPKGS_REV in pins.env) so a failure is
# reproducible, and WHICH files are sampled is random, so CI keeps reaching
# constructions a fixed list would never contain. That is the same design as
# scripts/fetch-corpus.sh, for the same reason.
#
# Usage: ./scripts/nixpkgs-parse.sh [count] [impl ...]   (default 300, ocaml python)

set -euo pipefail

COUNT="${1:-300}"
shift || true
if [ "$#" -eq 0 ]; then
  set -- ocaml python
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
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
REL="${NIXPKGS_PARSE_DIR:-build/nixpkgs-parse}"
OUT="$REPO/$REL"

# shellcheck source=scripts/pins.env
. "$HERE/pins.env"

rm -rf "$OUT"
mkdir -p "$OUT"

echo ">> sampling $COUNT .nix files from nixpkgs $NIXPKGS_REV"

# Everything runs in the pinned Nix image, so the oracle is the same version
# the rest of the project is verified against.
docker run --rm -v "$OUT:/out" \
  -e COUNT="$COUNT" -e REV="$NIXPKGS_REV" "$NIX_IMAGE" sh -c '
set -eu
cd /tmp
# codeload serves a tarball of the exact commit, so no git and no channel.
curl -sSL "https://codeload.github.com/NixOS/nixpkgs/tar.gz/$REV" | tar xz
cd "nixpkgs-$REV"

skipped=0
n=0
# sort -R makes the sample random; the TREE is pinned, the CHOICE is not.
for f in $(find . -name "*.nix" -type f | sort -R); do
  [ "$n" -ge "$COUNT" ] && break
  # `--parse` resolves scope, so a file with a free variable is refused by Nix
  # itself. That is the oracle declining to answer, not us failing.
  out=$(nix-instantiate --parse "$f" 2>/dev/null) || { skipped=$((skipped+1)); continue; }
  [ -n "$out" ] || { skipped=$((skipped+1)); continue; }
  n=$((n+1))
  # Name the pair by index, not by a flattened path: the pinned Nix image is
  # minimal and ships no sed or tr to rewrite the slashes with. The ABSOLUTE
  # original path goes in a third file, for two reasons: a mismatch can name
  # the culprit, and the parser needs the source directory because Nix resolves
  # relative paths at parse time against the file they appear in.
  base=$(printf "%04d" "$n")
  cp "$f" "/out/$base.nix"
  printf "%s\n" "$out" > "/out/$base.expected"
  printf "%s\n" "$PWD/${f#./}" > "/out/$base.path"
done
# Nix expands a leading tilde at parse time, so the parser has to be told the
# HOME the oracle used or those paths resolve differently in the two images.
printf "%s\n" "$HOME" > /out/home
echo "   $n usable, $skipped skipped (Nix itself refused to parse them)"
'

n=$(find "$OUT" -name '*.expected' | wc -l | tr -d ' ')
echo ">> corpus: $n real nixpkgs expressions in $OUT"
if [ "$n" -eq 0 ]; then
  echo "no usable files sampled; the harness is broken, not the parser" >&2
  exit 1
fi

fail=0
for impl in "$@"; do
  echo ">> $impl parses each and compares the printed tree"
  "$HERE/$(runner_for "$impl")" parsecheck "$REL" || fail=1
done
[ "$fail" -eq 0 ]
