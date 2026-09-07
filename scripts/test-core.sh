#!/bin/zsh

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
readonly bleat_repository_root="${bleat_script_dir:h}"
readonly bleat_result_root="${bleat_repository_root}/.build/test-core-results"

bleat_require_boolean() {
    local name="$1"
    local value="$2"
    if [[ "${value}" != "0" && "${value}" != "1" ]]; then
        print -u2 "${name} must be 0 or 1"
        return 1
    fi
}

bleat_verify_result_bundle() {
    local result_bundle="$1"
    local test_target="$2"
    local allowed_skips="$3"
    local results

    if [[ ! -f "${result_bundle}/Info.plist" ]]; then
        print -u2 "Expected complete result bundle at ${result_bundle}"
        return 1
    fi
    plutil -lint "${result_bundle}/Info.plist" >/dev/null

    results="$(
        xcrun xcresulttool get test-results tests \
            --path "${result_bundle}" \
            --format json
    )"
    if ! print -- "${results}" | jq --exit-status \
        --arg target "${test_target}" \
        --argjson allowed_skips "${allowed_skips}" '
            ([.. | objects | select(.nodeType == "Test Case")]) as $tests
            | ([$tests[] | select(.result == "Passed")] | length) > 0
            and all(
                $tests[];
                .result == "Passed"
                    or (
                        .result == "Skipped"
                        and (
                            .name as $name
                            | ($allowed_skips | index($name)) != null
                        )
                    )
            )
            and any(.. | objects; .name == $target)
        ' >/dev/null; then
        print -u2 "${test_target} result bundle is incomplete or contains a failure"
        return 1
    fi

    print -- "${results}" | jq --raw-output '
        [.. | objects
          | select(.nodeType == "Test Case")
          | "\(.name)\t\(.result)"]
        | .[]
    '
}

readonly bleat_skip_host="${BLEAT_SKIP_HOST:-0}"
readonly bleat_skip_simulator="${BLEAT_SKIP_SIMULATOR:-0}"
bleat_require_boolean BLEAT_SKIP_HOST "${bleat_skip_host}"
bleat_require_boolean BLEAT_SKIP_SIMULATOR "${bleat_skip_simulator}"

if [[ "${bleat_skip_host}" == "0" ]]; then
    swift test --enable-code-coverage
    swift build -c release
    "${bleat_script_dir}/test-paid-developer-build-modes.sh"
fi

if [[ "${bleat_skip_simulator}" == "1" ]]; then
    exit 0
fi

simulator_destination="${BLEAT_SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"

echo "Running base tests"
xcodebuild \
    -project Bleat.xcodeproj \
    -resolvePackageDependencies \
    -scheme Bleat \
    BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
    BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
    BLEAT_CARPLAY_MODE="${BLEAT_CARPLAY_MODE:-disabled}" \
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
    BLEAT_CARPLAY_MODE="${BLEAT_CARPLAY_MODE:-disabled}" \
    BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
    build

echo "Running tests on simulator: ${simulator_destination}"
rm -rf "${bleat_result_root}"
mkdir -p "${bleat_result_root}"
xcodebuild \
    -quiet \
    -project Bleat.xcodeproj \
    -scheme Bleat \
    -destination "${simulator_destination}" \
    -derivedDataPath .build/xcode-derived \
    BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
    BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
    BLEAT_CARPLAY_MODE="${BLEAT_CARPLAY_MODE:-disabled}" \
    BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
    -enableCodeCoverage YES \
    -parallel-testing-enabled NO \
    -resultBundlePath "${bleat_result_root}/app-tests.xcresult" \
    -only-testing:BleatAppTests \
    test
bleat_verify_result_bundle \
    "${bleat_result_root}/app-tests.xcresult" \
    BleatAppTests \
    '["testPhysicalDeviceResolvesAndVerifiesLiveAdvertisement()"]'

echo "Running UI tests on ${simulator_destination}"
xcodebuild \
    -quiet \
    -project Bleat.xcodeproj \
    -scheme Bleat \
    -destination "${simulator_destination}" \
    -derivedDataPath .build/xcode-derived \
    BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
    BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
    BLEAT_CARPLAY_MODE="${BLEAT_CARPLAY_MODE:-disabled}" \
    BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
    -enableCodeCoverage YES \
    -resultBundlePath "${bleat_result_root}/ui-tests.xcresult" \
    -parallel-testing-enabled NO \
    -only-testing:BleatUITests \
    -skip-testing:BleatUITests/BleatAccessibilityAuditUITests \
    test
bleat_verify_result_bundle \
    "${bleat_result_root}/ui-tests.xcresult" \
    BleatUITests \
    '[
        "testAcceptsExternalURLConfirmationFromHost()",
        "testLiveOnlineLoginPlaybackAndDownload()",
        "testLiveOfflineCachedDownloadAndLocalProgress()",
        "testReleaseScreenshots()",
        "testReleaseSecretScanRefreshAfterTokenInvalidation()",
        "testReleaseSecretScanLogout()"
    ]'
