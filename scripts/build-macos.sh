#!/usr/bin/env bash

set -euo pipefail

BUILD_VERBOSE="${BUILD_VERBOSE:-false}"
BUILD_VERBOSE_FLAG="-quiet"
if [[ "${BUILD_VERBOSE}" == "true" ]]; then
  BUILD_VERBOSE_FLAG=""
fi

: "${BLEAT_DEVELOPMENT_TEAM:?Set BLEAT_DEVELOPMENT_TEAM to the Apple team ID}"
readonly bleat_bundle_id="${BLEAT_BUNDLE_ID:?Set BLEAT_BUNDLE_ID to the bundle identifier for the app}"
readonly bleat_app=".build/macos-signed/Build/Products/Release-maccatalyst/Bleat.app"
# shellcheck disable=SC2155
readonly entitlements_file="$(mktemp "${TMPDIR:-/tmp}/bleat-entitlements.XXXXXX")"
# shellcheck disable=SC2155
readonly codesign_output="$(mktemp "${TMPDIR:-/tmp}/bleat-codesign.XXXXXX")"
trap 'rm -f "${entitlements_file}" "${codesign_output}"' EXIT

xcodebuild \
  -project Bleat.xcodeproj \
  -scheme BleatMac \
  -configuration Release \
  ${BUILD_VERBOSE_FLAG} \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath .build/macos-signed \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="${BLEAT_DEVELOPMENT_TEAM}" \
  CODE_SIGN_STYLE=Automatic \
  PRODUCT_BUNDLE_IDENTIFIER="${bleat_bundle_id}" \
  BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
  BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
  BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-disabled}" \
  build

codesign --verify --deep --strict "${bleat_app}" || {
  echo "Failed to verify codesign for ${bleat_app}. Output:"
  cat "${codesign_output}"
  exit 1
}
codesign -d --entitlements :- "${bleat_app}" >"${entitlements_file}" 2>"${codesign_output}" || {
  echo "Failed to verify codesign for ${bleat_app}. Output:"
  cat "${codesign_output}"
  exit 1
}
plutil -extract keychain-access-groups.0 raw \
  "${entitlements_file}" >/dev/null
codesign -dvv "${bleat_app}" >"${codesign_output}" 2>&1
grep -Eq '^TeamIdentifier=[A-Z0-9]+$' "${codesign_output}"
echo "opening ${bleat_app} ..."
open "${bleat_app}"
