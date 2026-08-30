#!/bin/zsh
# Runs the Issue #151 download storage and 300-track responsiveness evidence
# on a Release iOS Simulator build.

set -euo pipefail

readonly bleat_repository_root="${0:A:h:h}"
cd "${bleat_repository_root}"

readonly result_bundle=".build/download-performance.xcresult"
readonly simulator_destination="${BLEAT_SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
readonly expected_capacity_test="testDownloadPreflightRejectsInsufficientCapacityBeforeScheduling()"
readonly expected_performance_test="testThreeHundredTrackDownloadRepairAndPublicationStayResponsive()"

print "Running Issue #151 download evidence on ${simulator_destination}"

rm -rf "${result_bundle}"

xcodebuild \
    -quiet \
    -project Bleat.xcodeproj \
    -scheme BleatPerformance \
    -destination "${simulator_destination}" \
    -derivedDataPath .build/xcode-derived \
    -only-testing:BleatAppTests/AppModelTests/testDownloadPreflightRejectsInsufficientCapacityBeforeScheduling \
    -only-testing:BleatAppTests/AppModelTests/testThreeHundredTrackDownloadRepairAndPublicationStayResponsive \
    -resultBundlePath "${result_bundle}" \
    BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
    BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
    BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
    ENABLE_TESTABILITY=YES \
    test

executed="$(
    xcrun xcresulttool get test-results tests \
        --path "${result_bundle}" \
        | jq --raw-output '
            [.testNodes[].children[].children[].children[]
              | select(.nodeType == "Test Case")
              | "\(.name)\t\(.result)"] | .[]
        '
)"
print "${executed}"

if [[ -z "${executed}" ]]; then
    print -u2 "No Issue #151 download tests executed"
    exit 1
fi

readonly executed_count="$(wc -l <<<"${executed}" | tr -d ' ')"
if [[ "${executed_count}" != "2" ]]; then
    print -u2 "Expected exactly 2 Issue #151 tests, observed ${executed_count}"
    exit 1
fi

for expected_test in "${expected_capacity_test}" "${expected_performance_test}"; do
    if ! grep -Fqx "${expected_test}	Passed" <<<"${executed}"; then
        print -u2 "Missing passing result for ${expected_test}"
        exit 1
    fi
done

print "Issue #151 result bundle: ${result_bundle}"
