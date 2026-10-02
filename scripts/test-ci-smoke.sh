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
# Resolve the destination and product before building, so Simulator boot can
# proceed while Xcode compiles. Use Xcode's resolved device for both commands.
app_settings="$(
    xcodebuild "${common[@]}" -destination "${destination}" -showBuildSettings -json \
        | jq -e '[.[] | select(.target == "BleatApp") | .buildSettings]
            | if length == 1 then .[0] else error("Expected one BleatApp target") end'
)"
simulator_id="$(print -r -- "${app_settings}" | jq -er '.TARGET_DEVICE_IDENTIFIER | select(type == "string" and length > 0)')"
app_path="$(print -r -- "${app_settings}" | jq -er '.TARGET_BUILD_DIR + "/" + .FULL_PRODUCT_NAME')"
simulator_state="$(xcrun simctl list devices available --json \
    | jq -er --arg id "${simulator_id}" '[.devices[][] | select(.udid == $id) | .state] | if length == 1 then .[0] else error("Expected one Simulator") end')"
boot_pid=0
cleanup_boot_waiter() {
    if (( boot_pid > 0 )); then
        kill "${boot_pid}" 2>/dev/null || true
        wait "${boot_pid}" 2>/dev/null || true
    fi
}
trap cleanup_boot_waiter EXIT
(
    started="$(date +%s)"
    if [[ "${simulator_state}" == Shutdown ]]; then
        xcrun simctl boot "${simulator_id}"
    elif [[ "${simulator_state}" != Booted ]]; then
        print -u2 "Simulator is in unexpected state: ${simulator_state}"
        exit 1
    fi
    xcrun simctl bootstatus "${simulator_id}" -b
    print "Simulator ready in $(( $(date +%s) - started ))s"
) &
boot_pid=$!

build_started="$(date +%s)"
xcodebuild "${common[@]}" "${test_options[@]}" -destination "platform=iOS Simulator,id=${simulator_id}" \
    -only-testing:"${startup}" -only-testing:"${signed_in}" build-for-testing
print "Build for testing completed in $(( $(date +%s) - build_started ))s"
boot_status=0
wait "${boot_pid}" || boot_status=$?
boot_pid=0
(( boot_status == 0 )) || exit "${boot_status}"
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
