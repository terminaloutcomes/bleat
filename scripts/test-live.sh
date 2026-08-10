#!/bin/zsh

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
readonly bleat_environment_script="${bleat_script_dir}/live-test-environment.sh"
readonly bleat_root_port="${BLEAT_ABS_ROOT_PORT:-13378}"
readonly bleat_prefix_port="${BLEAT_ABS_PREFIX_PORT:-13379}"
readonly bleat_oidc_https_port="${BLEAT_OIDC_HTTPS_PORT:-13480}"
readonly bleat_artifact_dir="${bleat_script_dir:h}/TestSupport/ServerHarness/artifacts"
readonly bleat_oidc_configuration_script="${bleat_script_dir}/configure-live-oidc.sh"
readonly bleat_ca_file="/tmp/bleat-live-caddy-ca.$$"
readonly bleat_test_username="${BLEAT_TEST_USERNAME:-bleat-$(/usr/bin/uuidgen)}"
readonly bleat_test_password="${BLEAT_TEST_PASSWORD:-$(/usr/bin/uuidgen)}"

bleat_cleanup() {
    local exit_code=$?
    if (( exit_code != 0 )); then
        "${bleat_environment_script}" artifacts "${bleat_artifact_dir}" || true
    fi
    "${bleat_environment_script}" down || true
    rm -f "${bleat_ca_file}"
    exit "${exit_code}"
}

trap bleat_cleanup EXIT INT TERM

export BLEAT_TEST_USERNAME="${bleat_test_username}"
export BLEAT_TEST_PASSWORD="${bleat_test_password}"
export BLEAT_LIVE_OIDC_USERNAME="bleat-oidc"
export BLEAT_LIVE_OIDC_PASSWORD="bleat-oidc-password"
"${bleat_environment_script}" reset
export BLEAT_LIVE_CA_CERT="${bleat_ca_file}"
"${bleat_environment_script}" ca "${bleat_ca_file}"
"${bleat_oidc_configuration_script}"

export BLEAT_LIVE_ROOT_URL="http://127.0.0.1:${bleat_root_port}"
export BLEAT_LIVE_PREFIX_URL="http://127.0.0.1:${bleat_prefix_port}/audiobookshelf"
export BLEAT_LIVE_USERNAME="${bleat_test_username}"
export BLEAT_LIVE_PASSWORD="${bleat_test_password}"
export BLEAT_LIVE_OIDC_HTTPS_PORT="${bleat_oidc_https_port}"

swift test --filter BleatCoreLiveTests
