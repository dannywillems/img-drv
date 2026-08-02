#!/usr/bin/env bash
#
# Build, lint, type-check and test the Rust implementation, in the pinned
# container.
#
# One target, one command, run identically by CI and by a developer. The only
# prerequisite is docker; the toolchain is the pinned image, so the
# rust-toolchain.toml channel never triggers a download.
#
# Usage: ./scripts/rs-check.sh [build|lint|test|format|all]

set -euo pipefail

WHAT="${1:-all}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# shellcheck source=scripts/pins.env
. "$HERE/pins.env"

FMT='cargo fmt --check'
LINT='cargo clippy --all-targets --all-features -- -D warnings'

case "$WHAT" in
  build)  cmd='cargo build --release --locked' ;;
  lint)   cmd="$FMT && $LINT" ;;
  test)   cmd='cargo test --locked' ;;
  format) cmd='cargo fmt' ;;
  all)    cmd="$FMT && $LINT && cargo test --locked" ;;
  *)      echo "usage: $0 [build|lint|test|format|all]" >&2; exit 2 ;;
esac

# Two caches, neither of which affects WHAT is built:
#   - CARGO_HOME in the working tree, so the crates.io index and the registry
#     survive between runs (target/ likewise). Both are gitignored.
#   - a named volume for rustup, because rust-toolchain.toml asks for rustfmt
#     and clippy and the slim image ships neither. A named volume initialises
#     from the image on first use, so the components download once instead of
#     once per invocation. On a fresh CI runner that is simply one download.
exec docker run --rm \
  -v "$REPO:/w" -w /w/impl/rust \
  -v img-drv-rustup:/usr/local/rustup \
  -e CARGO_HOME=/w/impl/rust/.cargo-home \
  "$RS_IMAGE" sh -c "$cmd"
