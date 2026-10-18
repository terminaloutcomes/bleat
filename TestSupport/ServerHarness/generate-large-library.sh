#!/bin/zsh
# Usage: BLEAT_LARGE_LIBRARY_COUNT=10000 generate-large-library.sh [output-dir]
set -euo pipefail
bleat_repository_root="${BLEAT_REPOSITORY_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
exec cargo run --quiet --locked --manifest-path "${bleat_repository_root}/Cargo.toml" \
    --package scripts --bin generate-large-library -- --root "${bleat_repository_root}" "$@"
