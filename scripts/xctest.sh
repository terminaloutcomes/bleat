#!/bin/zsh
# Runs an Xcode test bundle with a single command and verifies the result
# per AGENTS.md (console exit 0 is not evidence; inspect the .xcresult).
#
# Usage:
#   ./scripts/xctest.sh [-s SCHEME] [-d DESTINATION] [-t TEST-ID] \
#       [-r RESULT-BUNDLE] [-c CONFIG] [-- ENV-NAME=VALUE ...]
#
# Defaults:
#   SCHEME        Bleat
#   DESTINATION   platform=iOS Simulator,name=iPhone 17 Pro
#   TEST-ID       (none; runs the whole scheme's test action)
#   RESULT-BUNDLE .build/xctest.xcresult
#   CONFIG        (scheme default; pass -c Release to override)
#
# Env vars after `--` are exported into the test process via the
# TEST_RUNNER_ prefix (xcodebuild forwards TEST_RUNNER_FOO as FOO to the
# test runner). Pass them as `-- BLEAT_PERF_SEED_COUNT=100`.
#
# Examples:
#   ./scripts/xctest.sh -s Bleat -t BleatAppTests/AppModelTests/testFoo
#   ./scripts/xctest.sh -s BleatPerformance -t BleatUITests/BleatPerformanceUITests -- BLEAT_PERF_SEED_COUNT=100
#   ./scripts/xctest.sh -s Bleat -t BleatUITests/BleatUITests/testNativeLoginShowsSignedInTabs

set -euo pipefail

bleat_script_dir="${0:A:h}"
bleat_repo_root="${bleat_script_dir:h}"

scheme="Bleat"
destination="${BLEAT_SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"
test_id=""
result_bundle="${bleat_repo_root}/.build/xctest.xcresult"
config_override=""

while getopts "s:d:t:r:c:" opt; do
    case "${opt}" in
        s) scheme="${OPTARG}" ;;
        d) destination="${OPTARG}" ;;
        t) test_id="${OPTARG}" ;;
        r) result_bundle="${OPTARG}" ;;
        c) config_override="${OPTARG}" ;;
        *) print -u2 "Usage: $0 [-s SCHEME] [-d DESTINATION] [-t TEST-ID] [-r RESULT-BUNDLE] [-c CONFIG] [-- ENV=VAL ...]"; exit 64 ;;
    esac
done
shift $((OPTIND - 1))

# Collect remaining positional args as env-var assignments and forward
# them to the test process via the TEST_RUNNER_ prefix (xcodebuild forwards
# TEST_RUNNER_FOO as FOO to the test runner). getopts already consumed any
# `--` terminator, so each remaining arg is `NAME=VALUE`.
for arg in "$@"; do
    name="${arg%%=*}"
    value="${arg#*=}"
    export "TEST_RUNNER_${name}=${value}"
done

config_flag=()
if [[ -n "${config_override}" ]]; then
    config_flag=(-configuration "${config_override}")
fi

only_testing=()
if [[ -n "${test_id}" ]]; then
    only_testing=(-only-testing:"${test_id}")
fi

print "Building ${scheme} for testing..."
xcodebuild -quiet \
    -project "${bleat_repo_root}/Bleat.xcodeproj" \
    -scheme "${scheme}" \
    "${config_flag[@]}" \
    -destination "${destination}" \
    -derivedDataPath "${bleat_repo_root}/.build/xcode-derived" \
    BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
    BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
    BLEAT_CARPLAY_MODE="${BLEAT_CARPLAY_MODE:-disabled}" \
    BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
    build-for-testing

rm -rf "${result_bundle}"
print "Running ${scheme} tests (${test_id:-all})..."
xcodebuild -quiet \
    -project "${bleat_repo_root}/Bleat.xcodeproj" \
    -scheme "${scheme}" \
    "${config_flag[@]}" \
    -destination "${destination}" \
    -derivedDataPath "${bleat_repo_root}/.build/xcode-derived" \
    "${only_testing[@]}" \
    -resultBundlePath "${result_bundle}" \
    BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
    BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
    BLEAT_CARPLAY_MODE="${BLEAT_CARPLAY_MODE:-disabled}" \
    BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
    test

# Inspect the result bundle. Exit 0 is not evidence per AGENTS.md.
summary="$(
    xcrun xcresulttool get test-results tests \
        --path "${result_bundle}" \
        | jq --raw-output '
            [.. | objects
              | select(.nodeType == "Test Case")
              | "\(.name)\t\(.result)"] | join("\n")
        '
)"

if [[ -z "${summary}" ]]; then
    print -u2 "FAILED: no test cases executed in ${result_bundle}"
    exit 1
fi

print "${summary}"

passed="$(print -- "${summary}" | grep -c 'Passed$' || true)"
failed="$(print -- "${summary}" | grep -c 'Failed$' || true)"
skipped="$(print -- "${summary}" | grep -c 'Skipped$' || true)"

print ""
print "Executed: $(( passed + failed ))  Passed: ${passed}  Failed: ${failed}  Skipped: ${skipped}"

if (( failed > 0 )); then
    print -u2 "FAILED: ${failed} test case(s) failed"
    exit 1
fi

if (( passed == 0 && skipped == 0 )); then
    print -u2 "FAILED: no test cases executed (zero executed is a failed validation gate)"
    exit 1
fi

print "OK: ${result_bundle}"
