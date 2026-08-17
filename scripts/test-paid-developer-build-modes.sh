#!/usr/bin/env bash

set -euo pipefail

readonly target_name="BleatApp"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/bleat-build-modes.XXXXXX")"
trap 'rm -rf "${temporary_directory}"' EXIT

build_settings() {
  local global_mode="$1"
  local cloudkit_mode="$2"
  local app_attest_mode="$3"
  local output_path="$4"

  xcodebuild \
    -project Bleat.xcodeproj \
    -target "${target_name}" \
    -configuration Release \
    -sdk iphoneos \
    -showBuildSettings \
    -json \
    BUILD_WITHOUT_PAID_DEVELOPER="${global_mode}" \
    BLEAT_CLOUDKIT_MODE="${cloudkit_mode}" \
    BLEAT_APP_ATTEST_MODE="${app_attest_mode}" \
    >"${output_path}"
}

assert_settings() {
  local global_mode="$1"
  local configured_cloudkit_mode="$2"
  local configured_app_attest_mode="$3"
  local expected_cloudkit_mode="$4"
  local expected_app_attest_mode="$5"
  local output_path="${temporary_directory}/${global_mode}-${configured_cloudkit_mode}-${configured_app_attest_mode}.json"
  local expected_entitlements="App/Bleat.cloudkit-${expected_cloudkit_mode}.app-attest-${expected_app_attest_mode}.entitlements"

  build_settings \
    "${global_mode}" \
    "${configured_cloudkit_mode}" \
    "${configured_app_attest_mode}" \
    "${output_path}"

  jq -e \
    --arg target "${target_name}" \
    --arg cloudkit "${expected_cloudkit_mode}" \
    --arg app_attest "${expected_app_attest_mode}" \
    --arg entitlements "${expected_entitlements}" \
    'any(.[];
      .target == $target
      and .buildSettings.BLEAT_EFFECTIVE_CLOUDKIT_MODE == $cloudkit
      and .buildSettings.BLEAT_EFFECTIVE_APP_ATTEST_MODE == $app_attest
      and .buildSettings.CODE_SIGN_ENTITLEMENTS == $entitlements
    )' \
    "${output_path}" >/dev/null
}

assert_settings NO enabled enabled enabled enabled
assert_settings NO enabled disabled enabled disabled
assert_settings NO disabled enabled disabled enabled
assert_settings NO disabled disabled disabled disabled
assert_settings YES enabled enabled disabled disabled

fully_disabled_entitlements="App/Bleat.cloudkit-disabled.app-attest-disabled.entitlements"
if plutil -p "${fully_disabled_entitlements}" | rg -q 'icloud|appattest'; then
  echo "fully disabled entitlements contain a paid capability" >&2
  exit 1
fi

if [[ "$(plutil -extract BleatCloudKitMode raw App/Info.plist)" != "\$(BLEAT_EFFECTIVE_CLOUDKIT_MODE)" ]]; then
  echo "Info.plist does not use the effective CloudKit mode" >&2
  exit 1
fi
if [[ "$(plutil -extract BleatAppAttestMode raw App/Info.plist)" != "\$(BLEAT_EFFECTIVE_APP_ATTEST_MODE)" ]]; then
  echo "Info.plist does not use the effective App Attest mode" >&2
  exit 1
fi
if ! plutil -p "${fully_disabled_entitlements}" | rg -q 'keychain-access-groups'; then
  echo "fully disabled entitlements omit Keychain access" >&2
  exit 1
fi

if BUILD_WITHOUT_PAID_DEVELOPER=MAYBE \
  BLEAT_CLOUDKIT_MODE=enabled \
  BLEAT_APP_ATTEST_MODE=enabled \
  ./scripts/validate-paid-developer-build-settings.sh >/dev/null 2>&1; then
  echo "invalid global mode unexpectedly passed validation" >&2
  exit 1
fi

echo "Verified paid-capability build modes"
