#!/bin/zsh

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
readonly bleat_environment_script="${bleat_script_dir}/live-test-environment.sh"
readonly bleat_root_port="${BLEAT_ABS_ROOT_PORT:-13378}"
readonly bleat_prefix_port="${BLEAT_ABS_PREFIX_PORT:-13379}"
readonly bleat_artifact_dir="${bleat_script_dir:h}/TestSupport/ServerHarness/artifacts"
readonly bleat_test_username="${BLEAT_TEST_USERNAME:-bleat-root}"
readonly bleat_test_password="${BLEAT_TEST_PASSWORD:-bleat-test-only}"

bleat_cleanup() {
    local exit_code=$?
    if (( exit_code != 0 )); then
        "${bleat_environment_script}" artifacts "${bleat_artifact_dir}" || true
    fi
    "${bleat_environment_script}" down || true
    exit "${exit_code}"
}

trap bleat_cleanup EXIT INT TERM

"${bleat_environment_script}" reset

export BLEAT_LIVE_ROOT_URL="http://127.0.0.1:${bleat_root_port}"
export BLEAT_LIVE_PREFIX_URL="http://127.0.0.1:${bleat_prefix_port}/audiobookshelf"
export BLEAT_LIVE_USERNAME="${bleat_test_username}"
export BLEAT_LIVE_PASSWORD="${bleat_test_password}"

swift test --filter BleatCoreLiveTests
