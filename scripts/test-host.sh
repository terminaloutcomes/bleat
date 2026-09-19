#!/bin/zsh
set -euo pipefail

readonly script_dir="${0:A:h}"
readonly repository="${script_dir:h}"
cd "${repository}"
readonly results=".build/host-results"
readonly coverage=".build/coverage/swift-host"
mkdir -p "${results}" "${coverage}"
# Only this gate owns these reports. SwiftPM also clears its coverage directory
# before each instrumented run; save each product's profile before the next run.
rm -f "${results}"/*.xml(N) "${coverage}"/*.profdata(N) \
    "${coverage}/lcov.info" "${coverage}/raw.lcov"

swift build --build-tests --enable-code-coverage
readonly bin_dir="$(swift build --show-bin-path)"
readonly codecov="$(swift test --show-codecov-path)"
# Swift 6.2's native backend emits one package test product; SwiftBuild emits
# one per target. Select actual built products, never parse tool version text.
products=()
if [[ -f "${bin_dir}/BleatCoreAppPackageTests.xctest/Contents/MacOS/BleatCoreAppPackageTests" ]]; then
    products=(BleatCoreAppPackageTests)
else
    products=(BleatCoreTests BleatTranscriptionTests)
fi
reports=()
profiles=()
objects=()
for product in "${products[@]}"; do
    binary="${bin_dir}/${product}.xctest/Contents/MacOS/${product}"
    [[ -f "${binary}" ]] || { print -u2 "Missing host test product: ${product}"; exit 1; }
    # Explicit product selection prevents another helper overwriting the XML.
    # Global serialization preserves shared URLProtocol/process-state fixtures.
    swift test --skip-build --disable-xctest --no-parallel \
        --test-product "${product}" --enable-code-coverage \
        --xunit-output "${results}/${product}.xml"
    reports+=("${results}/${product}.xml")
    cp "${codecov:h}/default.profdata" "${coverage}/${product}.profdata"
    profiles+=("${coverage}/${product}.profdata")
    objects+=(-object "${binary}")
done
python3 TestSupport/HostTests/reports.py results \
    TestSupport/HostTests/inventory.json "${results}/tests.xml" "${reports[@]}"
xcrun llvm-profdata merge -sparse "${profiles[@]}" -o "${coverage}/combined.profdata"
xcrun llvm-cov export -format=lcov \
    -instr-profile "${coverage}/combined.profdata" "${objects[@]}" \
    > "${coverage}/raw.lcov"
python3 TestSupport/HostTests/reports.py coverage \
    "${coverage}/raw.lcov" "${repository}" "${coverage}/lcov.info"
