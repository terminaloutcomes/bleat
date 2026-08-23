#!/usr/bin/env zsh

set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
cd "${repository_root}"

if cargo tree \
  --manifest-path bleat-api/Cargo.toml \
  --edges features \
  --invert rkyv 2>/dev/null \
  | rg -q '^rkyv '
then
  print -u2 \
    "RUSTSEC-2026-0235 may only be ignored while rkyv is absent from the enabled feature graph"
  exit 1
fi

cargo audit \
  --file bleat-api/Cargo.lock \
  --deny yanked
