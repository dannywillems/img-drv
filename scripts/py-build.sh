#!/usr/bin/env bash
#
# Build the Python wheel and sdist in the pinned container, then check the
# metadata. A library nobody can install is not a library.
#
# Usage: ./scripts/py-build.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# shellcheck source=scripts/pins.env
. "$HERE/pins.env"

exec docker run --rm \
  -v "$REPO:/w" -w /w/impl/python \
  "$PY_IMAGE" sh -c '
    pip install -q --root-user-action=ignore build twine >/dev/null 2>&1
    python -m build --outdir dist . >/dev/null
    twine check dist/*
    ls -la dist/
  '
