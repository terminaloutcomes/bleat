#!/usr/bin/env bash

set -euo pipefail

BUILD_VERBOSE="${BUILD_VERBOSE:-false}"
BUILD_VERBOSE_FLAG="-quiet"
if [[ "${BUILD_VERBOSE}" == "true" ]]; then
  BUILD_VERBOSE_FLAG=""
fi

xcodebuild \
  -project Bleat.xcodeproj \
  -scheme Bleat \
  -configuration Debug \
  ${BUILD_VERBOSE_FLAG} \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/xcode-derived \
  BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
  BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
  BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
  build

xcrun simctl install booted \
  .build/xcode-derived/Build/Products/Debug-iphonesimulator/Bleat.app
xcrun simctl launch --terminate-running-process booted com.yaleman.Bleat
