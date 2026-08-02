#!/usr/bin/env bash
#
# Build, lint and test the OCaml implementation, in the pinned container.
#
# One target, one command, run identically by CI and by a developer. The only
# prerequisite is docker.
#
# Usage: ./scripts/ml-check.sh [build|lint|test|format|all]

set -euo pipefail

WHAT="${1:-all}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# shellcheck source=scripts/pins.env
. "$HERE/pins.env"

case "$WHAT" in
  build)  cmd='dune build @all' ;;
  lint)   cmd='dune build @fmt' ;;
  test)   cmd='dune test' ;;
  format) cmd='dune build @fmt --auto-promote || true' ;;
  all)    cmd='dune build @fmt && dune build @all && dune test' ;;
  *)      echo "usage: $0 [build|lint|test|format|all]" >&2; exit 2 ;;
esac

# The opam switch lives in a NAMED VOLUME, initialised from the image on first
# use, so dune, alcotest, qcheck-alcotest and ocamlformat are installed once
# rather than once per run. The
# volume is a cache: it changes nothing about what is built, and a fresh CI
# runner simply pays the install once.
#
# Runs as root because the repository is mounted from the host with the host's
# ownership, and dune writes _build into the source tree.
exec docker run --rm \
  -v "$REPO:/w" -w /w/impl/ocaml \
  -v img-drv-opam:/home/opam/.opam \
  --user root \
  -e OPAMROOT=/home/opam/.opam \
  -e IMG_DRV_GOLDEN=/w/docs/spec/examples \
  "$ML_IMAGE" sh -c "
    eval \$(opam env --root=/home/opam/.opam) &&
    opam install -y --no-depexts dune alcotest qcheck-alcotest ocamlformat.0.29.0 >/dev/null 2>&1 || true
    eval \$(opam env --root=/home/opam/.opam) && $cmd
  "
