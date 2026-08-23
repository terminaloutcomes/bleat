#!/bin/zsh

set -euo pipefail


readonly bleat_script_dir="${0:A:h}"
readonly bleat_repository_root="${bleat_script_dir:h}"
readonly bleat_archive_path="${BLEAT_ARCHIVE_PATH:-${bleat_repository_root}/.build/Bleat.xcarchive}"
readonly bleat_project_configuration="${bleat_repository_root}/project.yml"

readonly bleat_expected_version="$(
    awk '$1 == "MARKETING_VERSION:" {
        gsub(/"/, "", $2)
        print $2
        exit
    }' "${bleat_project_configuration}"
)"
readonly bleat_expected_build="$(
    awk '$1 == "CURRENT_PROJECT_VERSION:" {
        gsub(/"/, "", $2)
        print $2
        exit
    }' "${bleat_project_configuration}"
)"

if [[ -z "${bleat_expected_version}" || -z "${bleat_expected_build}" ]]; then
    print -u2 "Could not read the app version and build from project.yml"
    exit 1
fi

BUILD_VERBOSE="${BUILD_VERBOSE:-false}"
BUILD_VERBOSE_FLAG="-quiet"
if [[ "${BUILD_VERBOSE}" == "true" ]]; then
  BUILD_VERBOSE_FLAG=""
fi

readonly bleat_telemetry_auth_base_url="${BLEAT_TELEMETRY_AUTH_BASE_URL:?Set BLEAT_TELEMETRY_AUTH_BASE_URL to the production HTTPS authentication origin}"
readonly bleat_telemetry_otlp_endpoint="${BLEAT_TELEMETRY_OTLP_ENDPOINT:?Set BLEAT_TELEMETRY_OTLP_ENDPOINT to the production HTTPS OTLP origin}"

if [[ "${bleat_telemetry_auth_base_url}" != https://?* ]]; then
    print -u2 "BLEAT_TELEMETRY_AUTH_BASE_URL must be an HTTPS URL"
    exit 1
fi
if [[ "${bleat_telemetry_otlp_endpoint}" != https://?* ]]; then
    print -u2 "BLEAT_TELEMETRY_OTLP_ENDPOINT must be an HTTPS URL"
    exit 1
fi

typeset -a bleat_signing_arguments
if [[ -n "${BLEAT_DEVELOPMENT_TEAM:-}" ]]; then
    bleat_signing_arguments=(
        "DEVELOPMENT_TEAM=${BLEAT_DEVELOPMENT_TEAM}"
        "CODE_SIGN_STYLE=Automatic"
    )
    if [[ "${BLEAT_ALLOW_PROVISIONING_UPDATES:-0}" == "1" ]]; then
        bleat_signing_arguments+=("-allowProvisioningUpdates")
    fi
else
    bleat_signing_arguments=(
        "CODE_SIGNING_ALLOWED=NO"
        "CODE_SIGNING_REQUIRED=NO"
    )
fi

xcodebuild \
    -project "${bleat_repository_root}/Bleat.xcodeproj" \
    -scheme Bleat \
    ${BUILD_VERBOSE_FLAG} \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "${bleat_archive_path}" \
    BUILD_WITHOUT_PAID_DEVELOPER="${BUILD_WITHOUT_PAID_DEVELOPER:-NO}" \
    BLEAT_APP_ATTEST_MODE="${BLEAT_APP_ATTEST_MODE:-enabled}" \
    BLEAT_CLOUDKIT_MODE="${BLEAT_CLOUDKIT_MODE:-enabled}" \
    BLEAT_TELEMETRY_AUTH_BASE_URL="${bleat_telemetry_auth_base_url}" \
    BLEAT_TELEMETRY_OTLP_ENDPOINT="${bleat_telemetry_otlp_endpoint}" \
    "${bleat_signing_arguments[@]}" \
    archive

test -f "${bleat_archive_path}/Info.plist"
readonly bleat_app_path="${bleat_archive_path}/Products/Applications/Bleat.app"
readonly bleat_app_info="${bleat_app_path}/Info.plist"
readonly bleat_privacy_manifest="${bleat_app_path}/PrivacyInfo.xcprivacy"

test -f "${bleat_app_info}"
test -f "${bleat_privacy_manifest}"
plutil -lint "${bleat_app_info}" "${bleat_privacy_manifest}"

if [[ "$(plutil -extract CFBundleShortVersionString raw "${bleat_app_info}")" != "${bleat_expected_version}" \
    || "$(plutil -extract CFBundleVersion raw "${bleat_app_info}")" != "${bleat_expected_build}" ]]; then
    print -u2 "Archive version does not match Bleat ${bleat_expected_version} (${bleat_expected_build})"
    exit 1
fi

if [[ "$(plutil -extract BleatTelemetryAuthenticationBaseURL raw "${bleat_app_info}")" != "${bleat_telemetry_auth_base_url}" \
    || "$(plutil -extract BleatTelemetryOTLPEndpoint raw "${bleat_app_info}")" != "${bleat_telemetry_otlp_endpoint}" ]]; then
    print -u2 "Archive telemetry configuration does not match the supplied environment"
    exit 1
fi

python3 "${bleat_script_dir}/inspect-release-archive.py" \
    --archive "${bleat_archive_path}" \
    --package-resolution \
    "${bleat_repository_root}/Bleat.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
