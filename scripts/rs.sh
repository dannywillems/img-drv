#!/usr/bin/env bash
#
# Run the Rust implementation in the pinned container.
#
# Arguments are REPO-RELATIVE paths, because the repository is mounted at a
# fixed point inside the container. Mirrors scripts/py.sh so the two
# implementations are driven identically.
#
# Usage: ./scripts/rs.sh verify build/differential

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# shellcheck source=scripts/pins.env
. "$HERE/pins.env"

exec docker run --rm \
  -v "$REPO:/w" -w /w \
  -e CARGO_HOME=/w/impl/rust/.cargo-home \
  "$RS_IMAGE" sh -c \
  "cargo run --quiet --locked --manifest-path impl/rust/Cargo.toml \
     --bin img-drv -- $*"
