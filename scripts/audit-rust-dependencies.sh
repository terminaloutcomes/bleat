#!/usr/bin/env bash

set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
cd "${repository_root}"

exec cargo run --quiet --locked --package scripts --bin audit-rust-dependencies -- "$@"
