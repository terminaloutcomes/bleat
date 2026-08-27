#!/bin/zsh

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
readonly bleat_repository_root="${bleat_script_dir:h}"
readonly bleat_environment_script="${bleat_script_dir}/live-test-environment.sh"
readonly bleat_run_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
readonly bleat_private_root="$(mktemp -d /tmp/bleat-release-secret-scan.XXXXXX)"
readonly bleat_report_root="${bleat_repository_root}/.build/release-secret-scan"
readonly bleat_derived_data="${bleat_repository_root}/.build/release-secret-compile"
readonly bleat_result_root="${bleat_private_root}/results"
readonly bleat_process_root="${bleat_private_root}/process-output"
readonly bleat_scan_root="${bleat_private_root}/surfaces"
readonly bleat_secret_root="${bleat_private_root}/sentinels"
readonly bleat_archive_path="${bleat_private_root}/Bleat.xcarchive"
readonly bleat_live_project="bleat-secret-scan-${bleat_run_id}"
readonly bleat_telemetry_project="bleat-secret-telemetry-${bleat_run_id}"
readonly bleat_telemetry_compose="${bleat_repository_root}/bleat-api/compose.yml"
readonly bleat_telemetry_capture="${bleat_private_root}/telemetry-capture"
readonly bleat_secret_broker_path="/v1/private-test-secret/${bleat_run_id}"
readonly bleat_device_type="${BLEAT_LIVE_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
readonly bleat_bundle_id="${BUNDLE_ID_PREFIX:-com.terminaloutcomes}.Bleat"
readonly bleat_port_base="$((31000 + RANDOM % 15000))"

export BLEAT_ABS_ROOT_PORT="${bleat_port_base}"
export BLEAT_ABS_PREFIX_PORT="$((bleat_port_base + 1))"
export BLEAT_HTTPS_ROOT_PORT="$((bleat_port_base + 2))"
export BLEAT_HTTPS_PREFIX_PORT="$((bleat_port_base + 3))"
export BLEAT_OIDC_HTTPS_PORT="$((bleat_port_base + 4))"
export BLEAT_TELEMETRY_AUTH_HTTPS_PORT="$((bleat_port_base + 5))"
export BLEAT_TELEMETRY_OTLP_HTTPS_PORT="$((bleat_port_base + 6))"
export BLEAT_API_TEST_PORT="$((bleat_port_base + 7))"
export BLEAT_TELEMETRY_COLLECTOR_TEST_PORT="$((bleat_port_base + 8))"
export BLEAT_TELEMETRY_COLLECTOR_HEALTH_TEST_PORT="$((bleat_port_base + 9))"
export BLEAT_TELEMETRY_CAPTURE_DIRECTORY="${bleat_telemetry_capture}"
export BLEAT_SECRET_BROKER_TEST_PORT="$((bleat_port_base + 10))"
export BLEAT_SECRET_BROKER_HTTPS_PORT="$((bleat_port_base + 11))"
export BLEAT_API_POSTGRES_PASSWORD="telemetry-${bleat_run_id}"
export BLEAT_API_PUBLIC_ISSUER="http://host.docker.internal:${BLEAT_API_TEST_PORT}"
export BLEAT_COMPOSE_PROJECT_NAME="${bleat_live_project}"
export BLEAT_TEST_USERNAME="bleat-${bleat_run_id}"
export BLEAT_TEST_PASSWORD="$(uuidgen | tr '[:upper:]' '[:lower:]')-$(uuidgen | tr '[:upper:]' '[:lower:]')!+/%"
export BLEAT_LIVE_APP_URL="https://localhost:${BLEAT_HTTPS_PREFIX_PORT}/audiobookshelf"
export BLEAT_LIVE_USERNAME="${BLEAT_TEST_USERNAME}"
export TEST_RUNNER_BLEAT_LIVE_APP_URL="${BLEAT_LIVE_APP_URL}"
export TEST_RUNNER_BLEAT_LIVE_USERNAME="${BLEAT_LIVE_USERNAME}"
export TEST_RUNNER_BLEAT_RELEASE_SECRET_SCAN=1
export TEST_RUNNER_BLEAT_RELEASE_SECRET_BROKER_URL="https://localhost:${BLEAT_SECRET_BROKER_HTTPS_PORT}${bleat_secret_broker_path}"

bleat_simulator_id=""
bleat_ca_file=""
bleat_harness_started=0
bleat_telemetry_started=0
bleat_succeeded=0
bleat_cleaning=0
bleat_secret_broker_pid=""
bleat_stage="initialization"

bleat_cleanup() {
    local exit_code="${1:-$?}"
    if [[ "${bleat_cleaning}" == "1" ]]; then
        return
    fi
    bleat_cleaning=1
    trap - EXIT HUP INT QUIT TERM
    if [[ "${bleat_succeeded}" != "1" ]]; then
        print -u2 "Release secret-leakage gate failed at stage: ${bleat_stage}"
        mkdir -p "${bleat_report_root}"
        jq --null-input \
            --arg status failed \
            --arg stage "${bleat_stage}" \
            --arg command "mise run test:release-secrets" \
            '{status: $status, failedStage: $stage, command: $command}' \
            >"${bleat_report_root}/failure.json"
        typeset -a completed_results
        completed_results=("${bleat_result_root}"/*.tests.json(N))
        if (( ${#completed_results} )); then
            jq --slurp 'add' "${completed_results[@]}" \
                >"${bleat_report_root}/failure-tests.json" || true
        fi
    fi
    if [[ -n "${bleat_simulator_id}" ]]; then
        xcrun simctl shutdown "${bleat_simulator_id}" >/dev/null 2>&1 || true
        xcrun simctl delete "${bleat_simulator_id}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${bleat_secret_broker_pid}" ]]; then
        kill "${bleat_secret_broker_pid}" >/dev/null 2>&1 || true
        wait "${bleat_secret_broker_pid}" >/dev/null 2>&1 || true
    fi
    if (( bleat_harness_started )); then
        "${bleat_environment_script}" down >/dev/null 2>&1 || true
    fi
    if (( bleat_telemetry_started )); then
        docker compose --project-name "${bleat_telemetry_project}" \
            --file "${bleat_telemetry_compose}" \
            down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi
    [[ -z "${bleat_ca_file}" ]] || rm -f "${bleat_ca_file}"
    case "${bleat_private_root}" in
        /tmp/bleat-release-secret-scan.*) rm -rf "${bleat_private_root}" ;;
    esac
    unset BLEAT_TEST_PASSWORD BLEAT_API_POSTGRES_PASSWORD
    exit "${exit_code}"
}

trap bleat_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 131' QUIT
trap 'exit 143' TERM

bleat_verify_result() {
    local result_bundle="$1"
    local test_id="$2"
    local output="$3"
    xcrun xcresulttool get test-results tests \
        --path "${result_bundle}" --format json \
        | jq --exit-status \
            --arg test_id "${test_id##*/}" '
                [.. | objects
                    | select(.nodeType? == "Test Case")
                    | {
                        name: .name,
                        result: .result,
                        duration: (.duration // null),
                        failures: [.. | objects
                            | select(.nodeType? == "Failure Message")
                            | .name]
                    }
                ] as $tests
                | ($tests | length) == 1
                    and $tests[0].result == "Passed"
                    and ($tests[0].name | contains($test_id))
            ' >/dev/null
    xcrun xcresulttool get test-results tests \
        --path "${result_bundle}" --format json \
        | jq '[.. | objects
            | select(.nodeType? == "Test Case")
            | {
                name: .name,
                result: .result,
                duration: (.duration // null),
                failures: [.. | objects
                    | select(.nodeType? == "Failure Message")
                    | .name]
            }
        ]' >"${output}"
}

bleat_run_test() {
    local label="$1"
    local test_id="$2"
    local result_bundle="${bleat_result_root}/${label}.xcresult"
    local process_output="${bleat_process_root}/${label}.log"
    bleat_stage="test ${test_id}"
    print "Running ${test_id}"
    set +e
    xcodebuild -quiet \
        -xctestrun "${bleat_xctestrun}" \
        -destination "id=${bleat_simulator_id}" \
        -parallel-testing-enabled NO \
        -maximum-parallel-testing-workers 1 \
        -resultBundlePath "${result_bundle}" \
        -only-testing:"${test_id}" \
        test-without-building >"${process_output}" 2>&1
    local test_exit=$?
    set -e
    if [[ -d "${result_bundle}" ]]; then
        xcrun xcresulttool get test-results tests \
            --path "${result_bundle}" --format json \
            | jq '[.. | objects
                | select(.nodeType? == "Test Case")
                | {
                    name: .name,
                    result: .result,
                    duration: (.duration // null),
                    failures: [.. | objects
                        | select(.nodeType? == "Failure Message")
                        | .name]
                }
            ]' >"${bleat_result_root}/${label}.tests.json" || true
    fi
    if (( test_exit != 0 )); then
        bleat_cleanup "${test_exit}"
    fi
    if ! bleat_verify_result \
        "${result_bundle}" "${test_id}" \
        "${bleat_result_root}/${label}.tests.json"; then
        bleat_cleanup 1
    fi
}

for command in docker jq python3 xcodebuild xcrun uuidgen; do
    command -v "${command}" >/dev/null \
        || { print -u2 "Required command is unavailable: ${command}"; exit 1; }
done

chmod 700 "${bleat_private_root}"
rm -rf "${bleat_report_root}"
mkdir -p "${bleat_report_root}" "${bleat_result_root}" \
    "${bleat_process_root}" "${bleat_scan_root}" "${bleat_secret_root}" \
    "${bleat_telemetry_capture}"

bleat_stage="scanner self-test"
python3 -m unittest Tests.ScriptTests.test_scan_release_secrets
jq --null-input --arg value "${BLEAT_TEST_PASSWORD}" \
    '{secrets: [{label: "password", value: $value}]}' \
    >"${bleat_secret_root}/password.json"
python3 "${bleat_script_dir}/serve-private-test-secret.py" \
    --manifest "${bleat_secret_root}/password.json" \
    --label password \
    --path "${bleat_secret_broker_path}" \
    --port "${BLEAT_SECRET_BROKER_TEST_PORT}" \
    >"${bleat_process_root}/secret-broker.log" 2>&1 &
bleat_secret_broker_pid=$!
for _ in {1..30}; do
    curl --silent --fail \
        "http://127.0.0.1:${BLEAT_SECRET_BROKER_TEST_PORT}/health" \
        >/dev/null 2>&1 && break
    sleep 0.1
done
curl --silent --fail \
    "http://127.0.0.1:${BLEAT_SECRET_BROKER_TEST_PORT}/health" \
    >/dev/null

bleat_stage="telemetry environment startup"
bleat_telemetry_started=1
docker compose --project-name "${bleat_telemetry_project}" \
    --file "${bleat_telemetry_compose}" \
    up --detach --build --wait api
docker compose --project-name "${bleat_telemetry_project}" \
    --file "${bleat_telemetry_compose}" \
    up --detach telemetry-collector
for _ in {1..60}; do
    curl --silent --fail \
        "http://127.0.0.1:${BLEAT_TELEMETRY_COLLECTOR_HEALTH_TEST_PORT}/" \
        >/dev/null 2>&1 && break
    sleep 1
done
curl --silent --fail \
    "http://127.0.0.1:${BLEAT_TELEMETRY_COLLECTOR_HEALTH_TEST_PORT}/" \
    >/dev/null

bleat_stage="Audiobookshelf environment startup"
bleat_harness_started=1
"${bleat_environment_script}" reset

bleat_stage="Simulator creation"
bleat_runtime="$(
    xcrun simctl list runtimes available --json \
        | jq --exit-status --raw-output \
            '[.runtimes[] | select(.name | startswith("iOS"))] | last | .identifier'
)"
bleat_simulator_id="$(
    xcrun simctl create \
        "Bleat Release Secret Scan $$" "${bleat_device_type}" "${bleat_runtime}"
)"
xcrun simctl boot "${bleat_simulator_id}"
xcrun simctl bootstatus "${bleat_simulator_id}" -b
bleat_ca_file="$(mktemp /tmp/bleat-secret-caddy-root.XXXXXX)"
"${bleat_environment_script}" ca "${bleat_ca_file}"
xcrun simctl keychain "${bleat_simulator_id}" add-root-cert "${bleat_ca_file}"

bleat_stage="Release build-for-testing"
print "Building the Release-Simulator journey"
xcodebuild -quiet \
    -project "${bleat_repository_root}/Bleat.xcodeproj" \
    -scheme Bleat \
    -configuration Release \
    -destination "id=${bleat_simulator_id}" \
    -derivedDataPath "${bleat_derived_data}" \
    -parallel-testing-enabled NO \
    ENABLE_TESTABILITY=YES \
    BUILD_WITHOUT_PAID_DEVELOPER=YES \
    BLEAT_APP_ATTEST_MODE=disabled \
    BLEAT_CLOUDKIT_MODE=disabled \
    BLEAT_TELEMETRY_ATTESTER_MODE=fake \
    BLEAT_TELEMETRY_AUTH_BASE_URL="https://localhost:${BLEAT_TELEMETRY_AUTH_HTTPS_PORT}" \
    BLEAT_TELEMETRY_OTLP_ENDPOINT="https://localhost:${BLEAT_TELEMETRY_OTLP_HTTPS_PORT}" \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) BLEAT_RELEASE_SECRET_SCAN' \
    build-for-testing >"${bleat_process_root}/build-for-testing.log" 2>&1

bleat_xctestrun="$(
    find "${bleat_derived_data}/Build/Products" -name '*.xctestrun' -print -quit
)"
[[ -n "${bleat_xctestrun}" ]] \
    || { print -u2 "Release build did not produce an xctestrun"; exit 1; }

bleat_run_test online \
    BleatUITests/BleatLiveUITests/testLiveOnlineLoginPlaybackAndDownload
bleat_run_test capture-initial \
    BleatAppTests/ReleaseSecretLeakageTests/testCaptureInitialTokensAndForceRefresh
bleat_run_test refresh \
    BleatUITests/BleatLiveUITests/testReleaseSecretScanRefreshAfterTokenInvalidation
bleat_run_test capture-rotated \
    BleatAppTests/ReleaseSecretLeakageTests/testCaptureRotatedTokens

bleat_stage="private token manifest extraction"
bleat_data_container="$(
    xcrun simctl get_app_container \
        "${bleat_simulator_id}" "${bleat_bundle_id}" data
)"
bleat_capture_directory="${bleat_data_container}/Library/Application Support/Bleat/ReleaseSecretScan"
cp "${bleat_capture_directory}/initial.json" "${bleat_secret_root}/initial.json"
cp "${bleat_capture_directory}/rotated.json" "${bleat_secret_root}/rotated.json"
bleat_run_test remove-private-capture \
    BleatAppTests/ReleaseSecretLeakageTests/testRemovePrivateCapture

bleat_stage="offline restoration journey"
docker compose --project-name "${bleat_live_project}" \
    --file "${bleat_repository_root}/TestSupport/ServerHarness/compose.yaml" \
    stop audiobookshelf-root audiobookshelf-prefix keycloak
bleat_run_test offline \
    BleatUITests/BleatLiveUITests/testLiveOfflineCachedDownloadAndLocalProgress
docker compose --project-name "${bleat_live_project}" \
    --file "${bleat_repository_root}/TestSupport/ServerHarness/compose.yaml" \
    up --detach --wait audiobookshelf-root audiobookshelf-prefix
"${bleat_environment_script}" wait
bleat_run_test logout \
    BleatUITests/BleatLiveUITests/testReleaseSecretScanLogout
bleat_run_test logout-session-keychain \
    BleatAppTests/ReleaseSecretLeakageTests/testLogoutRemovedSessionCredentials
bleat_run_test logout-private-capture \
    BleatAppTests/ReleaseSecretLeakageTests/testPrivateCaptureRemainsRemovedAfterLogout

bleat_stage="runtime artifact collection"
bleat_data_container="$(
    xcrun simctl get_app_container \
        "${bleat_simulator_id}" "${bleat_bundle_id}" data
)"
mkdir -p "${bleat_scan_root}/runtime-logs" \
    "${bleat_scan_root}/app-container" \
    "${bleat_scan_root}/server-artifacts"
xcrun simctl spawn "${bleat_simulator_id}" log collect \
    --output "${bleat_scan_root}/runtime-logs/Bleat.logarchive" \
    --last 30m >"${bleat_process_root}/log-collect.log" 2>&1
ditto "${bleat_data_container}" "${bleat_scan_root}/app-container"
"${bleat_environment_script}" artifacts \
    "${bleat_scan_root}/server-artifacts"
docker compose --project-name "${bleat_telemetry_project}" \
    --file "${bleat_telemetry_compose}" logs --no-color \
    >"${bleat_scan_root}/server-artifacts/telemetry-compose.log" 2>&1

bleat_stage="telemetry evidence verification"
for _ in {1..30}; do
    [[ -s "${bleat_telemetry_capture}/traces.json" \
        && -s "${bleat_telemetry_capture}/logs.json" ]] && break
    sleep 1
done
test -s "${bleat_telemetry_capture}/traces.json"
test -s "${bleat_telemetry_capture}/logs.json"
jq --slurp --exit-status '
    ([.. | objects | select(.key? == "service.name"
        and .value.stringValue? == "bleat")] | length) >= 1
    and ([.. | objects
        | select((.name? | type) == "string")
        | select(.name | startswith("bleat."))] | length) >= 1
' "${bleat_telemetry_capture}/traces.json" >/dev/null

bleat_stage="unsigned Release archive"
print "Creating and inspecting the normal unsigned Release archive"
BLEAT_ARCHIVE_PATH="${bleat_archive_path}" \
BUILD_WITHOUT_PAID_DEVELOPER=YES \
BLEAT_APP_ATTEST_MODE=disabled \
BLEAT_CLOUDKIT_MODE=disabled \
BLEAT_TELEMETRY_AUTH_BASE_URL="https://localhost:${BLEAT_TELEMETRY_AUTH_HTTPS_PORT}" \
BLEAT_TELEMETRY_OTLP_ENDPOINT="https://localhost:${BLEAT_TELEMETRY_OTLP_HTTPS_PORT}" \
    "${bleat_script_dir}/archive-beta.sh" \
    >"${bleat_process_root}/archive.log" 2>&1

bleat_stage="prohibited surface scan"
python3 "${bleat_script_dir}/scan-release-secrets.py" \
    --manifest "${bleat_secret_root}/password.json" \
    --manifest "${bleat_secret_root}/initial.json" \
    --manifest "${bleat_secret_root}/rotated.json" \
    --redact-surface "server-artifacts=${bleat_scan_root}/server-artifacts" \
    --surface "process-output=${bleat_process_root}" \
    --surface "xcresult-bundles=${bleat_result_root}" \
    --surface "unified-logs=${bleat_scan_root}/runtime-logs" \
    --surface "app-owned-data=${bleat_scan_root}/app-container" \
    --surface "server-artifacts=${bleat_scan_root}/server-artifacts" \
    --surface "remote-telemetry=${bleat_telemetry_capture}" \
    --surface "release-test-products=${bleat_derived_data}/Build/Products" \
    --surface "release-archive=${bleat_archive_path}" \
    --report "${bleat_report_root}/scan.json"

bleat_stage="evidence report"
jq --slurp 'add' "${bleat_result_root}"/*.tests.json \
    >"${bleat_report_root}/tests.json"
bleat_version="$(
    awk '$1 == "MARKETING_VERSION:" {gsub(/"/, "", $2); print $2; exit}' \
        "${bleat_repository_root}/project.yml"
)"
bleat_build="$(
    awk '$1 == "CURRENT_PROJECT_VERSION:" {gsub(/"/, "", $2); print $2; exit}' \
        "${bleat_repository_root}/project.yml"
)"
bleat_commit="$(git -C "${bleat_repository_root}" rev-parse HEAD)"
bleat_platform="$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
bleat_runtime_name="$(
    xcrun simctl list runtimes --json \
        | jq --raw-output --arg id "${bleat_runtime}" \
            '.runtimes[] | select(.identifier == $id) | .name + " " + .version'
)"
jq --null-input \
    --slurpfile scan "${bleat_report_root}/scan.json" \
    --slurpfile tests "${bleat_report_root}/tests.json" \
    --arg status passed \
    --arg sourceCommit "${bleat_commit}" \
    --arg applicationVersion "${bleat_version}" \
    --arg applicationBuild "${bleat_build}" \
    --arg platform "${bleat_platform}; ${bleat_runtime_name}" \
    --arg command "mise run test:release-secrets" \
    '{
        status: $status,
        sourceCommit: $sourceCommit,
        applicationVersion: $applicationVersion,
        applicationBuild: $applicationBuild,
        platform: $platform,
        command: $command,
        executedTestCount: ($tests[0] | length),
        tests: $tests[0],
        scannedSurfaces: $scan[0].surfaceLabels,
        scannedFileCount: $scan[0].scannedFileCount,
        scannedByteCount: $scan[0].scannedByteCount,
        serverArtifactRedactionCount: $scan[0].redactionCount,
        findingCount: $scan[0].findingCount
    }' >"${bleat_report_root}/report.json"

rm -f "${bleat_report_root}/failure.json"
bleat_succeeded=1
print "Release secret-leakage gate passed."
print "Evidence report: .build/release-secret-scan/report.json"
