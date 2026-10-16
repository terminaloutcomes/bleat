#!/usr/bin/env bash

set -euo pipefail

readonly bleat_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly bleat_repository_root="$(cd -- "${bleat_script_dir}/.." && pwd)"
cd "${bleat_repository_root}"
exec cargo run --quiet --locked --package scripts --bin xcode-test-runner -- macos
