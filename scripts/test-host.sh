#!/bin/zsh
set -euo pipefail
readonly script_dir="${0:A:h}"
cd "${script_dir:h}"
exec cargo run --quiet --locked --package scripts --bin host-test-driver -- "$@"
