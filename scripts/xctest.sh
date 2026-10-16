#!/bin/zsh
# Run a selected Xcode scheme and verify every test discovered from its built
# test products. See xcode-test-runner for the supported CLI options.

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
readonly bleat_repository_root="${bleat_script_dir:h}"
cd "${bleat_repository_root}"
exec cargo run --quiet --locked --package scripts --bin xcode-test-runner -- xctest "$@"
