#!/usr/bin/env bash

set -euo pipefail

BUILD_VERBOSE="${BUILD_VERBOSE:-false}"
BUILD_VERBOSE_FLAG="-quiet"
if [[ "${BUILD_VERBOSE}" == "true" ]]; then
  BUILD_VERBOSE_FLAG=""
fi

: "${BLEAT_DEVELOPMENT_TEAM:?Set BLEAT_DEVELOPMENT_TEAM to the Apple team ID}"
: "${BLEAT_DEVICE_ID:?Set BLEAT_DEVICE_ID to the connected device UDID}"
: "${BLEAT_DEVICE_BUILD_DIRECTORY:?Set BLEAT_DEVICE_BUILD_DIRECTORY to the device build directory}"
readonly bleat_bundle_id="${BLEAT_BUNDLE_ID:?Set BLEAT_BUNDLE_ID to the bundle identifier for the app}"
readonly bleat_app="${BLEAT_DEVICE_BUILD_DIRECTORY}/Build/Products/Release-iphoneos/Bleat.app"

if [ -d "${bleat_app}" ]; then
  echo "Removing existing build at ${bleat_app} before building..."
  rm -rf "${bleat_app}"
fi

readonly build_without_paid_developer="${BUILD_WITHOUT_PAID_DEVELOPER:-YES}"

echo "Building Bleat for the configured device with bundle identifier ${bleat_bundle_id}..."

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
  BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
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
  echo "built bundle identifier ${built_bundle_id} does not match ${bleat_bundle_id}" >&2
  exit 1
fi

if [[ "${build_without_paid_developer}" == "YES" ]]; then
  readonly app_attest_entitlement="com.apple.developer.devicecheck.appattest-environment"
  readonly cloudkit_entitlement_prefix="com.apple.developer.icloud-"
  readonly keychain_entitlement="keychain-access-groups"
  signed_entitlements="$(codesign -d --entitlements :- "${bleat_app}" 2>/dev/null)"

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
  if [[ "${built_app_attest_mode}" != "disabled" || "${built_cloudkit_mode}" != "disabled" ]]; then
    echo "Personal-Team build did not record both effective modes as disabled" >&2
    exit 1
  fi
fi
