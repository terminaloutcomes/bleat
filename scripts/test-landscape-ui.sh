#!/bin/zsh

set -euo pipefail

readonly bleat_repository_root="${0:A:h:h}"
readonly bleat_derived_data="${bleat_repository_root}/.build/landscape-ui-derived"
readonly bleat_result_root="${bleat_repository_root}/.build/landscape-ui-results"
readonly bleat_destinations=(
    "${BLEAT_LANDSCAPE_IPHONE_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
    "${BLEAT_LANDSCAPE_IPAD_DESTINATION:-platform=iOS Simulator,name=iPad Pro 13-inch (M5)}"
)

rm -rf "${bleat_result_root}"
mkdir -p "${bleat_result_root}"

for destination in "${bleat_destinations[@]}"; do
    label="${destination##*name=}"
    result_bundle="${bleat_result_root}/${label// /-}.xcresult"
    print "Running landscape UI tests on ${label}"
    xcodebuild -quiet \
        -project "${bleat_repository_root}/Bleat.xcodeproj" \
        -scheme Bleat \
        -destination "${destination}" \
        -derivedDataPath "${bleat_derived_data}" \
        BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
        BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
        BLEAT_CARPLAY_MODE="${BLEAT_CARPLAY_MODE:-disabled}" \
        BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
        -parallel-testing-enabled NO \
        -resultBundlePath "${result_bundle}" \
        -only-testing:BleatUITests/BleatLandscapeUITests \
        test
    xcrun xcresulttool get test-results summary --path "${result_bundle}" --format json \
        | jq --exit-status '
            .result == "Passed"
            and .totalTestCount == 3
            and .passedTests == 3
            and .failedTests == 0
        ' >/dev/null
done
