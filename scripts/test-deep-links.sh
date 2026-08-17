#!/bin/zsh

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
readonly bleat_repository_root="${bleat_script_dir:h}"
readonly bleat_run_id="$(/usr/bin/uuidgen | tr '[:upper:]' '[:lower:]')"
readonly bleat_bundle_identifier="com.yaleman.Bleat"
readonly bleat_device_type="${BLEAT_DEEP_LINK_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
readonly bleat_receipt_key="bleatUITestLastDeepLinkReceipt"
readonly bleat_driver_ready_key="bleatUITestExternalURLDriverReady"
readonly bleat_driver_complete_key="bleatUITestExternalURLDriverComplete"
readonly bleat_driver_bundle_identifier="com.yaleman.BleatUITests.xctrunner"

if [[ -n "${BLEAT_DEEP_LINK_DERIVED_DATA:-}" ]]; then
    readonly bleat_derived_data="${BLEAT_DEEP_LINK_DERIVED_DATA}"
    readonly bleat_remove_derived_data=0
else
    readonly bleat_derived_data="${bleat_repository_root}/.build/deep-link-derived-${bleat_run_id}"
    readonly bleat_remove_derived_data=1
fi

bleat_simulator_id=""
bleat_data_container=""
bleat_driver_data_container=""
bleat_driver_pid=""
bleat_driver_log="${TMPDIR:-/tmp}/bleat-deep-links-${bleat_run_id}.log"

bleat_cleanup() {
    local exit_code=$?
    trap - EXIT HUP INT QUIT TERM
    if [[ -n "${bleat_driver_pid}" ]]; then
        kill "${bleat_driver_pid}" >/dev/null 2>&1 || true
        wait "${bleat_driver_pid}" >/dev/null 2>&1 || true
    fi
    if [[ -n "${bleat_simulator_id}" ]]; then
        xcrun simctl shutdown "${bleat_simulator_id}" >/dev/null 2>&1 \
            || true
        xcrun simctl delete "${bleat_simulator_id}" >/dev/null 2>&1 \
            || true
    fi
    if (( bleat_remove_derived_data )); then
        rm -rf "${bleat_derived_data}"
    fi
    rm -f "${bleat_driver_log}"
    exit "${exit_code}"
}

bleat_abort() {
    local exit_code="$1"
    trap - HUP INT QUIT TERM
    exit "${exit_code}"
}

bleat_receipt() {
    if [[ -z "${bleat_data_container}" ]]; then
        return
    fi
    plutil -extract "${bleat_receipt_key}" raw \
        "${bleat_data_container}/Library/Preferences/${bleat_bundle_identifier}.plist" \
        2>/dev/null \
        || true
}

bleat_wait_for_receipt() {
    local expected="$1"
    local previous="$2"
    local attempt
    local actual
    for attempt in {1..100}; do
        actual="$(bleat_receipt)"
        if [[ "${actual}" != "${previous}" \
            && "${actual}" == *":${expected}" ]]; then
            return 0
        fi
        sleep 0.2
    done
    print -u2 "Deep-link route did not reach expected typed outcome: ${expected}"
    return 1
}

bleat_wait_for_unchanged_receipt() {
    local previous="$1"
    local attempt
    for attempt in {1..50}; do
        if [[ "$(bleat_receipt)" != "${previous}" ]]; then
            print -u2 "Malformed deep link unexpectedly changed navigation"
            return 1
        fi
        sleep 0.2
    done
    return 0
}

bleat_open_and_expect() {
    local route="$1"
    local expected="$2"
    local previous
    previous="$(bleat_receipt)"
    xcrun simctl openurl "${bleat_simulator_id}" "${route}"
    bleat_wait_for_receipt "${expected}" "${previous}"
}

bleat_wait_for_driver() {
    local attempt
    for attempt in {1..200}; do
        if [[ -z "${bleat_driver_data_container}" ]]; then
            bleat_driver_data_container="$(
                xcrun simctl get_app_container \
                    "${bleat_simulator_id}" \
                    "${bleat_driver_bundle_identifier}" \
                    data \
                    2>/dev/null \
                    || true
            )"
        fi
        if [[ -n "${bleat_driver_data_container}" ]] \
            && plutil -extract "${bleat_driver_ready_key}" raw \
                "${bleat_driver_data_container}/Library/Preferences/${bleat_driver_bundle_identifier}.plist" \
                2>/dev/null \
                | rg -x true; then
            return 0
        fi
        if ! kill -0 "${bleat_driver_pid}" 2>/dev/null; then
            print -u2 "External URL confirmation driver exited before becoming ready"
            cat "${bleat_driver_log}" >&2
            return 1
        fi
        sleep 0.25
    done
    print -u2 "Timed out waiting for the external URL confirmation driver"
    cat "${bleat_driver_log}" >&2
    return 1
}

bleat_finish_driver() {
    xcrun simctl spawn \
        "${bleat_simulator_id}" \
        defaults write \
        "${bleat_driver_bundle_identifier}" \
        "${bleat_driver_complete_key}" \
        -bool true
}

trap bleat_cleanup EXIT
if [[ "${BLEAT_DEEP_LINK_ALLOW_HUP:-0}" != "1" ]]; then
    trap 'bleat_abort 129' HUP
else
    trap '' HUP
fi
trap 'bleat_abort 130' INT
trap 'bleat_abort 131' QUIT
trap 'bleat_abort 143' TERM

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
        "Bleat Deep Links $$" \
        "${bleat_device_type}" \
        "${bleat_runtime}"
)"
xcrun simctl boot "${bleat_simulator_id}"
xcrun simctl bootstatus "${bleat_simulator_id}"

xcodebuild \
    -quiet \
    -project "${bleat_repository_root}/Bleat.xcodeproj" \
    -scheme Bleat \
    -configuration Debug \
    -destination "id=${bleat_simulator_id}" \
    -derivedDataPath "${bleat_derived_data}" \
    BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
    BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
    BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
    build

bleat_app="${bleat_derived_data}/Build/Products/Debug-iphonesimulator/Bleat.app"
if [[ ! -d "${bleat_app}" ]]; then
    print -u2 "Xcode did not produce the simulator app"
    exit 1
fi
scheme="$(
    plutil -extract 'CFBundleURLTypes.0.CFBundleURLSchemes.0' raw \
        "${bleat_app}/Info.plist"
)"
if [[ "${scheme}" != "bleat" ]]; then
    print -u2 "Built app does not register the bleat URL scheme"
    exit 1
fi
xcrun simctl install "${bleat_simulator_id}" "${bleat_app}"

xcodebuild \
    -quiet \
    -project "${bleat_repository_root}/Bleat.xcodeproj" \
    -scheme Bleat \
    -destination "id=${bleat_simulator_id}" \
    -derivedDataPath "${bleat_derived_data}" \
    BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
    BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
    BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG EXTERNAL_URL_DRIVER' \
    -parallel-testing-enabled NO \
    -only-testing:BleatUITests/BleatUITests/testAcceptsExternalURLConfirmationFromHost \
    test >"${bleat_driver_log}" 2>&1 &
bleat_driver_pid="$!"
bleat_wait_for_driver

# Xcode installs the test runner after the app. Persist the DEBUG scenario only
# after that installation so the cold route starts from the intended account.
xcrun simctl launch \
    --terminate-running-process \
    "${bleat_simulator_id}" \
    "${bleat_bundle_identifier}" \
    --args \
    --ui-testing-signed-in \
    --ui-testing-persist-scenario \
    --ui-testing-clear-deep-link-receipt \
    >/dev/null
bleat_data_container="$(
    xcrun simctl get_app_container \
        "${bleat_simulator_id}" \
        "${bleat_bundle_identifier}" \
        data
)"
sleep 0.2
xcrun simctl terminate "${bleat_simulator_id}" "${bleat_bundle_identifier}"

# The first route starts the app through the registered scheme. The remaining
# routes exercise delivery while the same scene is already running.
bleat_open_and_expect \
    'bleat://book/ui-book?account=ui-account&library=ui-library' \
    'applied:book'
bleat_open_and_expect 'bleat://home' 'applied:home'
bleat_open_and_expect 'bleat://library' 'applied:library'
bleat_open_and_expect 'bleat://downloads' 'applied:downloads'
bleat_open_and_expect 'bleat://settings/diagnostics' 'applied:settings'
bleat_open_and_expect 'bleat://search/book?q=Test' 'applied:search'
bleat_open_and_expect 'bleat://search/author?q=Test' 'applied:search'
bleat_open_and_expect 'bleat://search/series?q=Test' 'applied:search'
bleat_open_and_expect \
    'bleat://author/author-1?account=ui-account&library=ui-library' \
    'applied:author'
bleat_open_and_expect \
    'bleat://series/series-1?account=ui-account&library=ui-library' \
    'applied:series'
bleat_open_and_expect 'bleat://now-playing' 'unavailable:nowPlaying'

bleat_last_receipt="$(bleat_receipt)"
xcrun simctl openurl "${bleat_simulator_id}" 'bleat://search?q='
bleat_wait_for_unchanged_receipt "${bleat_last_receipt}"

bleat_finish_driver
wait "${bleat_driver_pid}"
bleat_driver_pid=""

xcrun simctl launch \
    --terminate-running-process \
    "${bleat_simulator_id}" \
    "${bleat_bundle_identifier}" \
    --args \
    --ui-testing-clear-persisted-scenario \
    >/dev/null
