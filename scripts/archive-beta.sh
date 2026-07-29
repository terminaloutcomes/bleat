#!/bin/zsh

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
readonly bleat_repository_root="${bleat_script_dir:h}"
readonly bleat_archive_path="${BLEAT_ARCHIVE_PATH:-${bleat_repository_root}/.build/Bleat.xcarchive}"

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
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "${bleat_archive_path}" \
    "${bleat_signing_arguments[@]}" \
    archive

test -f "${bleat_archive_path}/Info.plist"
readonly bleat_app_path="${bleat_archive_path}/Products/Applications/Bleat.app"
readonly bleat_app_info="${bleat_app_path}/Info.plist"
readonly bleat_privacy_manifest="${bleat_app_path}/PrivacyInfo.xcprivacy"

test -f "${bleat_app_info}"
test -f "${bleat_privacy_manifest}"
plutil -lint "${bleat_app_info}" "${bleat_privacy_manifest}"

if [[ "$(plutil -extract CFBundleShortVersionString raw "${bleat_app_info}")" != "0.1.0" \
    || "$(plutil -extract CFBundleVersion raw "${bleat_app_info}")" != "1" ]]; then
    print -u2 "Archive version does not match Bleat 0.1.0 (1)"
    exit 1
fi
