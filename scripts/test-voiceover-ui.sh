#!/bin/zsh

set -euo pipefail

readonly bleat_repository_root="${0:A:h:h}"
readonly bleat_build_root="${bleat_repository_root}/.build"
readonly bleat_derived_data="${bleat_build_root:A}/voiceover-ui-derived"
readonly bleat_result_root="${bleat_build_root:A}/voiceover-ui-results"
readonly bleat_runtime="${BLEAT_VOICEOVER_RUNTIME:-$(
    xcrun simctl list runtimes -j | jq --raw-output --exit-status '
        [.runtimes[] | select(.isAvailable and .platform == "iOS")]
        | max_by(.version | split(".") | map(tonumber))
        | .identifier
    '
)}"
readonly bleat_device_types=(
    "${BLEAT_VOICEOVER_IPHONE_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
    "${BLEAT_VOICEOVER_IPAD_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB}"
)
readonly bleat_device_labels=("iPhone-17-Pro" "iPad-Pro-13-inch-M5")
readonly bleat_expected_tests='[
    "BleatVoiceOverUITests/testLoginVoiceOverSemantics()",
    "BleatVoiceOverUITests/testPlaybackVoiceOverSemantics()",
    "BleatVoiceOverUITests/testPrimaryJourneyVoiceOverSemantics()"
]'
typeset -a bleat_devices=()

delete_device() {
    local device="$1"
    xcrun simctl shutdown "${device}" >/dev/null 2>&1 || true
    for _ in {1..5}; do
        if xcrun simctl delete "${device}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

cleanup() {
    local incoming_status=$?
    local cleanup_failed=false
    trap - EXIT
    set +e
    for device in "${bleat_devices[@]}"; do
        if [[ -n "${device}" ]] && ! delete_device "${device}"; then
            print -u2 "Failed to delete disposable Simulator ${device}"
            cleanup_failed=true
        fi
    done
    if (( incoming_status != 0 )); then
        exit "${incoming_status}"
    fi
    if [[ "${cleanup_failed}" == true ]]; then
        exit 1
    fi
}

trap cleanup EXIT

rm -rf "${bleat_result_root}" "${bleat_derived_data}"
mkdir -p "${bleat_result_root}"

run_audit() {
    local device="$1"
    local label="$2"
    local result_bundle="${bleat_result_root}/${label}.xcresult"

    print "Running VoiceOver semantic UI tests on ${label}"
    xcodebuild -quiet \
        -project "${bleat_repository_root}/Bleat.xcodeproj" \
        -scheme Bleat \
        -destination "platform=iOS Simulator,id=${device}" \
        -derivedDataPath "${bleat_derived_data}" \
        BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
        BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
        BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
        -parallel-testing-enabled NO \
        -resultBundlePath "${result_bundle}" \
        -only-testing:BleatUITests/BleatVoiceOverUITests \
        test

    xcrun xcresulttool get test-results summary \
        --path "${result_bundle}" --format json \
        | jq --exit-status '
            .result == "Passed"
            and .totalTestCount == 3
            and .passedTests == 3
            and .failedTests == 0
        ' >/dev/null
    xcrun xcresulttool get test-results tests \
        --path "${result_bundle}" --format json \
        | jq --exit-status --argjson expected "${bleat_expected_tests}" '
            [
                ..
                | objects
                | select(.nodeType? == "Test Case" and .result? == "Passed")
                | .nodeIdentifier
            ] as $passed
            | ($passed | length) == ($expected | length)
                and all($expected[]; . as $test | $passed | index($test) != null)
        ' >/dev/null
}

for (( index = 1; index <= ${#bleat_device_types}; index++ )); do
    device_type="${bleat_device_types[index]}"
    label="${bleat_device_labels[index]}"
    device="$(
        xcrun simctl create \
            "Bleat VoiceOver ${label} $$" \
            "${device_type}" \
            "${bleat_runtime}"
    )"
    bleat_devices+=("${device}")

    xcrun simctl boot "${device}"
    xcrun simctl bootstatus "${device}" -b
    run_audit "${device}" "${label}"
    delete_device "${device}"
    bleat_devices[index]=""
done
