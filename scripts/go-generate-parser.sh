#!/usr/bin/env bash
#
# Regenerate the Go parser from grammar.y, and optionally check it is current.
#
# Go has no build step to run a generator in, so impl/go/nix/grammar.go is
# COMMITTED. That buys a generated table a reviewer can actually read, and costs
# the possibility of a stale checkout: an edit to grammar.y that nobody
# regenerates leaves a parser that still compiles and parses the OLD language.
# `--check` is what makes that impossible to merge.
#
# Usage: ./scripts/go-generate-parser.sh [--check]

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# shellcheck source=scripts/pins.env
. "$HERE/pins.env"

CHECK="${1:-}"

docker run --rm -v "$REPO:/w" -w /w/impl/go/nix "$GO_IMAGE" sh -c "
  set -eu
  go run $GOYACC -o /tmp/grammar.go -p nix grammar.y
  rm -f y.output
  if [ '$CHECK' = '--check' ]; then
    if ! diff -q /tmp/grammar.go grammar.go >/dev/null; then
      echo 'grammar.go is STALE: grammar.y changed and nobody regenerated it.' >&2
      echo 'Run: make generate-parser' >&2
      exit 1
    fi
    echo 'grammar.go is current'
  else
    cp /tmp/grammar.go grammar.go
    echo 'regenerated impl/go/nix/grammar.go'
  fi
"
