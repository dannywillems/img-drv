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

# The IR core needs nothing installed. The PARSER needs PLY, which unlike
# menhir, LALRPOP and goyacc is a runtime dependency because it builds its
# tables at import time, so it is installed only for the command that uses it.
NEEDS_PLY=""
if [ "${1:-}" = "parsecheck" ] || [ "${1:-}" = "reparse" ]; then
  NEEDS_PLY="pip install --quiet --no-input --disable-pip-version-check --root-user-action=ignore ply &&"
fi

exec docker run --rm \
  -v "$REPO:/w" -w /w \
  -e PYTHONPATH=/w/impl/python/src \
  -e PYTHONDONTWRITEBYTECODE=1 \
  "$PY_IMAGE" sh -c "$NEEDS_PLY exec python -m img_drv $*"
