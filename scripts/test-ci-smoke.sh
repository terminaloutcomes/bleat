#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"
readonly result=".build/ci-smoke/results.xcresult"
readonly derived=".build/ci-smoke/derived"
readonly destination="${BLEAT_SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
readonly startup="BleatUITests/BleatUITests/testLaunchingScreenDescribesStartupWork"
readonly signed_in="BleatUITests/BleatUITests/testMiniPlayerIsAbsentBeforePlayback"
typeset -a common
common=(-project Bleat.xcodeproj -scheme Bleat -configuration Debug
    -derivedDataPath "${derived}")
typeset -a test_options
test_options=(-enableCodeCoverage YES -parallel-testing-enabled NO)

rm -rf "${result}"
xcodebuild "${common[@]}" "${test_options[@]}" -destination "${destination}" -only-testing:"${startup}" \
    -only-testing:"${signed_in}" build-for-testing

# Resolve the same destination and product Xcode used for the successful build.
app_settings="$(
    xcodebuild "${common[@]}" -destination "${destination}" -showBuildSettings -json \
        | jq -e '[.[] | select(.target == "BleatApp") | .buildSettings]
            | if length == 1 then .[0] else error("Expected one BleatApp target") end'
)"
simulator_id="$(print -r -- "${app_settings}" | jq -er '.TARGET_DEVICE_IDENTIFIER | select(type == "string" and length > 0)')"
app_path="$(print -r -- "${app_settings}" | jq -er '.TARGET_BUILD_DIR + "/" + .FULL_PRODUCT_NAME')"
xcrun simctl bootstatus "${simulator_id}" -b
xcrun simctl install "${simulator_id}" "${app_path}"

test_status=0
xcodebuild "${common[@]}" "${test_options[@]}" -destination "platform=iOS Simulator,id=${simulator_id}" -only-testing:"${startup}" \
    -only-testing:"${signed_in}" -resultBundlePath "${result}" \
    test-without-building || test_status=$?

# Inspect results even after a failed test command so assertions remain visible.
xcrun xcresulttool get test-results summary --path "${result}" --format json
xcrun xcresulttool get test-results tests --path "${result}" --format json \
    | jq -e '
        [.. | objects | select(.nodeType == "Test Case")] as $tests
        | ($tests | length) == 2
          and all($tests[]; .result == "Passed")
          and ([$tests[].name] | sort) == ([
            "testLaunchingScreenDescribesStartupWork()",
            "testMiniPlayerIsAbsentBeforePlayback()"
          ] | sort)
    '
exit "${test_status}"
