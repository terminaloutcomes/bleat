#!/bin/zsh

set -euo pipefail

swift test --enable-code-coverage
swift build -c release

if [[ "${BLEAT_SKIP_SIMULATOR:-0}" == "1" ]]; then
    exit 0
fi

simulator_destination="${BLEAT_SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}"

xcodebuild \
    -project Bleat.xcodeproj \
    -resolvePackageDependencies \
    -scheme Bleat \
    BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
    -derivedDataPath .build/xcode-derived

xcodebuild \
    -quiet \
    -project Bleat.xcodeproj \
    -scheme Bleat \
    -configuration Release \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath .build/xcode-derived \
    BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
    build

xcodebuild \
    -quiet \
    -project Bleat.xcodeproj \
    -scheme Bleat \
    -destination "${simulator_destination}" \
    -derivedDataPath .build/xcode-derived \
    BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
    -enableCodeCoverage YES \
    test
