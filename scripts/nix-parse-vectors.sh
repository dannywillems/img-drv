#!/usr/bin/env bash
#
# Regenerate the parser differential vectors from the PINNED Nix.
#
# nix-instantiate --parse re-prints the AST it parsed, so it pins tree SHAPE
# rather than merely "it parsed". Column 1 is the input, column 2 is what Nix
# prints, and every implementation's parser has to reproduce column 2.
#
# Usage: ./scripts/nix-parse-vectors.sh cases.txt > docs/spec/nix-parse/vectors.tsv

set -euo pipefail

CASES="${1:?usage: $0 <cases-file>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=scripts/pins.env
. "$HERE/pins.env"

docker run --rm -v "$(cd "$(dirname "$CASES")" && pwd)/$(basename "$CASES"):/c.txt:ro" \
  "$NIX_IMAGE" sh -c '
while IFS= read -r line; do
  [ -z "$line" ] && continue
  printf "%s" "$line" > /tmp/t.nix
  printf "%s\t%s\n" "$line" "$(nix-instantiate --parse /tmp/t.nix 2>&1 | head -1)"
done < /c.txt'
