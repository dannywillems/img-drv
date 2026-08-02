#!/usr/bin/env bash
#
# Run the OCaml implementation in the pinned container.
#
# The directory argument is REPO-RELATIVE. Like scripts/go.sh, the working
# directory inside the container has to be the project root for dune to resolve,
# so the path is rewritten to an absolute one.
#
# Usage: ./scripts/ml.sh verify build/differential

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <command> <repo-relative-directory>" >&2
  exit 2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# shellcheck source=scripts/pins.env
. "$HERE/pins.env"

# The install line is not redundant with ml-check.sh. The opam cache volume is
# warm on a laptop and cold on a fresh CI runner, and this script has to work on
# both: without it, conformance fails with "dune: not found" only in CI, which
# is the worst place to find out.
exec docker run --rm \
  -v "$REPO:/w" -w /w/impl/ocaml \
  -v img-drv-opam:/home/opam/.opam \
  --user root \
  -e OPAMROOT=/home/opam/.opam \
  "$ML_IMAGE" sh -c "
    eval \$(opam env --root=/home/opam/.opam) &&
    opam install -y --no-depexts dune alcotest >/dev/null 2>&1 || true
    eval \$(opam env --root=/home/opam/.opam) &&
    dune exec --no-build-info -- ./bin/main.exe $1 /w/$2
  "
