#!/bin/zsh

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
readonly bleat_environment_script="${bleat_script_dir}/live-test-environment.sh"
source "${bleat_script_dir}/live-profile.sh"
if (( $# > 1 )) || [[ -n "${BLEAT_COMPOSE_PROJECT_NAME:-}" ]]; then
    print -u2 "Usage: scripts/test-live.sh [minimum|current-stable] (BLEAT_COMPOSE_PROJECT_NAME is managed by the runner)"
    exit 64
fi
bleat_select_live_profile "${1:-current-stable}"
readonly bleat_version_slug="${BLEAT_EXPECTED_SERVER_VERSION//./-}"
readonly bleat_run_id="$(/usr/bin/uuidgen | tr '[:upper:]' '[:lower:]')"
export BLEAT_COMPOSE_PROJECT_NAME="bleat-live-${BLEAT_LIVE_PROFILE_ID}-${bleat_version_slug}-${bleat_run_id}"
readonly bleat_root_port="${BLEAT_ABS_ROOT_PORT:-13378}"
readonly bleat_prefix_port="${BLEAT_ABS_PREFIX_PORT:-13379}"
readonly bleat_artifact_dir="${bleat_script_dir:h}/TestSupport/ServerHarness/artifacts/${BLEAT_LIVE_PROFILE_ID}-${BLEAT_EXPECTED_SERVER_VERSION}-${bleat_run_id}"
readonly bleat_test_username="${BLEAT_TEST_USERNAME:-bleat-$(/usr/bin/uuidgen)}"
readonly bleat_test_password="${BLEAT_TEST_PASSWORD:-$(/usr/bin/uuidgen)}"

bleat_cleanup() {
    local exit_code=$?
    trap - EXIT HUP INT TERM
    if (( exit_code != 0 )); then
        "${bleat_environment_script}" artifacts "${bleat_artifact_dir}" || true
    fi
    "${bleat_environment_script}" down || exit_code=1
    if [[ -n "$(docker ps --all --quiet --filter "label=com.docker.compose.project=${BLEAT_COMPOSE_PROJECT_NAME}")" \
        || -n "$(docker volume ls --quiet --filter "label=com.docker.compose.project=${BLEAT_COMPOSE_PROJECT_NAME}")" ]]; then
        print -u2 "Disposable compatibility resources remain after cleanup"
        exit_code=1
    fi
    exit "${exit_code}"
}

trap bleat_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

export BLEAT_TEST_USERNAME="${bleat_test_username}"
export BLEAT_TEST_PASSWORD="${bleat_test_password}"
"${bleat_environment_script}" reset

export BLEAT_LIVE_ROOT_URL="http://127.0.0.1:${bleat_root_port}"
export BLEAT_LIVE_PREFIX_URL="http://127.0.0.1:${bleat_prefix_port}/audiobookshelf"
export BLEAT_LIVE_USERNAME="${bleat_test_username}"
export BLEAT_LIVE_PASSWORD="${bleat_test_password}"

swift test --filter "${BLEAT_LIVE_TEST_FILTER:-BleatCoreLiveTests}"
