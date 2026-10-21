#!/usr/bin/env bash
set -euo pipefail
readonly bleat_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${bleat_script_dir}/.."
exec cargo run --quiet --locked --package scripts --bin xcode-test-runner -- paid-build-modes "$@"
