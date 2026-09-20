#!/bin/zsh
set -euo pipefail

readonly script_dir="${0:A:h}"
readonly repository="${script_dir:h}"
cd "${repository}"
readonly results=".build/host-results"
readonly coverage=".build/coverage/swift-host"
readonly signing="${BLEAT_HOST_SIGNING:-required}"
case "${signing}" in
    required) : "${BLEAT_DEVELOPMENT_TEAM:?Set BLEAT_DEVELOPMENT_TEAM for signed host tests}" ;;
    unsigned) print 'Unsigned coverage lane: synchronizable Keychain test is excluded' ;;
    *) print -u2 'BLEAT_HOST_SIGNING must be required or unsigned'; exit 64 ;;
esac
export BLEAT_HOST_SIGNING="${signing}"
mkdir -p "${results}" "${coverage}"
# Only this gate owns these reports. SwiftPM also clears its coverage directory
# before each instrumented run; save each product's profile before the next run.
rm -f "${results}"/*.xml(N) "${coverage}"/*.profdata(N) \
    "${coverage}/lcov.info" "${coverage}/raw.lcov" "${coverage}"/*.profraw(N)

swift build --build-tests --enable-code-coverage
readonly bin_dir="$(swift build --show-bin-path)"
if [[ "${signing}" == required ]]; then
    mkdir -p .build/host-runner
    cp TestSupport/HostTests/Runner.entitlements .build/host-runner/Runner.entitlements
    xcodegen generate --spec TestSupport/HostTests/project.yml --project .build/host-runner
    xcodebuild -quiet -project .build/host-runner/BleatHostRunner.xcodeproj \
        -scheme BleatHostRunner -configuration Debug \
        -destination "platform=macOS,arch=$(uname -m)" \
        -derivedDataPath .build/host-runner-derived -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="${BLEAT_DEVELOPMENT_TEAM}" build
    runner_app="${repository}/.build/host-runner-derived/Build/Products/Debug/BleatHostRunner.app"
    codesign --verify --strict "${runner_app}"
    [[ -f "${runner_app}/Contents/embedded.provisionprofile" ]] || {
        print -u2 'Signed host is missing its provisioning profile'; exit 1
    }
    codesign -d --entitlements - --xml "${runner_app}" > "${results}/runner-entitlements.plist" 2>/dev/null
    python3 - "${results}/runner-entitlements.plist" <<'PYVERIFY'
import os, plistlib, sys
from pathlib import Path
entitlements = plistlib.loads(Path(sys.argv[1]).read_bytes())
team = os.environ["BLEAT_DEVELOPMENT_TEAM"]
app_id = team + ".com.terminaloutcomes.Bleat.HostTests"
if (entitlements.get("com.apple.developer.team-identifier") != team
        or entitlements.get("com.apple.application-identifier") != app_id
        or entitlements.get("keychain-access-groups") != [app_id]):
    sys.exit("Signed host does not carry the required team, application, and Keychain entitlements")
print("Verified signed host identity, Keychain entitlement, and profile presence")
PYVERIFY
    platform="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
    swift_bin="$(xcrun --find swift)"
    toolchain="${swift_bin:h:h}"
else
    codecov="$(swift test --show-codecov-path)"
fi
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
    if [[ "${signing}" == required ]]; then
        # Run a provisioned copy of SwiftPM's helper; never modify Xcode itself.
        DYLD_FRAMEWORK_PATH="${platform}/Library/Frameworks:${platform}/Library/PrivateFrameworks" \
        DYLD_LIBRARY_PATH="${platform}/usr/lib:${toolchain}/lib/swift/macosx" \
        LLVM_PROFILE_FILE="${repository}/${coverage}/${product}-%p-%m.profraw" \
            "${runner_app}/Contents/MacOS/BleatHostRunner" \
            --test-bundle-path "${binary}" --testing-library swift-testing \
            --no-parallel --xunit-output "${results}/${product}.xml"
        raw_profiles=("${coverage}/${product}-"*.profraw(N))
        (( ${#raw_profiles} > 0 )) || { print -u2 'Signed host produced no coverage profiles'; exit 1; }
        xcrun llvm-profdata merge -sparse "${raw_profiles[@]}" -o "${coverage}/${product}.profdata"
    else
        # Explicit product selection prevents another helper overwriting the XML.
        swift test --skip-build --disable-xctest --no-parallel \
            --test-product "${product}" --enable-code-coverage \
            --xunit-output "${results}/${product}.xml"
        cp "${codecov:h}/default.profdata" "${coverage}/${product}.profdata"
    fi
    reports+=("${results}/${product}.xml")
    profiles+=("${coverage}/${product}.profdata")
    objects+=(-object "${binary}")
done
verification_flags=()
if [[ "${signing}" == unsigned ]]; then
    verification_flags=(--allow-unsigned-keychain-skip)
fi
python3 TestSupport/HostTests/reports.py results "${verification_flags[@]}" \
    TestSupport/HostTests/inventory.json "${results}/tests.xml" "${reports[@]}"
xcrun llvm-profdata merge -sparse "${profiles[@]}" -o "${coverage}/combined.profdata"
xcrun llvm-cov export -format=lcov \
    -instr-profile "${coverage}/combined.profdata" "${objects[@]}" \
    > "${coverage}/raw.lcov"
python3 TestSupport/HostTests/reports.py coverage \
    "${coverage}/raw.lcov" "${repository}" "${coverage}/lcov.info"
