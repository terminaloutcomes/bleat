#!/usr/bin/env bash

set -euo pipefail

readonly repository_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
exec cargo run \
    --quiet \
    --locked \
    --manifest-path "${repository_root}/build-scripts/Cargo.toml" \
    --bin validate-paid-developer-build-settings
