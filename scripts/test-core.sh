#!/bin/zsh

set -euo pipefail

swift test --enable-code-coverage
swift build -c release
./scripts/test-paid-developer-build-modes.sh

if [[ "${BLEAT_SKIP_SIMULATOR:-0}" == "1" ]]; then
    exit 0
fi

simulator_destination="${BLEAT_SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
simulator_test_workers="${BLEAT_SIMULATOR_TEST_WORKERS:-1}"

if [[ ! "${simulator_test_workers}" =~ ^[1-9][0-9]*$ ]]; then
    print -u2 "BLEAT_SIMULATOR_TEST_WORKERS must be a positive integer"
    exit 2
fi

echo "Running base tests"
xcodebuild \
    -project Bleat.xcodeproj \
    -resolvePackageDependencies \
    -scheme Bleat \
    BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
    BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
    BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
    -derivedDataPath .build/xcode-derived

echo "Running build test..."
xcodebuild \
    -quiet \
    -project Bleat.xcodeproj \
    -scheme Bleat \
    -configuration Release \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath .build/xcode-derived \
    BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
    BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
    BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
    build

echo "Running tests on simulator: ${simulator_destination}"
xcodebuild \
    -quiet \
    -project Bleat.xcodeproj \
    -scheme Bleat \
    -destination "${simulator_destination}" \
    -derivedDataPath .build/xcode-derived \
    BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
    BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
    BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
    -enableCodeCoverage YES \
    -only-testing:BleatAppTests \
    test

echo "Running UI tests with ${simulator_test_workers} workers"
xcodebuild \
    -quiet \
    -project Bleat.xcodeproj \
    -scheme Bleat \
    -destination "${simulator_destination}" \
    -derivedDataPath .build/xcode-derived \
    BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
    BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
    BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
    -enableCodeCoverage YES \
    -parallel-testing-enabled YES \
    -parallel-testing-worker-count "${simulator_test_workers}" \
    -only-testing:BleatUITests \
    test
