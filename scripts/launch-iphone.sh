#!/usr/bin/env bash

set -euo pipefail

BUILD_VERBOSE="${BUILD_VERBOSE:-false}"
BUILD_VERBOSE_FLAG="-quiet"
if [[ "${BUILD_VERBOSE}" == "true" ]]; then
  BUILD_VERBOSE_FLAG=""
fi

readonly bleat_simulator_name="${BLEAT_SIMULATOR_NAME:-iPhone 17 Pro}"
bleat_simulator_id="$(
  xcrun simctl list devices available --json \
    | jq -r --arg name "${bleat_simulator_name}" '
      [.devices
        | to_entries[]
        | select(.key | startswith("com.apple.CoreSimulator.SimRuntime.iOS-"))]
      | sort_by(.key)
      | [.[].value[] | select(.name == $name and .isAvailable)]
      | last
      | .udid // empty
    '
)"
readonly bleat_simulator_id
if [[ -z "${bleat_simulator_id}" ]]; then
  echo "No available ${bleat_simulator_name} Simulator was found" >&2
  exit 1
fi

if ! xcrun simctl list devices booted --json \
  | jq -e --arg id "${bleat_simulator_id}" \
    'any(.devices[][]; .udid == $id)' >/dev/null; then
  xcrun simctl boot "${bleat_simulator_id}"
fi
xcrun simctl bootstatus "${bleat_simulator_id}" -b
open -a Simulator --args -CurrentDeviceUDID "${bleat_simulator_id}"

xcodebuild \
  -project Bleat.xcodeproj \
  -scheme Bleat \
  -configuration Debug \
  ${BUILD_VERBOSE_FLAG} \
  -destination "id=${bleat_simulator_id}" \
  -derivedDataPath .build/xcode-derived \
  BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
  BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
  BLEAT_CARPLAY_MODE="${BLEAT_CARPLAY_MODE:-disabled}" \
  BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
  build

xcrun simctl install "${bleat_simulator_id}" \
  .build/xcode-derived/Build/Products/Debug-iphonesimulator/Bleat.app
xcrun simctl launch --terminate-running-process \
  "${bleat_simulator_id}" \
  com.terminaloutcomes.Bleat
