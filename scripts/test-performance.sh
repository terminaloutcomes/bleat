#!/bin/zsh
# Runs the 10,000-book Simulator performance baseline for GitHub issue #46
# / spec section 19 on iPhone 17 Pro / iOS 26.5, Release configuration.
#
# Uses the dedicated BleatPerformance scheme whose Test action is configured
# for Release, so the app and UI-test runner are built and measured in
# Release. The dedicated BLEAT_UI_TESTING compilation condition includes the
# fixture and memory probe only for this invocation; ordinary Release builds
# do not contain the test service.
#
# Usage:
#   ./scripts/test-performance.sh
#
# Output:
#   .build/performance.xcresult (verified via xcresulttool)

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
readonly result_bundle="${bleat_script_dir:h}/.build/performance.xcresult"
readonly simulator_destination="${BLEAT_SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
readonly seed_count="${BLEAT_PERF_SEED_COUNT:-10000}"

print "Running 10,000-book performance UI tests on ${simulator_destination}"
print "Seed count: ${seed_count}"

rm -rf "${result_bundle}"

# Forward the configurable seed count to the test runner process.
# xcodebuild passes `TEST_RUNNER_`-prefixed environment variables through to
# the test process with the prefix stripped, so the test's
# `ProcessInfo.processInfo.environment["BLEAT_PERF_SEED_COUNT"]` sees the
# value. Passing it as a build setting (the previous form) did not reach the
# test process because the shared scheme defines no matching env var.
export TEST_RUNNER_BLEAT_PERF_SEED_COUNT="${seed_count}"

xcodebuild \
    -quiet \
    -project "${bleat_script_dir:h}/Bleat.xcodeproj" \
    -scheme BleatPerformance \
    -destination "${simulator_destination}" \
    -derivedDataPath "${bleat_script_dir:h}/.build/xcode-derived" \
    -only-testing:BleatUITests/BleatPerformanceUITests \
    -resultBundlePath "${result_bundle}" \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) BLEAT_UI_TESTING' \
    BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
    BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
    BLEAT_CARPLAY_MODE="${BLEAT_CARPLAY_MODE:-enabled}" \
    BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
    test

cargo run --quiet --locked --manifest-path "${bleat_script_dir}/Cargo.toml" \
    --bin verify-test-results -- --result-bundle "${result_bundle}" \
    --expected BleatUITests/BleatPerformanceUITests/testTenKBooksLaunchBrowsingAndSearchPerformance

print "Performance baseline result bundle: ${result_bundle}"
