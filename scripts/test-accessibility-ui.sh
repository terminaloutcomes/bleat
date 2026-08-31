#!/bin/zsh

set -euo pipefail

readonly bleat_repository_root="${0:A:h:h}"
readonly bleat_build_root="${bleat_repository_root}/.build"
readonly bleat_derived_data="${bleat_build_root:A}/accessibility-ui-derived"
readonly bleat_result_root="${bleat_build_root:A}/accessibility-ui-results"
readonly bleat_runtime="${BLEAT_ACCESSIBILITY_RUNTIME:-$(
    xcrun simctl list runtimes -j | jq --raw-output --exit-status '
        [
            .runtimes[]
            | select(.isAvailable and .platform == "iOS")
        ]
        | max_by(.version | split(".") | map(tonumber))
        | .identifier
    '
)}"
readonly bleat_device_types=(
    "${BLEAT_ACCESSIBILITY_IPHONE_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}"
    "${BLEAT_ACCESSIBILITY_IPAD_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB}"
)
readonly bleat_device_labels=("iPhone-17-Pro" "iPad-Pro-13-inch-M5")
readonly bleat_expected_screenshots='[
    "book-detail",
    "book-editor",
    "bookmark-editor",
    "chapters",
    "downloads",
    "home",
    "library",
    "login",
    "mini-player",
    "now-playing",
    "search",
    "settings"
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
    exit 0
}

trap cleanup EXIT

rm -rf "${bleat_result_root}"
mkdir -p "${bleat_result_root}"

run_audit() {
    local device="$1"
    local label="$2"
    local mode="$3"
    local result_bundle="${bleat_result_root}/${label}-${mode}.xcresult"
    local attachment_directory="${bleat_result_root}/screenshots/${label}-${mode}"
    local test_name_prefix
    local expected_tests
    case "${mode}" in
        bold-text)
            test_name_prefix="BoldText"
            ;;
        increase-contrast)
            test_name_prefix="IncreaseContrast"
            ;;
        *)
            print -u2 "Unsupported accessibility audit mode: ${mode}"
            return 2
            ;;
    esac
    expected_tests="$(
        jq --compact-output --null-input \
            --arg prefix "${test_name_prefix}" '
            [
                "BleatAccessibilityAuditUITests/test\($prefix)LoginAccessibilityAudit()",
                "BleatAccessibilityAuditUITests/test\($prefix)PlaybackAccessibilityAudit()",
                "BleatAccessibilityAuditUITests/test\($prefix)PrimaryJourneysAccessibilityAudit()"
            ]
        '
    )"
    local -a selected_tests=(
        "-only-testing:BleatUITests/BleatAccessibilityAuditUITests/test${test_name_prefix}LoginAccessibilityAudit"
        "-only-testing:BleatUITests/BleatAccessibilityAuditUITests/test${test_name_prefix}PlaybackAccessibilityAudit"
        "-only-testing:BleatUITests/BleatAccessibilityAuditUITests/test${test_name_prefix}PrimaryJourneysAccessibilityAudit"
    )

    print "Running ${mode} accessibility UI tests on ${label}"
    if ! xcodebuild -quiet \
        -project "${bleat_repository_root}/Bleat.xcodeproj" \
        -scheme Bleat \
        -destination "platform=iOS Simulator,id=${device}" \
        -derivedDataPath "${bleat_derived_data}" \
        BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
        BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
        BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
        -parallel-testing-enabled NO \
        -resultBundlePath "${result_bundle}" \
        "${selected_tests[@]}" \
        test
    then
        return 1
    fi

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
        | jq --exit-status --argjson expected "${expected_tests}" '
            [
                ..
                | objects
                | select(.nodeType? == "Test Case" and .result? == "Passed")
                | .nodeIdentifier
            ] as $passed
            | ($passed | length) == ($expected | length)
                and all($expected[]; . as $test | $passed | index($test) != null)
        ' >/dev/null
    xcrun xcresulttool export attachments \
        --path "${result_bundle}" \
        --output-path "${attachment_directory}"
    jq --exit-status \
        --arg mode "${mode}" \
        --argjson expected "${bleat_expected_screenshots}" '
        [
            .[].attachments[].suggestedHumanReadableName
            | sub("_0_[^/]+[.]png$"; "")
        ] | sort
        == ($expected | map("\($mode)-\(.)") | sort)
    ' "${attachment_directory}/manifest.json" >/dev/null
}

for (( index = 1; index <= ${#bleat_device_types}; index++ )); do
    device_type="${bleat_device_types[index]}"
    label="${bleat_device_labels[index]}"
    device="$(
        xcrun simctl create \
            "Bleat Accessibility ${label} $$" \
            "${device_type}" \
            "${bleat_runtime}"
    )"
    bleat_devices+=("${device}")

    xcrun simctl boot "${device}"
    xcrun simctl bootstatus "${device}" -b
    xcrun simctl spawn "${device}" defaults write \
        com.apple.Accessibility EnhancedTextLegibilityEnabled -bool NO
    xcrun simctl ui "${device}" increase_contrast enabled
    if ! run_audit "${device}" "${label}" "increase-contrast"; then
        if delete_device "${device}"; then
            bleat_devices[index]=""
        else
            print -u2 "Failed to delete disposable Simulator ${device}"
        fi
        exit 1
    fi

    xcrun simctl ui "${device}" increase_contrast disabled
    xcrun simctl spawn "${device}" defaults write \
        com.apple.Accessibility EnhancedTextLegibilityEnabled -bool YES
    xcrun simctl shutdown "${device}"
    xcrun simctl boot "${device}"
    xcrun simctl bootstatus "${device}" -b
    if ! run_audit "${device}" "${label}" "bold-text"; then
        if delete_device "${device}"; then
            bleat_devices[index]=""
        else
            print -u2 "Failed to delete disposable Simulator ${device}"
        fi
        exit 1
    fi

    if ! delete_device "${device}"; then
        print -u2 "Failed to delete disposable Simulator ${device}"
        exit 1
    fi
    bleat_devices[index]=""
done
