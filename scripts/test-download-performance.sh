#!/bin/zsh
# Runs the Issue #151 download storage and 300-track responsiveness evidence
# on a Release iOS Simulator build.

set -euo pipefail

readonly bleat_repository_root="${0:A:h:h}"
cd "${bleat_repository_root}"

readonly result_bundle=".build/download-performance.xcresult"
readonly simulator_destination="${BLEAT_SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"

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

cargo run --quiet --locked --manifest-path "${bleat_repository_root}/scripts/Cargo.toml" \
    --bin verify-test-results -- --result-bundle "${result_bundle}" \
    --expected BleatAppTests/AppModelTests/testDownloadPreflightRejectsInsufficientCapacityBeforeScheduling \
    --expected BleatAppTests/AppModelTests/testThreeHundredTrackDownloadRepairAndPublicationStayResponsive

print "Issue #151 result bundle: ${result_bundle}"
