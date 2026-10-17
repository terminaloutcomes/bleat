#!/bin/zsh

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
readonly bleat_repository_root="${bleat_script_dir:h}"
cd "${bleat_repository_root}"
exec cargo run --quiet --locked --package scripts --bin xcode-test-runner -- core
