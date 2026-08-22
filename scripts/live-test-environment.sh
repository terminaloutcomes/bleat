#!/bin/zsh

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
readonly bleat_repository_root="${bleat_script_dir:h}"
readonly bleat_compose_file="${bleat_repository_root}/TestSupport/ServerHarness/compose.yaml"
readonly bleat_project_name="${BLEAT_COMPOSE_PROJECT_NAME:-bleat-live-tests}"
readonly bleat_root_port="${BLEAT_ABS_ROOT_PORT:-13378}"
readonly bleat_prefix_port="${BLEAT_ABS_PREFIX_PORT:-13379}"
readonly bleat_https_root_port="${BLEAT_HTTPS_ROOT_PORT:-13478}"
readonly bleat_https_prefix_port="${BLEAT_HTTPS_PREFIX_PORT:-13479}"
readonly bleat_root_url="http://127.0.0.1:${bleat_root_port}"
readonly bleat_prefix_url="http://127.0.0.1:${bleat_prefix_port}/audiobookshelf"
readonly bleat_https_root_url="https://localhost:${bleat_https_root_port}"
readonly bleat_https_prefix_url="https://localhost:${bleat_https_prefix_port}/audiobookshelf"
readonly bleat_test_username="${BLEAT_TEST_USERNAME:-}"
readonly bleat_test_password="${BLEAT_TEST_PASSWORD:-}"

bleat_compose() {
    docker compose \
        --project-name "${bleat_project_name}" \
        --file "${bleat_compose_file}" \
        "$@"
}

bleat_status() {
    /usr/bin/curl \
        --fail \
        --silent \
        --show-error \
        --max-time 2 \
        "${1}/status"
}

bleat_export_ca() {
    local destination="$1"
    bleat_compose cp \
        caddy:/data/caddy/pki/authorities/local/root.crt \
        "${destination}"
}

bleat_https_status() {
    local base_url="$1"
    local certificate="$2"
    /usr/bin/curl \
        --fail \
        --silent \
        --show-error \
        --max-time 2 \
        --cacert "${certificate}" \
        "${base_url}/status"
}

bleat_wait_https() {
    local certificate
    local attempt
    certificate="$(mktemp /tmp/bleat-caddy-root.XXXXXX)"
    bleat_export_ca "${certificate}"
    for attempt in {1..30}; do
        if bleat_https_status \
            "${bleat_https_root_url}" \
            "${certificate}" \
            >/dev/null 2>&1 \
            && bleat_https_status \
                "${bleat_https_prefix_url}" \
                "${certificate}" \
                >/dev/null 2>&1; then
            rm -f "${certificate}"
            return 0
        fi
        sleep 1
    done
    rm -f "${certificate}"
    print -u2 "HTTPS proxy services did not become ready"
    return 1
}

bleat_wait() {
    local attempt
    for attempt in {1..60}; do
        if bleat_status "${bleat_root_url}" >/dev/null 2>&1 \
            && bleat_status "${bleat_prefix_url}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    print -u2 "Audiobookshelf services did not become ready"
    bleat_compose ps
    bleat_compose logs --no-color --tail 100
    return 1
}

bleat_initialize() {
    local base_url="$1"
    local status_payload
    status_payload="$(bleat_status "${base_url}")"

    if [[ "${status_payload}" == *'"isInit":true'* ]]; then
        return 0
    fi
    if [[ "${status_payload}" != *'"isInit":false'* ]]; then
        print -u2 "Unexpected Audiobookshelf status payload from ${base_url}"
        return 1
    fi

    /usr/bin/curl \
        --fail \
        --silent \
        --show-error \
        --max-time 10 \
        --request POST \
        --header 'Content-Type: application/json' \
        --data "{\"newRoot\":{\"username\":\"${bleat_test_username}\",\"password\":\"${bleat_test_password}\"}}" \
        "${base_url}/init" \
        >/dev/null

    if [[ "$(bleat_status "${base_url}")" != *'"isInit":true'* ]]; then
        print -u2 "Audiobookshelf initialization did not persist for ${base_url}"
        return 1
    fi
}

bleat_login_access_token() {
    local base_url="$1"
    local login_payload
    login_payload="$(
        /usr/bin/curl \
            --fail \
            --silent \
            --show-error \
            --max-time 10 \
            --request POST \
            --header 'Content-Type: application/json' \
            --header 'x-return-tokens: true' \
            --data "{\"username\":\"${bleat_test_username}\",\"password\":\"${bleat_test_password}\"}" \
            "${base_url}/login"
    )"

    print -r -- "${login_payload}" | jq --exit-status --raw-output \
        '.user.accessToken | select(type == "string" and length > 0)'
}

bleat_seed_navigation_metadata() {
    local base_url="$1"
    local access_token="$2"
    local items_payload="$3"
    local -a item_ids
    local fixture_count

    item_ids=(
        "${(@f)$(
            print -r -- "${items_payload}" \
                | jq --exit-status --raw-output '.results[]?.id'
        )}"
    )
    if (( ${#item_ids} != 3 )); then
        print -u2 "Expected exactly 3 fixture item IDs from ${base_url}"
        return 1
    fi

    local -a metadata_payloads=(
        '{"metadata":{"authors":[{"name":"Fixture Author One"},{"name":"Fixture Author Two"}],"series":[{"name":"Fixture Series","sequence":"1"},{"name":"Fixture Companion","sequence":"1"}]}}'
        '{"metadata":{"authors":[{"name":"Fixture Author One"}],"series":[{"name":"Fixture Series","sequence":"2"}]}}'
        '{"metadata":{"authors":[{"name":"Fixture Author Three"}],"series":[{"name":"Fixture Companion","sequence":"2"}]}}'
    )
    local index
    for index in {1..3}; do
        /usr/bin/curl \
            --fail \
            --silent \
            --show-error \
            --max-time 10 \
            --request PATCH \
            --header "Authorization: Bearer ${access_token}" \
            --header 'Content-Type: application/json' \
            --data "${metadata_payloads[index]}" \
            "${base_url}/api/items/${item_ids[index]}/media" \
            >/dev/null
    done

    fixture_count=0
    local item_metadata
    for item_id in "${item_ids[@]}"; do
        item_metadata="$(
            /usr/bin/curl \
                --fail \
                --silent \
                --show-error \
                --max-time 10 \
                --header "Authorization: Bearer ${access_token}" \
                "${base_url}/api/items/${item_id}?expanded=1"
        )"
        if [[ "$(
            print -r -- "${item_metadata}" \
                | jq --raw-output \
                    'if (.media.metadata.authors | length) >= 2
                        and (.media.metadata.series | length) >= 2
                    then "yes" else "no" end'
        )" == "yes" ]]; then
            (( fixture_count += 1 ))
        fi
    done
    if [[ "${fixture_count}" != "1" ]]; then
        print -u2 "Navigation metadata was not seeded for ${base_url}"
        return 1
    fi
}

bleat_seed_library() {
    local base_url="$1"
    local expected_count="${2:-${BLEAT_SEED_ITEM_COUNT:-3}}"
    local access_token
    local libraries_payload
    local library_id
    local items_payload
    local item_count
    local attempt

    access_token="$(bleat_login_access_token "${base_url}")"
    libraries_payload="$(
        /usr/bin/curl \
            --fail \
            --silent \
            --show-error \
            --max-time 10 \
            --header "Authorization: Bearer ${access_token}" \
            "${base_url}/api/libraries"
    )"
    library_id="$(
        print -r -- "${libraries_payload}" \
            | jq --raw-output \
                '.libraries[]? | select(.name == "Bleat Live Fixtures") | .id' \
            | head -n 1
    )"

    if [[ -z "${library_id}" ]]; then
        library_id="$(
            /usr/bin/curl \
                --fail \
                --silent \
                --show-error \
                --max-time 10 \
                --request POST \
                --header "Authorization: Bearer ${access_token}" \
                --header 'Content-Type: application/json' \
                --data '{"name":"Bleat Live Fixtures","folders":[{"fullPath":"/audiobooks"}],"mediaType":"book","provider":"google"}' \
                "${base_url}/api/libraries" \
                | jq --exit-status --raw-output \
                    '.id | select(type == "string" and length > 0)'
        )"
    fi

    /usr/bin/curl \
        --fail \
        --silent \
        --show-error \
        --max-time 10 \
        --request POST \
        --header "Authorization: Bearer ${access_token}" \
        "${base_url}/api/libraries/${library_id}/scan" \
        >/dev/null

    for attempt in {1..60}; do
        items_payload="$(
            /usr/bin/curl \
                --fail \
                --silent \
                --show-error \
                --max-time 10 \
                --header "Authorization: Bearer ${access_token}" \
                "${base_url}/api/libraries/${library_id}/items"
        )"
        item_count="$(
            print -r -- "${items_payload}" \
                | jq --exit-status --raw-output '.total'
        )"
        if [[ "${item_count}" == "${expected_count}" ]]; then
            if [[ "${expected_count}" == "3" ]]; then
                bleat_seed_navigation_metadata \
                    "${base_url}" \
                    "${access_token}" \
                    "${items_payload}"
            fi
            return 0
        fi
        sleep 1
    done

    print -u2 \
        "Expected ${expected_count} seeded media items from ${base_url}, received ${item_count}"
    return 1
}

# Seeds the large synthetic library used by the 10,000-book performance
# baseline (issue #46). The library is only created when
# BLEAT_LARGE_LIBRARY_COUNT is set; the existing 3-item "Bleat Live Fixtures"
# library is untouched. The scan poll timeout scales with the count because
# scanning thousands of folders takes minutes.
bleat_seed_large_library() {
    local base_url="$1"
    local expected_count="${BLEAT_LARGE_LIBRARY_COUNT:?BLEAT_LARGE_LIBRARY_COUNT is required}"
    local access_token
    local library_id
    local items_payload
    local item_count
    local attempt
    local max_attempts=$(( expected_count / 20 + 120 ))

    access_token="$(bleat_login_access_token "${base_url}")"
    library_id="$(
        /usr/bin/curl \
            --fail \
            --silent \
            --show-error \
            --max-time 10 \
            --header "Authorization: Bearer ${access_token}" \
            "${base_url}/api/libraries" \
            | jq --raw-output \
                '.libraries[]? | select(.name == "Bleat Large Fixtures") | .id' \
            | head -n 1
    )"

    if [[ -z "${library_id}" ]]; then
        library_id="$(
            /usr/bin/curl \
                --fail \
                --silent \
                --show-error \
                --max-time 10 \
                --request POST \
                --header "Authorization: Bearer ${access_token}" \
                --header 'Content-Type: application/json' \
                --data '{"name":"Bleat Large Fixtures","folders":[{"fullPath":"/audiobooks-large"}],"mediaType":"book","provider":"google"}' \
                "${base_url}/api/libraries" \
                | jq --exit-status --raw-output \
                    '.id | select(type == "string" and length > 0)'
        )"
    fi

    /usr/bin/curl \
        --fail \
        --silent \
        --show-error \
        --max-time 10 \
        --request POST \
        --header "Authorization: Bearer ${access_token}" \
        "${base_url}/api/libraries/${library_id}/scan" \
        >/dev/null

    for attempt in {1..${max_attempts}}; do
        item_count="$(
            /usr/bin/curl \
                --fail \
                --silent \
                --show-error \
                --max-time 10 \
                --header "Authorization: Bearer ${access_token}" \
                "${base_url}/api/libraries/${library_id}/items?limit=1&page=0" \
                | jq --raw-output '.total // "0"'
        )"
        if [[ "${item_count}" == "${expected_count}" ]]; then
            return 0
        fi
        sleep 1
    done

    print -u2 \
        "Expected ${expected_count} large-library items from ${base_url}, received ${item_count}"
    return 1
}

bleat_seed() {
    if [[ -z "${bleat_test_username}" || -z "${bleat_test_password}" ]]; then
        print -u2 \
            "BLEAT_TEST_USERNAME and BLEAT_TEST_PASSWORD are required to seed"
        return 64
    fi
    bleat_initialize "${bleat_root_url}"
    bleat_initialize "${bleat_prefix_url}"
    bleat_seed_library "${bleat_root_url}"
    bleat_seed_library "${bleat_prefix_url}"
    if [[ -n "${BLEAT_LARGE_LIBRARY_COUNT:-}" ]]; then
        bleat_seed_large_library "${bleat_root_url}"
        bleat_seed_large_library "${bleat_prefix_url}"
    fi
}

bleat_redact() {
    sed -E \
        -e 's/(Authorization: Bearer )[A-Za-z0-9._-]+/\1[REDACTED]/g' \
        -e 's/("(accessToken|refreshToken|password)"[[:space:]]*:[[:space:]]*")[^"]*"/\1[REDACTED]"/g'
}

bleat_artifacts() {
    local artifact_dir="${1:-${bleat_repository_root}/TestSupport/ServerHarness/artifacts}"
    mkdir -p "${artifact_dir}"
    bleat_compose ps \
        | bleat_redact \
        >"${artifact_dir}/compose-ps.txt"
    bleat_compose logs --no-color 2>&1 \
        | bleat_redact \
        >"${artifact_dir}/compose.log"
}

bleat_down() {
    bleat_compose down --volumes --remove-orphans
}

case "${1:-}" in
    up)
        bleat_compose up --detach --wait
        bleat_wait
        bleat_wait_https
        ;;
    wait)
        bleat_wait
        ;;
    seed)
        bleat_wait
        bleat_seed
        ;;
    seed-large)
        bleat_wait
        if [[ -z "${BLEAT_LARGE_LIBRARY_COUNT:-}" ]]; then
            print -u2 "BLEAT_LARGE_LIBRARY_COUNT is required for seed-large"
            exit 64
        fi
        bleat_seed_large_library "${bleat_root_url}"
        bleat_seed_large_library "${bleat_prefix_url}"
        ;;
    reset)
        bleat_down
        bleat_compose up --detach --wait
        bleat_wait
        bleat_seed
        bleat_wait_https
        ;;
    status)
        bleat_status "${bleat_root_url}"
        print
        bleat_status "${bleat_prefix_url}"
        print
        ;;
    artifacts)
        bleat_artifacts "${2:-}"
        ;;
    ca)
        if [[ -z "${2:-}" ]]; then
            print -u2 "Usage: $0 ca <destination>"
            exit 64
        fi
        bleat_export_ca "$2"
        ;;
    stop)
        bleat_compose stop
        ;;
    down)
        bleat_down
        ;;
    *)
        print -u2 "Usage: $0 {up|wait|seed|seed-large|reset|status|artifacts [directory]|ca <destination>|stop|down}"
        exit 64
        ;;
esac
