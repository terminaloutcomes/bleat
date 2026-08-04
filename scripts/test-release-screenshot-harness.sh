#!/bin/zsh

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
readonly bleat_repository_root="${bleat_script_dir:h}"
readonly bleat_harness="${bleat_script_dir}/capture-release-screenshots.sh"
readonly bleat_fixture="${bleat_repository_root}/TestSupport/ReleaseScreenshots/fixtures.json"
readonly bleat_temporary_directory="$(mktemp -d /tmp/bleat-release-screenshot-tests.XXXXXX)"

bleat_cleanup() {
    rm -rf "${bleat_temporary_directory}"
}
trap bleat_cleanup EXIT

"${bleat_harness}" --validate-fixtures

bleat_expect_invalid_fixture() {
    local fixture="$1"
    local message="$2"
    if BLEAT_SCREENSHOT_FIXTURE="${fixture}" \
        "${bleat_harness}" --validate-fixtures >/dev/null 2>&1; then
        print -u2 -- "The harness accepted ${message}"
        exit 1
    fi
}

jq '.books[0].duration = 1' "${bleat_fixture}" \
    >"${bleat_temporary_directory}/invalid-duration.json"
bleat_expect_invalid_fixture \
    "${bleat_temporary_directory}/invalid-duration.json" "an invalid hero duration"

jq '.books[0].progress.currentTime = 46801' "${bleat_fixture}" \
    >"${bleat_temporary_directory}/invalid-progress.json"
bleat_expect_invalid_fixture \
    "${bleat_temporary_directory}/invalid-progress.json" "out-of-bounds progress"

jq '.books[0].chapters[4].start = 17999' "${bleat_fixture}" \
    >"${bleat_temporary_directory}/invalid-chapters.json"
bleat_expect_invalid_fixture \
    "${bleat_temporary_directory}/invalid-chapters.json" "invalid chapter boundaries"

jq '.books[0].cover = "covers/missing.png"' "${bleat_fixture}" \
    >"${bleat_temporary_directory}/missing-cover.json"
bleat_expect_invalid_fixture \
    "${bleat_temporary_directory}/missing-cover.json" "a missing cover"

jq '.screenshots[1].file = .screenshots[0].file' "${bleat_fixture}" \
    >"${bleat_temporary_directory}/duplicate-screenshot.json"
bleat_expect_invalid_fixture \
    "${bleat_temporary_directory}/duplicate-screenshot.json" "duplicate screenshot filenames"

readonly bleat_attachment_directory="${bleat_temporary_directory}/attachments"
readonly bleat_attachment_manifest="${bleat_temporary_directory}/attachments.json"
mkdir -p "${bleat_attachment_directory}"
jq --null-input --argjson screenshots "$(jq '[.screenshots[].file]' "${bleat_fixture}")" '
    [{attachments: ($screenshots | map({
        suggestedHumanReadableName: sub("\\.png$"; "_0_fixture.png"),
        exportedFileName: (. | sub("\\.png$"; "-attachment.png"))
    }))}]
' >"${bleat_attachment_manifest}"

while IFS= read -r filename; do
    sips -z 2868 1320 \
        "${bleat_repository_root}/TestSupport/ReleaseScreenshots/covers/thirteen-hours-of-goat-sounds.png" \
        --out "${bleat_attachment_directory}/${filename%.png}-attachment.png" >/dev/null
done < <(jq --raw-output '.screenshots[].file' "${bleat_fixture}")

BLEAT_SCREENSHOT_ATTACHMENT_MANIFEST="${bleat_attachment_manifest}" \
BLEAT_SCREENSHOT_ATTACHMENT_DIRECTORY="${bleat_attachment_directory}" \
BLEAT_SCREENSHOT_EXPECTED_DIMENSIONS=1320x2868 \
"${bleat_harness}" --validate-artifacts

jq '.[0].attachments |= .[1:]' "${bleat_attachment_manifest}" \
    >"${bleat_temporary_directory}/missing-attachment.json"
if BLEAT_SCREENSHOT_ATTACHMENT_MANIFEST="${bleat_temporary_directory}/missing-attachment.json" \
    BLEAT_SCREENSHOT_ATTACHMENT_DIRECTORY="${bleat_attachment_directory}" \
    BLEAT_SCREENSHOT_EXPECTED_DIMENSIONS=1320x2868 \
    "${bleat_harness}" --validate-artifacts >/dev/null 2>&1; then
    print -u2 "The artifact validator accepted a missing capture"
    exit 1
fi

jq '.[0].attachments[1].suggestedHumanReadableName = .[0].attachments[0].suggestedHumanReadableName' \
    "${bleat_attachment_manifest}" >"${bleat_temporary_directory}/duplicate-attachment.json"
if BLEAT_SCREENSHOT_ATTACHMENT_MANIFEST="${bleat_temporary_directory}/duplicate-attachment.json" \
    BLEAT_SCREENSHOT_ATTACHMENT_DIRECTORY="${bleat_attachment_directory}" \
    BLEAT_SCREENSHOT_EXPECTED_DIMENSIONS=1320x2868 \
    "${bleat_harness}" --validate-artifacts >/dev/null 2>&1; then
    print -u2 "The artifact validator accepted a duplicate capture"
    exit 1
fi

sips -z 2752 2064 \
    "${bleat_attachment_directory}/01-home-attachment.png" --out \
    "${bleat_temporary_directory}/invalid-dimensions.png" >/dev/null
mv "${bleat_temporary_directory}/invalid-dimensions.png" \
    "${bleat_attachment_directory}/01-home-attachment.png"
if BLEAT_SCREENSHOT_ATTACHMENT_MANIFEST="${bleat_attachment_manifest}" \
    BLEAT_SCREENSHOT_ATTACHMENT_DIRECTORY="${bleat_attachment_directory}" \
    BLEAT_SCREENSHOT_EXPECTED_DIMENSIONS=1320x2868 \
    "${bleat_harness}" --validate-artifacts >/dev/null 2>&1; then
    print -u2 "The artifact validator accepted invalid screenshot dimensions"
    exit 1
fi

jq --null-input '{app: {version: "1.0", build: "1"}, screenshots: []}' \
    >"${bleat_temporary_directory}/public-manifest.json"
BLEAT_SCREENSHOT_MANIFEST="${bleat_temporary_directory}/public-manifest.json" \
    "${bleat_harness}" --validate-manifest
jq '. + {accessToken: "not-for-export"}' \
    "${bleat_temporary_directory}/public-manifest.json" \
    >"${bleat_temporary_directory}/sensitive-manifest.json"
if BLEAT_SCREENSHOT_MANIFEST="${bleat_temporary_directory}/sensitive-manifest.json" \
    "${bleat_harness}" --validate-manifest >/dev/null 2>&1; then
    print -u2 "The manifest validator accepted an access token"
    exit 1
fi
