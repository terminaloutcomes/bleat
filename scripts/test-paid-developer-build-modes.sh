#!/usr/bin/env bash

set -euo pipefail

readonly target_name="BleatApp"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/bleat-build-modes.XXXXXX")"
trap 'rm -rf "${temporary_directory}"' EXIT

build_settings() {
  local global_mode="$1"
  local cloudkit_mode="$2"
  local app_attest_mode="$3"
  local carplay_mode="$4"
  local output_path="$5"

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
    BLEAT_CARPLAY_MODE="${carplay_mode}" \
    >"${output_path}"
}

assert_settings() {
  local global_mode="$1"
  local configured_cloudkit_mode="$2"
  local configured_app_attest_mode="$3"
  local configured_carplay_mode="$4"
  local expected_cloudkit_mode="$5"
  local expected_app_attest_mode="$6"
  local expected_carplay_mode="$7"
  local output_path="${temporary_directory}/${global_mode}-${configured_cloudkit_mode}-${configured_app_attest_mode}-${configured_carplay_mode}.json"
  local expected_entitlements="App/Bleat.cloudkit-${expected_cloudkit_mode}.app-attest-${expected_app_attest_mode}.entitlements"
  if [[ "${expected_carplay_mode}" == "enabled" ]]; then
    expected_entitlements="App/Bleat.cloudkit-${expected_cloudkit_mode}.app-attest-${expected_app_attest_mode}.carplay-enabled.entitlements"
  fi

  build_settings \
    "${global_mode}" \
    "${configured_cloudkit_mode}" \
    "${configured_app_attest_mode}" \
    "${configured_carplay_mode}" \
    "${output_path}"

  jq -e \
    --arg target "${target_name}" \
    --arg cloudkit "${expected_cloudkit_mode}" \
    --arg app_attest "${expected_app_attest_mode}" \
    --arg carplay "${expected_carplay_mode}" \
    --arg entitlements "${expected_entitlements}" \
    'any(.[];
      .target == $target
      and .buildSettings.BLEAT_EFFECTIVE_CLOUDKIT_MODE == $cloudkit
      and .buildSettings.BLEAT_EFFECTIVE_APP_ATTEST_MODE == $app_attest
      and .buildSettings.BLEAT_EFFECTIVE_CARPLAY_MODE == $carplay
      and .buildSettings.CODE_SIGN_ENTITLEMENTS == $entitlements
    )' \
    "${output_path}" >/dev/null
}

for carplay_mode in disabled enabled; do
  assert_settings NO enabled enabled "${carplay_mode}" enabled enabled "${carplay_mode}"
  assert_settings NO enabled disabled "${carplay_mode}" enabled disabled "${carplay_mode}"
  assert_settings NO disabled enabled "${carplay_mode}" disabled enabled "${carplay_mode}"
  assert_settings NO disabled disabled "${carplay_mode}" disabled disabled "${carplay_mode}"
done
assert_settings YES enabled enabled enabled disabled disabled disabled

macos_settings="${temporary_directory}/macos-carplay-enabled.json"
xcodebuild \
  -project Bleat.xcodeproj \
  -target "${target_name}" \
  -configuration Release \
  -sdk macosx \
  -showBuildSettings \
  -json \
  BUILD_WITHOUT_PAID_DEVELOPER=NO \
  BLEAT_CLOUDKIT_MODE=enabled \
  BLEAT_APP_ATTEST_MODE=enabled \
  BLEAT_CARPLAY_MODE=enabled \
  >"${macos_settings}"
jq -e \
  --arg target "${target_name}" \
  'any(.[];
    .target == $target
    and .buildSettings.BLEAT_EFFECTIVE_CARPLAY_MODE == "disabled"
    and .buildSettings.CODE_SIGN_ENTITLEMENTS == "App/BleatMac.enabled.entitlements"
  )' \
  "${macos_settings}" >/dev/null

fully_disabled_entitlements="App/Bleat.cloudkit-disabled.app-attest-disabled.entitlements"
if plutil -p "${fully_disabled_entitlements}" | rg -q 'icloud|appattest'; then
  echo "fully disabled entitlements contain a paid capability" >&2
  exit 1
fi
if rg -l 'com\.apple\.developer\.carplay-audio' App/BleatMac.*.entitlements >/dev/null; then
  echo "macOS entitlements unexpectedly contain CarPlay" >&2
  exit 1
fi
for entitlements in App/Bleat.cloudkit-*.carplay-enabled.entitlements; do
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.carplay-audio' "${entitlements}")" != "true" ]]; then
    echo "CarPlay-enabled entitlements do not enable CarPlay audio: ${entitlements}" >&2
    exit 1
  fi
done
for entitlements in App/Bleat.cloudkit-*.entitlements; do
  if [[ "${entitlements}" != *.carplay-enabled.entitlements ]] \
    && /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.carplay-audio' "${entitlements}" >/dev/null 2>&1; then
    echo "CarPlay-disabled entitlements contain CarPlay audio: ${entitlements}" >&2
    exit 1
  fi
done

if [[ "$(plutil -extract BleatCloudKitMode raw App/Info.plist)" != "\$(BLEAT_EFFECTIVE_CLOUDKIT_MODE)" ]]; then
  echo "Info.plist does not use the effective CloudKit mode" >&2
  exit 1
fi
if [[ "$(plutil -extract BleatAppAttestMode raw App/Info.plist)" != "\$(BLEAT_EFFECTIVE_APP_ATTEST_MODE)" ]]; then
  echo "Info.plist does not use the effective App Attest mode" >&2
  exit 1
fi
if [[ "$(plutil -extract BleatCarPlayMode raw App/Info.plist)" != "\$(BLEAT_EFFECTIVE_CARPLAY_MODE)" ]]; then
  echo "Info.plist does not use the effective CarPlay mode" >&2
  exit 1
fi
if ! plutil -p "${fully_disabled_entitlements}" | rg -q 'keychain-access-groups'; then
  echo "fully disabled entitlements omit Keychain access" >&2
  exit 1
fi

assert_validation_fails() {
  local global_mode="$1"
  local cloudkit_mode="$2"
  local app_attest_mode="$3"
  local carplay_mode="$4"

  if BUILD_WITHOUT_PAID_DEVELOPER="${global_mode}" \
    BLEAT_CLOUDKIT_MODE="${cloudkit_mode}" \
    BLEAT_APP_ATTEST_MODE="${app_attest_mode}" \
    BLEAT_CARPLAY_MODE="${carplay_mode}" \
    ./scripts/validate-paid-developer-build-settings.sh >/dev/null 2>&1; then
    echo "invalid capability modes unexpectedly passed validation" >&2
    exit 1
  fi
}

assert_validation_fails MAYBE enabled enabled disabled
assert_validation_fails NO unsupported enabled disabled
assert_validation_fails NO enabled unsupported disabled
assert_validation_fails NO enabled enabled unsupported

echo "Verified paid-capability build modes"
