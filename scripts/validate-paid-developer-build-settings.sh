#!/usr/bin/env bash

set -euo pipefail

if ! command -v cargo >/dev/null 2>&1; then
    echo "Cargo is not installed. Please install Rust and Cargo." >&2
    exit 1
fi

readonly repository_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# env -u works around weirdness with the SDKROOT environment variable in the build env
env -u SDKROOT \
    cargo run \
    --quiet \
    --manifest-path "${repository_root}/scripts/Cargo.toml" \
    --bin validate-paid-developer-build-settings
