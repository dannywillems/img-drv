#!/usr/bin/env bash
#
# Run the Python implementation in the pinned container.
#
# Nothing is installed on the host: the library has no runtime dependencies, so
# this needs only the interpreter. Arguments are REPO-RELATIVE paths, because
# the repository is mounted at a fixed point inside the container.
#
# Usage: ./scripts/py.sh verify build/differential

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# shellcheck source=scripts/pins.env
. "$HERE/pins.env"

exec docker run --rm \
  -v "$REPO:/w" -w /w \
  -e PYTHONPATH=/w/impl/python/src \
  "$PY_IMAGE" python -m img_drv "$@"
