#!/usr/bin/env bash

set -euo pipefail

readonly repository_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
exec env RUSTC_WRAPPER= RUSTC_WORKSPACE_WRAPPER= xcrun --sdk macosx \
    cargo run \
    --quiet \
    --locked \
    --manifest-path "${repository_root}/scripts/Cargo.toml" \
    --bin validate-paid-developer-build-settings
