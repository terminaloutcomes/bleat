#!/usr/bin/env zsh
set -euo pipefail

cargo test \
  --locked \
  --manifest-path bleat-api/Cargo.toml \
  --all-features \
  -- \
  --nocapture \
  --test-threads=4
