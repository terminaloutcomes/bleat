#!/bin/zsh

set -euo pipefail

readonly bleat_repository_root="${0:A:h:h}"
readonly bleat_build_root="${bleat_repository_root}/.build"
readonly bleat_derived_data="${bleat_build_root:A}/dynamic-type-ui-derived"
readonly bleat_result_root="${bleat_build_root:A}/dynamic-type-ui-results"
readonly bleat_destinations=(
    "${BLEAT_DYNAMIC_TYPE_IPHONE_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
    "${BLEAT_DYNAMIC_TYPE_IPAD_DESTINATION:-platform=iOS Simulator,name=iPad Pro 13-inch (M5)}"
)
readonly bleat_expected_tests='[
    "BleatDynamicTypeUITests/testLoginRemainsUsableAtLargestDynamicType()",
    "BleatDynamicTypeUITests/testPlaybackRemainsUsableAtLargestDynamicType()",
    "BleatDynamicTypeUITests/testPrimaryJourneysRemainUsableAtLargestDynamicType()"
]'

rm -rf "${bleat_result_root}"
mkdir -p "${bleat_result_root}"

for destination in "${bleat_destinations[@]}"; do
    label="${destination##*name=}"
    result_bundle="${bleat_result_root}/${label// /-}.xcresult"
    print "Running largest Dynamic Type UI tests on ${label}"
    xcodebuild -quiet \
        -project "${bleat_repository_root}/Bleat.xcodeproj" \
        -scheme Bleat \
        -destination "${destination}" \
        -derivedDataPath "${bleat_derived_data}" \
        BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
        BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
        BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
        -parallel-testing-enabled NO \
        -resultBundlePath "${result_bundle}" \
        -only-testing:BleatUITests/BleatDynamicTypeUITests \
        test
    xcrun xcresulttool get test-results summary --path "${result_bundle}" --format json \
        | jq --exit-status '
            .result == "Passed"
            and .totalTestCount == 3
            and .passedTests == 3
            and .failedTests == 0
        ' >/dev/null
    xcrun xcresulttool get test-results tests --path "${result_bundle}" --format json \
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
done
