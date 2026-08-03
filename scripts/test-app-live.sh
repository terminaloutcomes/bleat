#!/bin/zsh

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
readonly bleat_repository_root="${bleat_script_dir:h}"
readonly bleat_environment_script="${bleat_script_dir}/live-test-environment.sh"
readonly bleat_artifact_dir="${bleat_repository_root}/TestSupport/ServerHarness/app-live-artifacts"
readonly bleat_derived_data="${bleat_repository_root}/.build/live-xcode-derived"
readonly bleat_https_prefix_port="${BLEAT_HTTPS_PREFIX_PORT:-13479}"
readonly bleat_test_username="${BLEAT_TEST_USERNAME:-bleat-$(/usr/bin/uuidgen)}"
readonly bleat_test_password="${BLEAT_TEST_PASSWORD:-$(/usr/bin/uuidgen)}"
readonly bleat_device_type="${BLEAT_LIVE_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"

bleat_simulator_id=""
bleat_ca_file=""

bleat_cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM
    if (( exit_code != 0 )); then
        "${bleat_environment_script}" artifacts "${bleat_artifact_dir}" \
            || true
        if [[ -n "${bleat_simulator_id}" ]]; then
            xcrun simctl io \
                "${bleat_simulator_id}" \
                screenshot \
                "${bleat_artifact_dir}/simulator-failure.png" \
                >/dev/null 2>&1 \
                || true
        fi
    fi
    if [[ -n "${bleat_simulator_id}" ]]; then
        xcrun simctl shutdown "${bleat_simulator_id}" >/dev/null 2>&1 \
            || true
        xcrun simctl delete "${bleat_simulator_id}" >/dev/null 2>&1 \
            || true
    fi
    if [[ -n "${bleat_ca_file}" ]]; then
        rm -f "${bleat_ca_file}"
    fi
    rm -rf "${bleat_derived_data}"
    "${bleat_environment_script}" down >/dev/null 2>&1 || true
    exit "${exit_code}"
}

trap bleat_cleanup EXIT INT TERM

rm -rf "${bleat_artifact_dir}"
rm -rf "${bleat_derived_data}"
mkdir -p "${bleat_artifact_dir}"

export BLEAT_TEST_USERNAME="${bleat_test_username}"
export BLEAT_TEST_PASSWORD="${bleat_test_password}"
"${bleat_environment_script}" reset

bleat_runtime="$(
    xcrun simctl list runtimes available --json \
        | jq --exit-status --raw-output \
            '[.runtimes[] | select(.name | startswith("iOS"))] | last | .identifier'
)"
if [[ -z "${bleat_runtime}" || "${bleat_runtime}" == "null" ]]; then
    print -u2 "No available iOS Simulator runtime was found"
    exit 1
fi

bleat_simulator_id="$(
    xcrun simctl create \
        "Bleat Live $$" \
        "${bleat_device_type}" \
        "${bleat_runtime}"
)"
xcrun simctl boot "${bleat_simulator_id}"
xcrun simctl bootstatus "${bleat_simulator_id}"

bleat_ca_file="$(mktemp /tmp/bleat-caddy-root.XXXXXX)"
"${bleat_environment_script}" ca "${bleat_ca_file}"
xcrun simctl keychain \
    "${bleat_simulator_id}" \
    add-root-cert \
    "${bleat_ca_file}"

export BLEAT_LIVE_APP_URL="https://localhost:${bleat_https_prefix_port}/audiobookshelf"
export BLEAT_LIVE_USERNAME="${bleat_test_username}"
export BLEAT_LIVE_PASSWORD="${bleat_test_password}"

xcodebuild \
    -quiet \
    -project "${bleat_repository_root}/Bleat.xcodeproj" \
    -scheme Bleat \
    -destination "id=${bleat_simulator_id}" \
    -derivedDataPath "${bleat_derived_data}" \
    -parallel-testing-enabled NO \
    BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
    build-for-testing

bleat_xctestrun="$(
    find "${bleat_derived_data}/Build/Products" \
        -name '*.xctestrun' \
        -print \
        -quit
)"
if [[ -z "${bleat_xctestrun}" ]]; then
    print -u2 "Xcode did not produce an xctestrun file"
    exit 1
fi
plutil -insert \
    'BleatUITests.EnvironmentVariables.BLEAT_LIVE_APP_URL' \
    -string "${BLEAT_LIVE_APP_URL}" \
    "${bleat_xctestrun}"
plutil -insert \
    'BleatUITests.EnvironmentVariables.BLEAT_LIVE_USERNAME' \
    -string "${BLEAT_LIVE_USERNAME}" \
    "${bleat_xctestrun}"
plutil -insert \
    'BleatUITests.EnvironmentVariables.BLEAT_LIVE_PASSWORD' \
    -string "${BLEAT_LIVE_PASSWORD}" \
    "${bleat_xctestrun}"

xcodebuild \
    -quiet \
    -xctestrun "${bleat_xctestrun}" \
    -destination "id=${bleat_simulator_id}" \
    -parallel-testing-enabled NO \
    -resultBundlePath "${bleat_artifact_dir}/online.xcresult" \
    -only-testing:BleatUITests/BleatLiveUITests/testLiveOnlineLoginPlaybackAndDownload \
    test-without-building

"${bleat_environment_script}" stop

xcodebuild \
    -quiet \
    -xctestrun "${bleat_xctestrun}" \
    -destination "id=${bleat_simulator_id}" \
    -parallel-testing-enabled NO \
    -resultBundlePath "${bleat_artifact_dir}/offline.xcresult" \
    -only-testing:BleatUITests/BleatLiveUITests/testLiveOfflineCachedDownloadAndLocalProgress \
    test-without-building
