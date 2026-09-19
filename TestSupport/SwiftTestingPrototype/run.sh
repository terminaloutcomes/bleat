#!/bin/zsh
set -euo pipefail

readonly prototype_dir="${0:A:h}"
readonly repository_dir="${prototype_dir:h:h}"
readonly result_dir="${prototype_dir}/.build/evidence"
readonly trace="${BLEAT_PROTOTYPE_TRACE:-0}"
if [[ "${trace}" != 0 && "${trace}" != 1 ]]; then
    print -u2 'BLEAT_PROTOTYPE_TRACE must be 0 or 1'
    exit 1
fi
mkdir -p "${result_dir}"

# Use exactly the root package's package-manager-generated resolution.
cp "${repository_dir}/Package.resolved" "${prototype_dir}/Package.resolved"

for mode in ordinary coverage; do
    flags=()
    if [[ "${mode}" == coverage ]]; then
        flags+=(--enable-code-coverage)
    fi
    for runner in default testing-only; do
        runner_flags=()
        if [[ "${runner}" == testing-only ]]; then
            runner_flags+=(--disable-xctest)
        fi
        result="${result_dir}/${mode}-${runner}"
        # Remove only this script's previous reports so stale XML cannot pass.
        rm -f "${result}.xml" "${result}-swift-testing.xml"
        swift test --package-path "${prototype_dir}" --force-resolved-versions \
            "${flags[@]}" "${runner_flags[@]}" --xunit-output "${result}.xml" \
            >"${result}.log" 2>&1
        report="${result}.xml"
        if [[ "${runner}" == default ]]; then
            report="${result}-swift-testing.xml"
        fi
        print -- "${mode} / ${runner}"
        python3 "${prototype_dir}/verify-results.py" "${report}"
    done
    if [[ "${trace}" == 1 ]]; then
        bin_dir="$(swift build --package-path "${prototype_dir}" --show-bin-path)"
        bundle="${bin_dir}/PrototypeTests.xctest"
        platform="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
        swift_bin="$(xcrun --find swift)"
        toolchain="${swift_bin:h:h}"
        xcrun lldb --batch -s "${prototype_dir}/trace.lldb" -- \
            "$(xcrun --find xctest)" "${bundle}" \
            >"${result_dir}/${mode}-default-trace.log" 2>&1
        # Match the library search paths provided by SwiftPM to its helper.
        xcrun lldb --batch \
            -o "settings set target.env-vars DYLD_FRAMEWORK_PATH=${platform}/Library/Frameworks:${platform}/Library/PrivateFrameworks DYLD_LIBRARY_PATH=${platform}/usr/lib:${toolchain}/lib/swift/macosx" \
            -s "${prototype_dir}/trace.lldb" -- \
            "${toolchain}/libexec/swift/pm/swiftpm-testing-helper" \
            --test-bundle-path "${bundle}/Contents/MacOS/PrototypeTests" \
            --testing-library swift-testing \
            >"${result_dir}/${mode}-testing-only-trace.log" 2>&1
        # LLDB can exit successfully after a crashed inferior or a zero-test run.
        for runner in default testing-only; do
            log="${result_dir}/${mode}-${runner}-trace.log"
            grep -q 'exited with status = 0' "${log}"
            grep -q 'Test run with 7 tests in 1 suite passed' "${log}"
        done
    fi
done
