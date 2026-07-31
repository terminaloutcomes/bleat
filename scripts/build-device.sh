#!/usr/bin/env bash

set -euo pipefail

BUILD_VERBOSE="${BUILD_VERBOSE:-false}"
BUILD_VERBOSE_FLAG="-quiet"
if [[ "${BUILD_VERBOSE}" == "true" ]]; then
  BUILD_VERBOSE_FLAG=""
fi

: "${BLEAT_DEVELOPMENT_TEAM:?Set BLEAT_DEVELOPMENT_TEAM to the Apple team ID}"
: "${BLEAT_DEVICE_ID:?Set BLEAT_DEVICE_ID to the connected iPhone UDID}"
readonly bleat_bundle_id="${BLEAT_BUNDLE_ID:-com.yaleman.Bleat}"

xcodebuild \
  -project Bleat.xcodeproj \
  -scheme Bleat \
  ${BUILD_VERBOSE_FLAG} \
  -configuration Release \
  -destination "platform=iOS,id=${BLEAT_DEVICE_ID}" \
  -derivedDataPath .build/device-release \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="${BLEAT_DEVELOPMENT_TEAM}" \
  CODE_SIGN_STYLE=Automatic \
  PRODUCT_BUNDLE_IDENTIFIER="${bleat_bundle_id}" \
  BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
  build