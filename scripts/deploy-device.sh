#!/usr/bin/env bash

set -euo pipefail

: "${BLEAT_DEVICE_ID:?Set BLEAT_DEVICE_ID to the connected device UDID}"
: "${BLEAT_DEVICE_BUILD_DIRECTORY:?Set BLEAT_DEVICE_BUILD_DIRECTORY to the device build directory}"
readonly bleat_bundle_id="${BLEAT_BUNDLE_ID:?Set BLEAT_BUNDLE_ID to the bundle identifier for the app}"
readonly bleat_app="${BLEAT_DEVICE_BUILD_DIRECTORY}/Build/Products/Release-iphoneos/Bleat.app"

./scripts/build-device.sh

xcrun devicectl device install app \
  --device "${BLEAT_DEVICE_ID}" \
  "${bleat_app}"

xcrun devicectl device process launch \
  --device "${BLEAT_DEVICE_ID}" \
  "${bleat_bundle_id}"
