#!/bin/zsh

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
source "${bleat_script_dir}/live-profile.sh"
readonly bleat_temp="$(mktemp -d /tmp/bleat-live-profile-tests.XXXXXX)"
trap 'rm -rf "${bleat_temp}"' EXIT

bleat_select_live_profile minimum
[[ "${BLEAT_EXPECTED_SERVER_VERSION}" == "2.26.0" ]]
[[ "${BLEAT_ABS_IMAGE}" == *":2.26.0@sha256:"* ]]
bleat_select_live_profile current-stable
[[ "${BLEAT_EXPECTED_SERVER_VERSION}" == "2.37.0" ]]
[[ "${BLEAT_ABS_IMAGE}" == *":2.37.0@sha256:"* ]]
if bleat_select_live_profile unknown >/dev/null 2>&1; then
    print -u2 "Unknown profile was accepted"
    exit 1
fi

readonly bleat_valid="${bleat_script_dir:h}/TestSupport/ServerHarness/profiles/current-stable.json"
readonly bleat_fixtures="${bleat_script_dir:h}/Tests/BleatCoreTests/Fixtures"
bleat_status_matches_profile 2.26.0 \
    <"${bleat_fixtures}/2.26.0/captured-2.26.0-status.json"
bleat_status_matches_profile 2.37.0 \
    <"${bleat_fixtures}/2.37.0/captured-2.37.0-status.json"
if bleat_status_matches_profile 2.37.0 \
    <"${bleat_fixtures}/2.26.0/captured-2.26.0-status.json"; then
    print -u2 "A mismatched server version was accepted"
    exit 1
fi
jq '.image = "ghcr.io/advplyr/audiobookshelf:latest"' "${bleat_valid}" \
    >"${bleat_temp}/floating.json"
jq '.serverVersion = "2.36.0"' "${bleat_valid}" \
    >"${bleat_temp}/mismatch.json"
jq '.seedVersion = "2.36.0"' "${bleat_valid}" \
    >"${bleat_temp}/seed-mismatch.json"
jq 'del(.seedVersion)' "${bleat_valid}" \
    >"${bleat_temp}/missing.json"
for bad in "${bleat_temp}"/*.json; do
    if bleat_validate_live_profile_file "${bad}" current-stable >/dev/null 2>&1; then
        print -u2 "Invalid profile was accepted: ${bad:t}"
        exit 1
    fi
done

readonly bleat_compose="${bleat_script_dir:h}/TestSupport/ServerHarness/compose.yaml"
docker compose --file "${bleat_compose}" config --format json \
    | bleat_compose_images_match_profile "${BLEAT_ABS_IMAGE}"
cat >"${bleat_temp}/wrong-image.yaml" <<'EOF'
services:
  audiobookshelf-root:
    image: ghcr.io/advplyr/audiobookshelf:2.36.0
EOF
docker compose --file "${bleat_compose}" --file "${bleat_temp}/wrong-image.yaml" \
    config --format json >"${bleat_temp}/wrong-image-resolved.json"
if bleat_compose_images_match_profile "${BLEAT_ABS_IMAGE}" \
    <"${bleat_temp}/wrong-image-resolved.json"; then
    print -u2 "An overridden Audiobookshelf image was accepted"
    exit 1
fi
print 'Audiobookshelf live profiles validated'
