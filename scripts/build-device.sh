#!/usr/bin/env bash

set -euo pipefail

BUILD_VERBOSE="${BUILD_VERBOSE:-false}"
BUILD_VERBOSE_FLAG="-quiet"
if [[ "${BUILD_VERBOSE}" == "true" ]]; then
  BUILD_VERBOSE_FLAG=""
fi

: "${BLEAT_DEVELOPMENT_TEAM:?Set BLEAT_DEVELOPMENT_TEAM to the Apple team ID}"
: "${BLEAT_DEVICE_ID:?Set BLEAT_DEVICE_ID to the connected iPhone UDID}"
readonly bleat_bundle_id="${BLEAT_BUNDLE_ID:?Set BLEAT_BUNDLE_ID to the bundle identifier for the app}"
readonly bleat_app=".build/device-release/Build/Products/Release-iphoneos/Bleat.app"

if [ -d "${bleat_app}" ]; then
  echo "Removing existing build at ${bleat_app} before building..."
  rm -rf "${bleat_app}"
fi

xcodebuild \
  -project Bleat.xcodeproj \
  -scheme "Bleat (Bleat project)" \
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
  build | rg -v "Supported platforms for the buildables in the current scheme is empty"

if [[ ! -d "${bleat_app}" ]]; then
  echo "xcodebuild succeeded without producing ${bleat_app}" >&2
  exit 1
fi

built_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${bleat_app}/Info.plist")"
if [[ "${built_bundle_id}" != "${bleat_bundle_id}" ]]; then
  echo "built bundle identifier ${built_bundle_id} does not match ${bleat_bundle_id}" >&2
  exit 1
fi
