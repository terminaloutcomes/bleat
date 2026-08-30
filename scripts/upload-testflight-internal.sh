#!/bin/zsh

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
readonly bleat_repository_root="${bleat_script_dir:h}"
readonly bleat_project_configuration="${bleat_repository_root}/project.yml"

readonly bleat_development_team="${BLEAT_DEVELOPMENT_TEAM:?Set BLEAT_DEVELOPMENT_TEAM to the Apple team ID}"
readonly bleat_bundle_id="${BLEAT_BUNDLE_ID:?Set BLEAT_BUNDLE_ID to the App Store Connect bundle identifier}"
readonly bleat_build_number="${BLEAT_BUILD_NUMBER:-$(date -u '+%Y%m%d.%H%M.%S')}"
readonly bleat_version="$(
    awk '$1 == "MARKETING_VERSION:" {
        gsub(/"/, "", $2)
        print $2
        exit
    }' "${bleat_project_configuration}"
)"

if [[ -z "${bleat_version}" ]]; then
    print -u2 "Could not read MARKETING_VERSION from project.yml"
    exit 1
fi
if [[ ! "${bleat_build_number}" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
    print -u2 "BLEAT_BUILD_NUMBER must contain one to three dot-separated integers"
    exit 64
fi

readonly bleat_relative_output_directory=".build/testflight-internal/${bleat_version}-${bleat_build_number}"
readonly bleat_output_directory="${bleat_repository_root}/${bleat_relative_output_directory}"
readonly bleat_archive_path="${bleat_output_directory}/Bleat.xcarchive"
readonly bleat_export_options_path="${bleat_output_directory}/ExportOptions.plist"
readonly bleat_local_export_options_path="${bleat_output_directory}/LocalExportOptions.plist"
readonly bleat_local_export_log_path="${bleat_output_directory}/local-export.log"
readonly bleat_upload_export_path="${bleat_output_directory}/upload"
readonly bleat_delivery_log_path="${bleat_output_directory}/delivery.log"
readonly bleat_report_plist_path="${bleat_output_directory}/report.plist"
readonly bleat_report_path="${bleat_output_directory}/report.json"

if [[ -e "${bleat_output_directory}" ]]; then
    print -u2 "TestFlight output already exists for build ${bleat_build_number}"
    exit 1
fi
mkdir -p "${bleat_output_directory}"

if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Apple Distribution:'; then
    readonly bleat_distribution_identity_state="present"
else
    readonly bleat_distribution_identity_state="automatic-signing-required"
    print "No usable Apple Distribution identity is currently visible; Xcode will attempt to create or download one."
fi

"${bleat_script_dir}/create-testflight-export-options.sh" \
    "${bleat_export_options_path}" \
    "${bleat_development_team}" \
    "${bleat_bundle_id}" \
    upload
"${bleat_script_dir}/create-testflight-export-options.sh" \
    "${bleat_local_export_options_path}" \
    "${bleat_development_team}" \
    "${bleat_bundle_id}" \
    export

BLEAT_ALLOW_PROVISIONING_UPDATES=1 \
BLEAT_ARCHIVE_PATH="${bleat_archive_path}" \
BLEAT_BUILD_NUMBER="${bleat_build_number}" \
BUILD_WITHOUT_PAID_DEVELOPER=NO \
BLEAT_APP_ATTEST_MODE=enabled \
BLEAT_CLOUDKIT_MODE=enabled \
"${bleat_script_dir}/archive-beta.sh"

readonly bleat_app_info="${bleat_archive_path}/Products/Applications/Bleat.app/Info.plist"
if [[ "$(plutil -extract CFBundleIdentifier raw "${bleat_app_info}")" != "${bleat_bundle_id}" ]]; then
    print -u2 "Archive bundle identifier does not match BLEAT_BUNDLE_ID"
    exit 1
fi

print "Exporting the distribution-signed IPA for inspection..."
xcodebuild \
    -quiet \
    -exportArchive \
    -archivePath "${bleat_archive_path}" \
    -exportPath "${bleat_output_directory}/export" \
    -exportOptionsPlist "${bleat_local_export_options_path}" \
    -allowProvisioningUpdates \
    2>&1 \
    | sed \
        -e "s/${bleat_development_team}/<redacted-team>/g" \
        -e "s#${bleat_repository_root}#.#g" \
    | tee "${bleat_local_export_log_path}"

typeset -a bleat_exported_ipas
bleat_exported_ipas=("${bleat_output_directory}/export"/*.ipa(N))
if [[ "${#bleat_exported_ipas[@]}" -ne 1 ]]; then
    print -u2 "App Store export did not produce exactly one IPA"
    exit 1
fi
readonly bleat_exported_ipa="${bleat_exported_ipas[1]}"
python3 "${bleat_script_dir}/inspect-testflight-ipa.py" \
    --ipa "${bleat_exported_ipa}" \
    --team "${bleat_development_team}" \
    --bundle-id "${bleat_bundle_id}" \
    --version "${bleat_version}" \
    --build "${bleat_build_number}"
readonly bleat_ipa_sha256="$(shasum -a 256 "${bleat_exported_ipa}" | awk '{print $1}')"
print "${bleat_ipa_sha256}  export/${bleat_exported_ipa:t}" \
    > "${bleat_output_directory}/SHA256SUMS"

print "Uploading Bleat ${bleat_version} (${bleat_build_number}) as TestFlight Internal Only..."
xcodebuild \
    -quiet \
    -exportArchive \
    -archivePath "${bleat_archive_path}" \
    -exportPath "${bleat_upload_export_path}" \
    -exportOptionsPlist "${bleat_export_options_path}" \
    -allowProvisioningUpdates \
    2>&1 \
    | sed \
        -e "s/${bleat_development_team}/<redacted-team>/g" \
        -e "s#${bleat_repository_root}#.#g" \
    | tee "${bleat_delivery_log_path}"
if ! grep -Fq "Upload succeeded." "${bleat_delivery_log_path}"; then
    print -u2 "Xcode finished without confirming that the upload succeeded"
    exit 1
fi

readonly bleat_commit="$(git -C "${bleat_repository_root}" rev-parse HEAD)"
if [[ -n "$(git -C "${bleat_repository_root}" status --short)" ]]; then
    readonly bleat_worktree_state="dirty"
else
    readonly bleat_worktree_state="clean"
fi
readonly bleat_uploaded_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

plutil -create xml1 "${bleat_report_plist_path}"
plutil -insert schemaVersion -integer 1 "${bleat_report_plist_path}"
plutil -insert status -string uploaded "${bleat_report_plist_path}"
plutil -insert processingStatus -string processing "${bleat_report_plist_path}"
plutil -insert distribution -string testflight-internal-only "${bleat_report_plist_path}"
plutil -insert version -string "${bleat_version}" "${bleat_report_plist_path}"
plutil -insert build -string "${bleat_build_number}" "${bleat_report_plist_path}"
plutil -insert bundleIdentifier -string "${bleat_bundle_id}" "${bleat_report_plist_path}"
plutil -insert gitCommit -string "${bleat_commit}" "${bleat_report_plist_path}"
plutil -insert worktreeState -string "${bleat_worktree_state}" "${bleat_report_plist_path}"
plutil -insert distributionIdentityPreflight -string "${bleat_distribution_identity_state}" "${bleat_report_plist_path}"
plutil -insert ipaSha256 -string "${bleat_ipa_sha256}" "${bleat_report_plist_path}"
plutil -insert uploadedAt -string "${bleat_uploaded_at}" "${bleat_report_plist_path}"
plutil -convert json -o "${bleat_report_path}" "${bleat_report_plist_path}"
rm "${bleat_report_plist_path}"

print "TestFlight Internal Only upload completed for Bleat ${bleat_version} (${bleat_build_number})."
print "Local evidence: ${bleat_relative_output_directory}"
print "The build is uploaded but is not installable until App Store Connect finishes processing it."
