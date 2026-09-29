#!/bin/zsh

# Source this file from a disposable Audiobookshelf runner.
bleat_profile_script_dir="${${(%):-%x}:A:h}"

bleat_validate_live_profile_file() {
    local manifest="$1"
    local profile="$2"
    jq --exit-status --arg profile "${profile}" '
        .id == $profile
        and (.serverVersion | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
        and (.seedVersion | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
        and .seedVersion == .serverVersion
        and (.image | type == "string"
            and test("^ghcr\\.io/advplyr/audiobookshelf:[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[0-9a-f]{64}$"))
        and (.image | split(":")[1] | split("@") | .[0]) == .serverVersion
    ' "${manifest}" >/dev/null
}

bleat_status_matches_profile() {
    local expected_version="$1"
    jq --exit-status --arg expected "${expected_version}" \
        '.serverVersion == $expected' >/dev/null
}

bleat_compose_images_match_profile() {
    local expected_image="$1"
    jq --exit-status --arg expected "${expected_image}" '
        .services["audiobookshelf-root"].image == $expected
        and .services["audiobookshelf-prefix"].image == $expected
    ' >/dev/null
}

bleat_select_live_profile() {
    local profile="${1:-current-stable}"
    case "${profile}" in
        minimum|current-stable) ;;
        *) print -u2 "Unknown Audiobookshelf live profile: ${profile}"; return 64 ;;
    esac
    local manifest="${bleat_profile_script_dir:h}/TestSupport/ServerHarness/profiles/${profile}.json"
    if ! bleat_validate_live_profile_file "${manifest}" "${profile}"; then
        print -u2 "Invalid Audiobookshelf live profile: ${profile}"
        return 64
    fi
    export BLEAT_LIVE_PROFILE_ID="${profile}"
    export BLEAT_EXPECTED_SERVER_VERSION="$(jq -r '.serverVersion' "${manifest}")"
    export BLEAT_SEED_VERSION="$(jq -r '.seedVersion' "${manifest}")"
    export BLEAT_ABS_IMAGE="$(jq -r '.image' "${manifest}")"
    export BLEAT_LIVE_EXPECTED_VERSION="${BLEAT_EXPECTED_SERVER_VERSION}"
}
