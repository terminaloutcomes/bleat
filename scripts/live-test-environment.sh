#!/bin/zsh

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
readonly bleat_repository_root="${bleat_script_dir:h}"
readonly bleat_compose_file="${bleat_repository_root}/TestSupport/ServerHarness/compose.yaml"
readonly bleat_project_name="${BLEAT_COMPOSE_PROJECT_NAME:-bleat-live-tests}"
readonly bleat_root_port="${BLEAT_ABS_ROOT_PORT:-13378}"
readonly bleat_prefix_port="${BLEAT_ABS_PREFIX_PORT:-13379}"
readonly bleat_root_url="http://127.0.0.1:${bleat_root_port}"
readonly bleat_prefix_url="http://127.0.0.1:${bleat_prefix_port}/audiobookshelf"
readonly bleat_test_username="${BLEAT_TEST_USERNAME:-bleat-root}"
readonly bleat_test_password="${BLEAT_TEST_PASSWORD:-bleat-test-only}"

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

bleat_seed() {
    bleat_initialize "${bleat_root_url}"
    bleat_initialize "${bleat_prefix_url}"
}

bleat_artifacts() {
    local artifact_dir="${1:-${bleat_repository_root}/TestSupport/ServerHarness/artifacts}"
    mkdir -p "${artifact_dir}"
    bleat_compose ps >"${artifact_dir}/compose-ps.txt"
    bleat_compose logs --no-color >"${artifact_dir}/compose.log" 2>&1
}

bleat_down() {
    bleat_compose down --volumes --remove-orphans
}

case "${1:-}" in
    up)
        bleat_compose up --detach --wait
        bleat_wait
        ;;
    wait)
        bleat_wait
        ;;
    seed)
        bleat_wait
        bleat_seed
        ;;
    reset)
        bleat_down
        bleat_compose up --detach --wait
        bleat_wait
        bleat_seed
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
    down)
        bleat_down
        ;;
    *)
        print -u2 "Usage: $0 {up|wait|seed|reset|status|artifacts [directory]|down}"
        exit 64
        ;;
esac
