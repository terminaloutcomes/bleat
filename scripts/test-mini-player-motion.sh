#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
readonly derived=".build/issue-201"
readonly results=".build/mini-player-motion/results-$(date -u +%Y%m%dT%H%M%SZ)"
readonly runtime="$(xcrun simctl list runtimes -j | jq -er '[.runtimes[] | select(.isAvailable and .platform == "iOS")] | max_by(.version | split(".") | map(tonumber)) | .identifier')"
typeset -a devices=()
typeset -a tests=(
    testMiniPlayerReportsSystemReduceMotionSetting
    testMiniPlayerSwipesDownToStopWhilePlayingAndPaused
    testMiniPlayerRestoresWhenStopIsSuperseded
    testMiniPlayerSwipesUpToOpenNowPlaying
)
typeset -a selection=()
for name in "${tests[@]}"; do
    selection+=("-only-testing:BleatUITests/BleatUITests/${name}")
done
cleanup() {
    local incoming_status=$?
    trap - EXIT
    for device in "${devices[@]}"; do
        xcrun simctl shutdown "${device}" >/dev/null 2>&1 || true
        xcrun simctl delete "${device}" || incoming_status=1
    done
    exit "${incoming_status}"
}
trap cleanup EXIT
mkdir -p "${results}"
for type in iPhone-17-Pro iPad-Pro-13-inch-M5-12GB; do
    device="$(xcrun simctl create "Bleat Mini Player Motion $$ ${type}" "com.apple.CoreSimulator.SimDeviceType.${type}" "${runtime}")"
    devices+=("${device}")
    for mode in disabled enabled; do
        xcrun simctl boot "${device}"
        xcrun simctl bootstatus "${device}" -b
        value=NO
        [[ "${mode}" == enabled ]] && value=YES
        xcrun simctl spawn "${device}" defaults write com.apple.Accessibility ReduceMotionEnabled -bool "${value}"
        xcrun simctl shutdown "${device}"
        xcrun simctl boot "${device}"
        xcrun simctl bootstatus "${device}" -b
        bundle="${results}/${type}-${mode}.xcresult"
        TEST_RUNNER_BLEAT_EXPECT_REDUCE_MOTION="${mode}" xcodebuild -quiet \
            -project Bleat.xcodeproj -scheme Bleat -configuration Debug \
            -destination "platform=iOS Simulator,id=${device}" \
            -derivedDataPath "${derived}" -parallel-testing-enabled NO \
            "${selection[@]}" -resultBundlePath "${bundle}" test
        xcrun xcresulttool get test-results tests --path "${bundle}" --format json \
            | jq -e '[.. | objects | select(.nodeType == "Test Case")] as $tests |
                ($tests | length) == 4 and all($tests[]; .result == "Passed") and
                ([$tests[].name] | sort) == ([
                    "testMiniPlayerReportsSystemReduceMotionSetting()",
                    "testMiniPlayerSwipesDownToStopWhilePlayingAndPaused()",
                    "testMiniPlayerRestoresWhenStopIsSuperseded()",
                    "testMiniPlayerSwipesUpToOpenNowPlaying()"
                ] | sort)'
        xcrun simctl shutdown "${device}"
    done
done
print "Verified mini-player motion results: ${results}"
