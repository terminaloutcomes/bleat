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
    -destination "${destination}" -derivedDataPath "${derived}"
    -enableCodeCoverage YES -parallel-testing-enabled NO)

rm -rf "${result}"
xcodebuild "${common[@]}" -only-testing:"${startup}" \
    -only-testing:"${signed_in}" build-for-testing
test_status=0
xcodebuild "${common[@]}" -only-testing:"${startup}" \
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
