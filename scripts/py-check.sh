#!/usr/bin/env bash
#
# Lint, type-check and test the Python implementation, in the pinned container.
#
# One target, one command, run identically by CI and by a developer. Which is
# why it installs its own dev dependencies rather than assuming a machine has
# them: the only prerequisite is docker.
#
# Usage: ./scripts/py-check.sh [lint|test|format|all]

set -euo pipefail

WHAT="${1:-all}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# shellcheck source=scripts/pins.env
. "$HERE/pins.env"

case "$WHAT" in
  lint) cmd='ruff check . && ruff format --check . && mypy' ;;
  test) cmd='pytest' ;;
  format) cmd='ruff format . && ruff check --fix .' ;;
  all)  cmd='ruff check . && ruff format --check . && mypy && pytest' ;;
  *)    echo "usage: $0 [lint|test|format|all]" >&2; exit 2 ;;
esac

exec docker run --rm \
  -v "$REPO:/w" -w /w/impl/python \
  "$PY_IMAGE" sh -c "
    pip install -q --root-user-action=ignore -e '.[nix]' pytest hypothesis \
      mypy ruff >/dev/null 2>&1
    $cmd
  "
