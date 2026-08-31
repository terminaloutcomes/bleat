#!/usr/bin/env bash

set -euo pipefail

BUILD_VERBOSE="${BUILD_VERBOSE:-false}"
BUILD_VERBOSE_FLAG="-quiet"
if [[ "${BUILD_VERBOSE}" == "true" ]]; then
  BUILD_VERBOSE_FLAG=""
fi

readonly bleat_telemetry_auth_base_url="${BLEAT_TELEMETRY_AUTH_BASE_URL:?Set BLEAT_TELEMETRY_AUTH_BASE_URL to the production HTTPS authentication origin}"
readonly bleat_telemetry_otlp_endpoint="${BLEAT_TELEMETRY_OTLP_ENDPOINT:?Set BLEAT_TELEMETRY_OTLP_ENDPOINT to the production HTTPS OTLP origin}"

if [[ "${bleat_telemetry_auth_base_url}" != https://?* ]]; then
  echo "BLEAT_TELEMETRY_AUTH_BASE_URL must be an HTTPS URL" >&2
  exit 1
fi
if [[ "${bleat_telemetry_otlp_endpoint}" != https://?* ]]; then
  echo "BLEAT_TELEMETRY_OTLP_ENDPOINT must be an HTTPS URL" >&2
  exit 1
fi

: "${BLEAT_DEVELOPMENT_TEAM:?Set BLEAT_DEVELOPMENT_TEAM to the Apple team ID}"
: "${BLEAT_DEVICE_ID:?Set BLEAT_DEVICE_ID to the connected device UDID}"
: "${BLEAT_DEVICE_BUILD_DIRECTORY:?Set BLEAT_DEVICE_BUILD_DIRECTORY to the device build directory}"
readonly bleat_bundle_id="${BLEAT_BUNDLE_ID:?Set BLEAT_BUNDLE_ID to the bundle identifier for the app}"
readonly bleat_app="${BLEAT_DEVICE_BUILD_DIRECTORY}/Build/Products/Release-iphoneos/Bleat.app"
readonly requested_carplay_mode="${BLEAT_CARPLAY_MODE:-disabled}"

if [ -d "${bleat_app}" ]; then
  echo "Removing existing build at ${bleat_app} before building..."
  rm -rf "${bleat_app}"
fi

readonly build_without_paid_developer="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}"

echo "Building Bleat for the configured device..."

xcodebuild \
  -project Bleat.xcodeproj \
  -scheme Bleat \
  ${BUILD_VERBOSE_FLAG} \
  -configuration Release \
  -destination "platform=iOS,id=${BLEAT_DEVICE_ID}" \
  -derivedDataPath "${BLEAT_DEVICE_BUILD_DIRECTORY}" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="${BLEAT_DEVELOPMENT_TEAM}" \
  CODE_SIGN_STYLE=Automatic \
  PRODUCT_BUNDLE_IDENTIFIER="${bleat_bundle_id}" \
  BUILD_WITHOUT_PAID_DEVELOPER="${build_without_paid_developer}" \
  BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
  BLEAT_CARPLAY_MODE="${BLEAT_CARPLAY_MODE:-disabled}" \
  BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
  BLEAT_TELEMETRY_AUTH_BASE_URL="${bleat_telemetry_auth_base_url}" \
  BLEAT_TELEMETRY_OTLP_ENDPOINT="${bleat_telemetry_otlp_endpoint}" \
  build | {
    # rg exits 1 when it filters every line; the successful build must remain
    # successful in that quiet-output case.
    if rg -v "Supported platforms for the buildables in the current scheme is empty"; then
      :
    else
      rg_status=$?
      [[ "${rg_status}" -eq 1 ]]
    fi
  }

if [[ ! -d "${bleat_app}" ]]; then
  echo "xcodebuild succeeded without producing ${bleat_app}" >&2
  exit 1
fi

built_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${bleat_app}/Info.plist")"
if [[ "${built_bundle_id}" != "${bleat_bundle_id}" ]]; then
  echo "built bundle identifier does not match the configured identifier" >&2
  exit 1
fi

built_telemetry_auth_base_url="$(/usr/libexec/PlistBuddy -c 'Print :BleatTelemetryAuthenticationBaseURL' "${bleat_app}/Info.plist")"
built_telemetry_otlp_endpoint="$(/usr/libexec/PlistBuddy -c 'Print :BleatTelemetryOTLPEndpoint' "${bleat_app}/Info.plist")"
if [[ "${built_telemetry_auth_base_url}" != "${bleat_telemetry_auth_base_url}" \
  || "${built_telemetry_otlp_endpoint}" != "${bleat_telemetry_otlp_endpoint}" ]]; then
  echo "built telemetry configuration does not match the supplied environment" >&2
  exit 1
fi

effective_carplay_mode="${requested_carplay_mode}"
if [[ "${build_without_paid_developer}" == "YES" ]]; then
  effective_carplay_mode="disabled"
fi
built_carplay_mode="$(/usr/libexec/PlistBuddy -c 'Print :BleatCarPlayMode' "${bleat_app}/Info.plist")"
if [[ "${built_carplay_mode}" != "${effective_carplay_mode}" ]]; then
  echo "built CarPlay mode does not match the effective mode" >&2
  exit 1
fi

readonly carplay_entitlement="com.apple.developer.carplay-audio"
signed_entitlements_plist="$(mktemp "${TMPDIR:-/tmp}/bleat-device-entitlements.XXXXXX")"
profile_plist=""
trap 'rm -f "${signed_entitlements_plist}" "${profile_plist}"' EXIT
codesign -d --entitlements :- "${bleat_app}" >"${signed_entitlements_plist}" 2>/dev/null
signed_entitlements="$(<"${signed_entitlements_plist}")"
if [[ "${effective_carplay_mode}" == "enabled" ]]; then
  if [[ "$(/usr/libexec/PlistBuddy -c "Print :${carplay_entitlement}" "${signed_entitlements_plist}" 2>/dev/null)" != "true" ]]; then
    echo "CarPlay-enabled build is missing the signed CarPlay audio entitlement" >&2
    exit 1
  fi
  profile_plist="$(mktemp "${TMPDIR:-/tmp}/bleat-device-profile.XXXXXX")"
  security cms -D -i "${bleat_app}/embedded.mobileprovision" >"${profile_plist}"
  if [[ "$(/usr/libexec/PlistBuddy -c "Print :Entitlements:${carplay_entitlement}" "${profile_plist}")" != "true" ]]; then
    echo "CarPlay-enabled build profile does not authorize CarPlay audio" >&2
    exit 1
  fi
elif /usr/libexec/PlistBuddy -c "Print :${carplay_entitlement}" "${signed_entitlements_plist}" >/dev/null 2>&1; then
  echo "CarPlay-disabled build unexpectedly contains the signed CarPlay audio entitlement" >&2
  exit 1
fi

if [[ "${build_without_paid_developer}" == "YES" ]]; then
  readonly app_attest_entitlement="com.apple.developer.devicecheck.appattest-environment"
  readonly cloudkit_entitlement_prefix="com.apple.developer.icloud-"
  readonly keychain_entitlement="keychain-access-groups"
  if [[ "${signed_entitlements}" == *"${app_attest_entitlement}"* ]]; then
    echo "Personal-Team build unexpectedly contains the App Attest entitlement" >&2
    exit 1
  fi
  if [[ "${signed_entitlements}" == *"${cloudkit_entitlement_prefix}"* ]]; then
    echo "Personal-Team build unexpectedly contains the CloudKit entitlement" >&2
    exit 1
  fi
  if [[ "${signed_entitlements}" != *"${keychain_entitlement}"* ]]; then
    echo "Personal-Team build is missing the Keychain entitlement" >&2
    exit 1
  fi

  built_app_attest_mode="$(/usr/libexec/PlistBuddy -c 'Print :BleatAppAttestMode' "${bleat_app}/Info.plist")"
  built_cloudkit_mode="$(/usr/libexec/PlistBuddy -c 'Print :BleatCloudKitMode' "${bleat_app}/Info.plist")"
  if [[ "${built_app_attest_mode}" != "disabled" \
    || "${built_cloudkit_mode}" != "disabled" \
    || "${built_carplay_mode}" != "disabled" ]]; then
    echo "Personal-Team build did not record every effective paid mode as disabled" >&2
    exit 1
  fi
fi
