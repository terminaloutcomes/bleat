#!/usr/bin/env bash

set -euo pipefail

BUILD_VERBOSE="${BUILD_VERBOSE:-false}"
BUILD_VERBOSE_FLAG="-quiet"
if [[ "${BUILD_VERBOSE}" == "true" ]]; then
  BUILD_VERBOSE_FLAG=""
fi

: "${BLEAT_DEVELOPMENT_TEAM:?Set BLEAT_DEVELOPMENT_TEAM to the Apple team ID}"
readonly bleat_bundle_id="${BLEAT_BUNDLE_ID:-com.yaleman.Bleat}"

xcodebuild \
  -project Bleat.xcodeproj \
  -scheme BleatMac \
  ${BUILD_VERBOSE_FLAG} \
  -configuration Debug \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath .build/macos-signed \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="${BLEAT_DEVELOPMENT_TEAM}" \
  CODE_SIGN_STYLE=Automatic \
  PRODUCT_BUNDLE_IDENTIFIER="${bleat_bundle_id}" \
  BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
  test