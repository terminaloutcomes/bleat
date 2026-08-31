#!/bin/zsh

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
readonly bleat_repository_root="${bleat_script_dir:h}"
readonly bleat_environment_script="${bleat_script_dir}/live-test-environment.sh"
readonly bleat_run_id="$(/usr/bin/uuidgen | tr '[:upper:]' '[:lower:]')"
readonly bleat_artifact_root="${bleat_repository_root}/TestSupport/ServerHarness/app-live-artifacts"
readonly bleat_artifact_dir="${bleat_artifact_root}/${bleat_run_id}"
readonly bleat_derived_data="${bleat_repository_root}/.build/live-xcode-derived-${bleat_run_id}"
readonly bleat_compose_project_name="bleat-app-live-${bleat_run_id}"
readonly bleat_https_prefix_port="${BLEAT_HTTPS_PREFIX_PORT:-13479}"
readonly bleat_abs_prefix_port="${BLEAT_ABS_PREFIX_PORT:-13379}"
readonly bleat_test_username="${BLEAT_TEST_USERNAME:-bleat-$(/usr/bin/uuidgen)}"
readonly bleat_test_password="${BLEAT_TEST_PASSWORD:-$(/usr/bin/uuidgen)}"
readonly bleat_device_type="${BLEAT_LIVE_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
readonly bleat_fault_proxy_script="${bleat_repository_root}/TestSupport/ServerHarness/download_fault_proxy.py"

bleat_simulator_id=""
bleat_ca_file=""
bleat_media_root=""
bleat_fault_proxy_pid=""
bleat_harness_started=0

bleat_require_result_bundle() {
    local result_bundle="$1"
    if [[ ! -f "${result_bundle}/Info.plist" ]]; then
        print -u2 "Expected complete result bundle at ${result_bundle}"
        return 1
    fi
    plutil -lint "${result_bundle}/Info.plist" >/dev/null
}

bleat_abort() {
    local exit_code="$1"
    trap - HUP INT QUIT TERM
    exit "${exit_code}"
}

bleat_cleanup() {
    local exit_code=$?
    trap - EXIT HUP INT QUIT TERM
    if (( exit_code != 0 && bleat_harness_started )); then
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
    if [[ -n "${bleat_fault_proxy_pid}" ]]; then
        kill "${bleat_fault_proxy_pid}" >/dev/null 2>&1 || true
        wait "${bleat_fault_proxy_pid}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${bleat_media_root}" ]]; then
        rm -rf "${bleat_media_root}"
    fi
    rm -rf "${bleat_derived_data}"
    if (( bleat_harness_started )); then
        "${bleat_environment_script}" down >/dev/null 2>&1 || true
    fi
    exit "${exit_code}"
}

trap bleat_cleanup EXIT
trap 'bleat_abort 129' HUP
trap 'bleat_abort 130' INT
trap 'bleat_abort 131' QUIT
trap 'bleat_abort 143' TERM

if [[ -n "${BLEAT_COMPOSE_PROJECT_NAME:-}" ]]; then
    print -u2 "BLEAT_COMPOSE_PROJECT_NAME is not supported by test-app-live.sh"
    exit 64
fi
if [[ -e "${bleat_artifact_dir}" || -e "${bleat_derived_data}" ]]; then
    print -u2 "Live app test workspace already exists for this run"
    exit 1
fi

mkdir -p "${bleat_artifact_dir}"
export BLEAT_COMPOSE_PROJECT_NAME="${bleat_compose_project_name}"

bleat_media_root="$(mktemp -d /tmp/bleat-app-live-media.XXXXXX)"
cp -R \
    "${bleat_repository_root}/TestSupport/ServerHarness/media/." \
    "${bleat_media_root}"
dd if=/dev/zero bs=1048576 count=34 \
    >> "${bleat_media_root}/multi-track/01.aac" \
    2>/dev/null
export BLEAT_MEDIA_ROOT="${bleat_media_root}"

bleat_fault_proxy_port="$(
    /usr/bin/python3 -c \
        'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
)"
/usr/bin/python3 "${bleat_fault_proxy_script}" \
    --listen-port "${bleat_fault_proxy_port}" \
    --upstream-host 127.0.0.1 \
    --upstream-port "${bleat_abs_prefix_port}" \
    > "${bleat_artifact_dir}/download-fault-proxy.log" \
    2>&1 &
bleat_fault_proxy_pid=$!
export BLEAT_PREFIX_UPSTREAM="host.docker.internal:${bleat_fault_proxy_port}"

for _ in {1..50}; do
    if curl --fail --silent \
        "http://127.0.0.1:${bleat_fault_proxy_port}/__bleat_fault__/health" \
        >/dev/null; then
        break
    fi
    sleep 0.1
done
curl --fail --silent --show-error \
    "http://127.0.0.1:${bleat_fault_proxy_port}/__bleat_fault__/health" \
    >/dev/null

export BLEAT_TEST_USERNAME="${bleat_test_username}"
export BLEAT_TEST_PASSWORD="${bleat_test_password}"
bleat_harness_started=1
"${bleat_environment_script}" reset

curl --fail --silent --show-error \
    --request POST \
    "http://127.0.0.1:${bleat_fault_proxy_port}/__bleat_fault__/arm" \
    >/dev/null

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
    BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
    BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
    BLEAT_CARPLAY_MODE="${BLEAT_CARPLAY_MODE:-disabled}" \
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

bleat_online_result_bundle="${bleat_artifact_dir}/online.xcresult"
bleat_offline_result_bundle="${bleat_artifact_dir}/offline.xcresult"
if [[ -e "${bleat_online_result_bundle}" || -e "${bleat_offline_result_bundle}" ]]; then
    print -u2 "Live app test result bundle already exists"
    exit 1
fi

xcodebuild \
    -quiet \
    -xctestrun "${bleat_xctestrun}" \
    -destination "id=${bleat_simulator_id}" \
    -parallel-testing-enabled NO \
    -resultBundlePath "${bleat_online_result_bundle}" \
    -only-testing:BleatUITests/BleatLiveUITests/testLiveOnlineLoginPlaybackAndDownload \
    test-without-building
bleat_require_result_bundle "${bleat_online_result_bundle}"

readonly bleat_401_evidence="${bleat_artifact_dir}/download-401-evidence.json"
curl --fail --silent --show-error \
    "http://127.0.0.1:${bleat_fault_proxy_port}/__bleat_fault__/evidence" \
    > "${bleat_401_evidence}"
jq --exit-status '
    ([.downloadEvents[] | select(.injected == true)]) as $faults
    | (
        [
            .downloadEvents[]
            | select(
                .sequence < $faults[0].sequence
                and .downloadKey == $faults[0].downloadKey
                and .rangeStart == 0
                and (.rangeEnd + 1) == $faults[0].rangeStart
            )
        ]
    ) as $committed
    | (
        [
            .downloadEvents[]
            | select(
                .sequence > $faults[0].sequence
                and .downloadKey == $faults[0].downloadKey
                and .range == $faults[0].range
            )
        ]
    ) as $replacements
    | .refreshEvents as $refreshes
    | ($faults | length) == 1
    and ($faults[0].status == 401)
    and ($faults[0].authorizationScheme == "Bearer")
    and ($faults[0].hasTokenQuery == false)
    and ($faults[0].ifRange | type == "string" and length > 0)
    and ($committed | length) == 1
    and ($committed[0].status == 206)
    and ($committed[0].injected == false)
    and ($committed[0].ifRange == null)
    and ($committed[0].authorizationScheme == "Bearer")
    and ($committed[0].hasTokenQuery == false)
    and ($replacements | length) == 1
    and ($replacements[0].injected == false)
    and ($replacements[0].ifRange == $faults[0].ifRange)
    and ($replacements[0].status == 206)
    and ($replacements[0].authorizationScheme == "Bearer")
    and ($replacements[0].hasTokenQuery == false)
    and .refreshCount == 1
    and ($refreshes | length) == 1
    and ($refreshes[0].sequence > $faults[0].sequence)
    and ($refreshes[0].sequence < $replacements[0].sequence)
' "${bleat_401_evidence}" >/dev/null

"${bleat_environment_script}" stop

xcodebuild \
    -quiet \
    -xctestrun "${bleat_xctestrun}" \
    -destination "id=${bleat_simulator_id}" \
    -parallel-testing-enabled NO \
    -resultBundlePath "${bleat_offline_result_bundle}" \
    -only-testing:BleatUITests/BleatLiveUITests/testLiveOfflineCachedDownloadAndLocalProgress \
    test-without-building
bleat_require_result_bundle "${bleat_offline_result_bundle}"
