#!/usr/bin/env bash
#
# Build, lint, vet and test the Go implementation, in the pinned container.
#
# One target, one command, run identically by CI and by a developer. The only
# prerequisite is docker.
#
# Usage: ./scripts/go-check.sh [build|lint|test|format|all]

set -euo pipefail

WHAT="${1:-all}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# shellcheck source=scripts/pins.env
. "$HERE/pins.env"

# gofmt -l prints the files it would change; failing on any output is how a
# formatting check is written without a --check flag.
# The command substitution must expand INSIDE the container, not here, so the
# single quotes are deliberate.
# shellcheck disable=SC2016
FMT='test -z "$(gofmt -l .)" || { gofmt -l .; echo "run: make format"; exit 1; }'
# go vet is the standard-library linter and is always on. staticcheck would
# need a dependency and a second pinned tool; vet plus -race covers the
# failure modes this crate can actually have.
VET='go vet ./...'

case "$WHAT" in
  build)  cmd='go build ./...' ;;
  lint)   cmd="$FMT && $VET" ;;
  test)   cmd='go test -race ./...' ;;
  format) cmd='gofmt -w .' ;;
  all)    cmd="$FMT && $VET && go test -race ./..." ;;
  *)      echo "usage: $0 [build|lint|test|format|all]" >&2; exit 2 ;;
esac

# GOFLAGS=-mod=mod is not set: the module has no dependencies, so -mod=readonly
# (the default) is exactly right and a dirty go.mod fails the build.
exec docker run --rm \
  -v "$REPO:/w" -w /w/impl/go \
  -e GOCACHE=/w/impl/go/.gocache \
  -e GOFLAGS=-mod=readonly \
  "$GO_IMAGE" sh -c "$cmd"
