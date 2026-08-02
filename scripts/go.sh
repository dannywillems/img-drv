#!/usr/bin/env bash
#
# Run the Go implementation in the pinned container.
#
# The directory argument is REPO-RELATIVE, because the repository is mounted at
# a fixed point inside the container. Mirrors scripts/py.sh and scripts/rs.sh so
# the three implementations are driven identically.
#
# Unlike those two, the working directory inside the container has to be the
# module root for `go run ./cmd/img-drv` to resolve, so the path argument is
# rewritten to an absolute one rather than left relative.
#
# Usage: ./scripts/go.sh verify build/differential

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <command> <repo-relative-directory>" >&2
  exit 2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# shellcheck source=scripts/pins.env
. "$HERE/pins.env"

exec docker run --rm \
  -v "$REPO:/w" -w /w/impl/go \
  -e GOCACHE=/w/impl/go/.gocache \
  "$GO_IMAGE" go run ./cmd/img-drv "$1" "/w/$2"
