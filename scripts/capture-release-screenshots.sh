#!/bin/zsh

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
readonly bleat_repository_root="${bleat_script_dir:h}"
readonly bleat_fixture_directory="${bleat_repository_root}/TestSupport/ReleaseScreenshots"
readonly bleat_fixture="${BLEAT_SCREENSHOT_FIXTURE:-${bleat_fixture_directory}/fixtures.json}"
readonly bleat_compose_file="${bleat_fixture_directory}/compose.yaml"
readonly bleat_output_directory="${bleat_repository_root}/.build/release-screenshots"
readonly bleat_abs_image_default="ghcr.io/advplyr/audiobookshelf:2.36.0@sha256:180acad33d69c99ed208676465d8edcb268fa46967735579a7810859885b1a8e"
readonly bleat_abs_image="${BLEAT_SCREENSHOT_ABS_IMAGE:-${bleat_abs_image_default}}"
readonly bleat_run_id="$(/usr/bin/uuidgen | tr '[:upper:]' '[:lower:]')"
readonly bleat_compose_project="bleat-release-screenshots-${bleat_run_id}"
readonly bleat_password="$(/usr/bin/uuidgen)"
readonly bleat_appearances_raw="${BLEAT_SCREENSHOT_APPEARANCES:-light,dark}"
readonly bleat_orientations_raw="${BLEAT_SCREENSHOT_ORIENTATIONS-portrait,landscapeLeft}"
readonly bleat_locale="${BLEAT_SCREENSHOT_LOCALE:-en_AU}"
readonly bleat_requested_port="${BLEAT_SCREENSHOT_PORT:-}"
readonly bleat_device_types_raw="${BLEAT_SCREENSHOT_DEVICES:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max,com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB}"
readonly bleat_record_video="${BLEAT_SCREENSHOT_RECORD_VIDEO:-0}"
readonly bleat_work_directory="${bleat_output_directory}/work-${bleat_run_id}"
readonly bleat_media_directory="${bleat_work_directory}/media"
readonly bleat_derived_data="${bleat_work_directory}/derived-data"
readonly bleat_ids_file="${bleat_work_directory}/resolved-ids.json"

bleat_runtime=""
bleat_https_port=""
bleat_server_hostname=""
bleat_base_url=""
bleat_ca_file=""
bleat_harness_started=0
bleat_cleanup_armed=0
bleat_xctestrun=""
bleat_captured_dimensions=""
bleat_recording_pid=""
bleat_recording_path=""
typeset -a bleat_simulators
typeset -a bleat_result_bundles
typeset -a bleat_appearances
typeset -a bleat_orientations

bleat_fail() {
    print -u2 -- "$*"
    if (( bleat_cleanup_armed )); then
        bleat_cleanup 1
    fi
    exit 1
}

bleat_compose() {
    docker compose \
        --project-name "${bleat_compose_project}" \
        --file "${bleat_compose_file}" \
        "$@"
}

bleat_redact() {
    sed -E \
        -e "s/${bleat_password}/[REDACTED]/g" \
        -e 's/(Authorization: Bearer )[A-Za-z0-9._-]+/\1[REDACTED]/g' \
        -e 's/("(accessToken|refreshToken|password)"[[:space:]]*:[[:space:]]*")[^"]*"/\1[REDACTED]"/g'
}

bleat_capture_failure_artifacts() {
    local failure_directory="${bleat_output_directory}/failure"
    mkdir -p "${failure_directory}"
    bleat_compose ps 2>&1 | bleat_redact \
        >"${failure_directory}/compose-ps.txt" || true
    bleat_compose logs --no-color 2>&1 | bleat_redact \
        >"${failure_directory}/compose.log" || true
}

bleat_start_screen_recording() {
    local simulator="$1"
    local label="$2"
    local orientation="$3"
    local appearance="$4"
    (( bleat_record_video )) || return 0

    mkdir -p "${bleat_output_directory}/recordings"
    bleat_recording_path="${bleat_output_directory}/recordings/${label}-${orientation}-${appearance}.mp4"
    xcrun simctl io "${simulator}" recordVideo --codec=h264 --force \
        "${bleat_recording_path}" &
    bleat_recording_pid=$!
}

bleat_stop_screen_recording() {
    [[ -n "${bleat_recording_pid}" ]] || return 0

    local recording_pid="${bleat_recording_pid}"
    local recording_path="${bleat_recording_path}"
    bleat_recording_pid=""
    bleat_recording_path=""
    kill -INT "${recording_pid}" >/dev/null 2>&1 || true
    wait "${recording_pid}" || true
    [[ -s "${recording_path}" ]]
}

bleat_cleanup() {
    local exit_code="$1"
    trap - EXIT ZERR HUP INT QUIT TERM

    if ! bleat_stop_screen_recording; then
        print -u2 -- "Simulator screen recording did not produce a video"
        (( exit_code == 0 )) && exit_code=1
    fi

    if (( exit_code != 0 )) && (( bleat_harness_started )); then
        bleat_capture_failure_artifacts
        local simulator
        for simulator in "${bleat_simulators[@]}"; do
            xcrun simctl io "${simulator}" screenshot \
                "${bleat_output_directory}/failure/${simulator}.png" \
                >/dev/null 2>&1 || true
        done
    fi

    local simulator
    for simulator in "${bleat_simulators[@]}"; do
        xcrun simctl status_bar "${simulator}" clear >/dev/null 2>&1 || true
        xcrun simctl shutdown "${simulator}" >/dev/null 2>&1 || true
        xcrun simctl delete "${simulator}" >/dev/null 2>&1 || true
    done
    if [[ -n "${bleat_ca_file}" ]]; then
        rm -f "${bleat_ca_file}"
    fi
    if (( bleat_harness_started )); then
        bleat_compose down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi

    rm -rf "${bleat_work_directory}"
    if (( exit_code == 0 )); then
        rm -rf "${bleat_output_directory}/results"
        rmdir "${bleat_output_directory}/failure" >/dev/null 2>&1 || true
    else
        rm -rf "${bleat_output_directory}/iphone" "${bleat_output_directory}/ipad"
        rm -f "${bleat_output_directory}/manifest.json"
    fi
    exit "${exit_code}"
}

bleat_handle_exit() {
    local exit_code=$?
    if (( bleat_cleanup_armed )); then
        bleat_cleanup "${exit_code}"
    fi
    return "${exit_code}"
}

bleat_abort() {
    trap - HUP INT QUIT TERM
    exit "$1"
}

bleat_validate_fixture() {
    [[ -f "${bleat_fixture}" ]] || bleat_fail "Fixture manifest is missing"
    jq --exit-status '
        .schemaVersion == 2
        and .server.friendlyName == "Barnyard"
        and .server.hostname == "barnyard.terminaloutcomes.com"
        and .server.pathPrefix == "/audiobookshelf"
        and .account.username == "kid"
        and (.books | length == 5)
        and ([.books[].key] | unique | length == 5)
        and ([.books[].title] | unique | length == 5)
        and ([.books[].cover] | unique | length == 5)
        and all(.books[];
            ((.duration | type) == "number" and .duration > 0)
            and (if .progress then
                ((.progress.currentTime | type) == "number")
                and (.progress.currentTime >= 0)
                and (.progress.currentTime <= .duration)
                and ((.progress.isFinished | type) == "boolean")
            else true end))
        and ([.screenshots[].file] | length == 10)
        and ([.screenshots[].file] | unique | length == 10)
        and (.screenshots | map(.file) == [
            "00-login.png", "01-home.png", "02-library.png",
            "03-goat-sounds-detail.png", "04-goat-sounds-chapters.png",
            "05-mini-player.png", "06-now-playing.png", "07-downloads.png",
            "08-search.png", "09-settings.png"
        ])
        and (.books[] | select(.key == "thirteen-hours-of-goat-sounds")
            | .duration == 46800
            and .progress.currentTime == 19800
            and .progress.isFinished == false
            and (.chapters | length == 13)
            and ([.chapters[].start] == [range(0; 46800; 3600)])
            and ([.chapters[].end] == [range(3600; 50400; 3600)])
            and (.chapters[5].title == "romantic goats")
            and (.chapters[10].title == "oh no leave each other alone"))
        and ([.books[] | select(.series.name == "Barnyard Skills") | .series.sequence] | sort == ["1", "2"])
    ' "${bleat_fixture}" >/dev/null || bleat_fail "Fixture manifest failed validation"

    local cover
    while IFS= read -r cover; do
        [[ -f "${bleat_fixture_directory}/${cover}" ]] \
            || bleat_fail "Fixture cover is missing: ${cover}"
        sips -g pixelWidth -g pixelHeight "${bleat_fixture_directory}/${cover}" \
            | awk '/pixelWidth:/ { width = $2 } /pixelHeight:/ { height = $2 } END { exit !(width >= 600 && height >= 600 && width == height) }' \
            || bleat_fail "Fixture cover is not a square image of at least 600 px: ${cover}"
    done < <(jq --raw-output '.books[].cover' "${bleat_fixture}")
}

bleat_require_prerequisites() {
    local command
    for command in docker jq sips xcodebuild xcrun plutil; do
        command -v "${command}" >/dev/null \
            || bleat_fail "Required command is unavailable: ${command}"
    done
    docker compose version >/dev/null
    docker info >/dev/null \
        || bleat_fail "Docker is installed but its daemon is unavailable; start Docker Desktop or OrbStack and retry"
    xcrun xcresulttool --version >/dev/null
    xcrun simctl list runtimes available --json >/dev/null
    if [[ -n "${bleat_requested_port}" ]]; then
        [[ "${bleat_requested_port}" == <-> ]] \
            || bleat_fail "BLEAT_SCREENSHOT_PORT must be a TCP port number"
        command -v lsof >/dev/null || bleat_fail "Required command is unavailable: lsof"
        if lsof -nP -iTCP:"${bleat_requested_port}" -sTCP:LISTEN >/dev/null 2>&1; then
            bleat_fail "BLEAT_SCREENSHOT_PORT ${bleat_requested_port} is already in use"
        fi
    fi
}

bleat_resolve_runtime() {
    local runtimes
    runtimes="$(xcrun simctl list runtimes available --json)"
    bleat_runtime="${BLEAT_SCREENSHOT_RUNTIME:-$(
        print -r -- "${runtimes}" | jq --exit-status --raw-output '
            [.runtimes[] | select(.isAvailable and (.name | startswith("iOS")))]
            | last | .identifier // empty
        '
    )}"
    [[ -n "${bleat_runtime}" ]] || bleat_fail "No available iOS Simulator runtime was found"
    print -r -- "${runtimes}" | jq --exit-status --arg runtime "${bleat_runtime}" '
        any(.runtimes[]; .identifier == $runtime and .isAvailable)
    ' >/dev/null || {
        print -u2 "Requested runtime is unavailable: ${bleat_runtime}"
        print -u2 "Available iOS runtimes:"
        print -r -- "${runtimes}" | jq --raw-output '.runtimes[] | select(.isAvailable and (.name | startswith("iOS"))) | "  \(.identifier) (\(.name))"' >&2
        return 1
    }
}

bleat_device_types() {
    local raw_type device_type
    local -a types
    types=("${(@s:,:)bleat_device_types_raw}")
    (( ${#types} >= 1 && ${#types} <= 2 )) \
        || bleat_fail "BLEAT_SCREENSHOT_DEVICES must contain one iPhone, optionally followed by one iPad device type"

    local phone_count=0
    local pad_count=0
    for raw_type in "${types[@]}"; do
        device_type="${raw_type//[[:space:]]/}"
        case "${device_type}" in
            *iPhone*) (( phone_count += 1 )) ;;
            *iPad*) (( pad_count += 1 )) ;;
            *) bleat_fail "Screenshot device type must be an iPhone or iPad: ${device_type}" ;;
        esac
        xcrun simctl list runtimes available --json \
            | jq --exit-status --arg runtime "${bleat_runtime}" --arg device "${device_type}" '
                any(.runtimes[]; .identifier == $runtime and .isAvailable
                    and any(.supportedDeviceTypes[]?; .identifier == $device))
            ' >/dev/null || {
            print -u2 "Requested device type is unavailable for ${bleat_runtime}: ${device_type}"
            print -u2 "Available device types:"
            xcrun simctl list runtimes available --json \
                | jq --raw-output --arg runtime "${bleat_runtime}" '
                    .runtimes[] | select(.identifier == $runtime) | .supportedDeviceTypes[]?.identifier | "  \(.)"
                ' >&2
            return 1
        }
        print -r -- "${device_type}"
    done
    (( phone_count == 1 && pad_count <= 1 )) \
        || bleat_fail "BLEAT_SCREENSHOT_DEVICES must contain exactly one iPhone and at most one iPad"
}

bleat_generate_media() {
    mkdir -p "${bleat_media_directory}"
    local key folder media_file duration measured_duration
    while IFS= read -r key; do
        folder="$(jq --raw-output --arg key "${key}" '.books[] | select(.key == $key) | .folder' "${bleat_fixture}")"
        media_file="$(jq --raw-output --arg key "${key}" '.books[] | select(.key == $key) | .mediaFile' "${bleat_fixture}")"
        duration="$(jq --raw-output --arg key "${key}" '.books[] | select(.key == $key) | .duration' "${bleat_fixture}")"
        mkdir -p "${bleat_media_directory}/${folder}"
        docker run --rm \
            --user "$(id -u):$(id -g)" \
            --volume "${bleat_media_directory}:/audiobooks" \
            --entrypoint ffmpeg \
            "${bleat_abs_image}" \
            -hide_banner -loglevel error \
            -f lavfi -i anullsrc=r=16000:cl=mono \
            -t "${duration}" -c:a aac -b:a 16k -movflags +faststart \
            "/audiobooks/${folder}/${media_file}"
        measured_duration="$(
            docker run --rm \
                --volume "${bleat_media_directory}:/audiobooks:ro" \
                --entrypoint ffprobe \
                "${bleat_abs_image}" \
                -v error -show_entries format=duration -of default=nw=1:nk=1 \
                "/audiobooks/${folder}/${media_file}"
        )"
        awk -v actual="${measured_duration}" -v expected="${duration}" \
            'BEGIN { exit !(actual > expected - 0.01 && actual < expected + 0.01) }' \
            || bleat_fail "Media duration validation failed for ${media_file}"
    done < <(jq --raw-output '.books[].key' "${bleat_fixture}")
}

bleat_curl() {
    /usr/bin/curl --fail --silent --show-error --max-time 20 \
        --cacert "${bleat_ca_file}" \
        --resolve "${bleat_server_hostname}:${bleat_https_port}:127.0.0.1" "$@"
}

bleat_wait_for_https() {
    local attempt
    bleat_ca_file="$(mktemp /tmp/bleat-barnyard-ca.XXXXXX)"
    for attempt in {1..30}; do
        bleat_compose cp caddy:/data/caddy/pki/authorities/local/root.crt "${bleat_ca_file}" >/dev/null 2>&1 || true
        if [[ -s "${bleat_ca_file}" ]] \
            && bleat_curl "${bleat_base_url}/status" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    bleat_fail "Barnyard HTTPS proxy did not become ready"
}

bleat_initialize_and_login() {
    local username server_status
    username="$(jq --raw-output '.account.username' "${bleat_fixture}")"
    server_status="$(bleat_curl "${bleat_base_url}/status")"
    if [[ "$(print -r -- "${server_status}" | jq --raw-output '.isInit')" == "false" ]]; then
        bleat_curl --request POST --header 'Content-Type: application/json' \
            --data "$(jq --null-input --arg username "${username}" --arg password "${bleat_password}" '{newRoot:{username:$username,password:$password}}')" \
            "${bleat_base_url}/init" >/dev/null
    fi
    [[ "$(bleat_curl "${bleat_base_url}/status" | jq --raw-output '.isInit')" == "true" ]] \
        || bleat_fail "Barnyard initialization did not persist"

    bleat_curl --request POST --header 'Content-Type: application/json' \
        --header 'x-return-tokens: true' \
        --data "$(jq --null-input --arg username "${username}" --arg password "${bleat_password}" '{username:$username,password:$password}')" \
        "${bleat_base_url}/login" \
        | jq --exit-status --raw-output '.user.accessToken | select(type == "string" and length > 0)'
}

bleat_seed_library() {
    local access_token="$1"
    local library_name libraries library_id items count='' attempt
    local key folder title item_id payload cover ids_temporary
    local hero_id chapters progress hero playback_session playback_session_id track_index range_status
    library_name="$(jq --raw-output '.server.libraryName' "${bleat_fixture}")"
    libraries="$(bleat_curl --header "Authorization: Bearer ${access_token}" "${bleat_base_url}/api/libraries")"
    library_id="$(print -r -- "${libraries}" | jq --raw-output --arg name "${library_name}" '.libraries[]? | select(.name == $name) | .id' | head -n 1)"
    if [[ -z "${library_id}" ]]; then
        library_id="$(
            bleat_curl --request POST \
                --header "Authorization: Bearer ${access_token}" \
                --header 'Content-Type: application/json' \
                --data "$(jq --null-input --arg name "${library_name}" '{name:$name,folders:[{fullPath:"/audiobooks"}],mediaType:"book",provider:"google"}')" \
                "${bleat_base_url}/api/libraries" \
                | jq --exit-status --raw-output '.id | select(type == "string" and length > 0)'
        )"
    fi
    bleat_curl --request POST --header "Authorization: Bearer ${access_token}" \
        "${bleat_base_url}/api/libraries/${library_id}/scan" >/dev/null

    for attempt in {1..60}; do
        items="$(bleat_curl --header "Authorization: Bearer ${access_token}" "${bleat_base_url}/api/libraries/${library_id}/items?limit=50&sort=title&desc=0")"
        count="$(print -r -- "${items}" | jq --raw-output '.total')"
        if [[ "${count}" == "5" ]]; then
            break
        fi
        sleep 1
    done
    [[ "${count}" == "5" ]] || bleat_fail "Expected five Barnyard books after scanning, received ${count}"

    print -- '{}' >"${bleat_ids_file}"
    while IFS= read -r key; do
        folder="$(jq --raw-output --arg key "${key}" '.books[] | select(.key == $key) | .folder' "${bleat_fixture}")"
        title="$(jq --raw-output --arg key "${key}" '.books[] | select(.key == $key) | .title' "${bleat_fixture}")"
        item_id="$(print -r -- "${items}" | jq --raw-output --arg folder "${folder}" '
            .results[]?
            | select(.relPath == $folder)
            | .id
        ' | head -n 1)"
        [[ -n "${item_id}" ]] || bleat_fail "Could not resolve scanned Barnyard book: ${title}"

        payload="$(jq --compact-output --arg key "${key}" '
            .books[] | select(.key == $key) | {
                metadata: {
                    title: .title,
                    authors: (.authors | map({name: .})),
                    narrators: .narrators,
                    series: (if .series then [{name: .series.name, sequence: .series.sequence}] else [] end),
                    description: .description,
                    genres: .genres
                },
                tags: .tags
            }
        ' "${bleat_fixture}")"
        bleat_curl --request PATCH --header "Authorization: Bearer ${access_token}" \
            --header 'Content-Type: application/json' --data "${payload}" \
            "${bleat_base_url}/api/items/${item_id}/media" >/dev/null

        cover="$(jq --raw-output --arg key "${key}" '.books[] | select(.key == $key) | .cover' "${bleat_fixture}")"
        bleat_curl --request POST --header "Authorization: Bearer ${access_token}" \
            --form "cover=@${bleat_fixture_directory}/${cover};type=image/png" \
            "${bleat_base_url}/api/items/${item_id}/cover" \
            | jq --exit-status '.success == true' >/dev/null

        ids_temporary="${bleat_ids_file}.tmp"
        jq --arg key "${key}" --arg id "${item_id}" '. + {($key): $id}' \
            "${bleat_ids_file}" >"${ids_temporary}"
        mv "${ids_temporary}" "${bleat_ids_file}"
    done < <(jq --raw-output '.books[].key' "${bleat_fixture}")

    hero_id="$(jq --raw-output '."thirteen-hours-of-goat-sounds"' "${bleat_ids_file}")"
    chapters="$(jq --compact-output '.books[] | select(.key == "thirteen-hours-of-goat-sounds") | {chapters:.chapters}' "${bleat_fixture}")"
    bleat_curl --request POST --header "Authorization: Bearer ${access_token}" \
        --header 'Content-Type: application/json' --data "${chapters}" \
        "${bleat_base_url}/api/items/${hero_id}/chapters" >/dev/null

    while IFS= read -r key; do
        progress="$(jq --compact-output --arg key "${key}" '
            .books[] | select(.key == $key) | select(.progress) | {
                duration: .duration,
                currentTime: .progress.currentTime,
                progress: (.progress.currentTime / .duration),
                isFinished: .progress.isFinished,
                hideFromContinueListening: false
            }
        ' "${bleat_fixture}")"
        [[ -n "${progress}" ]] || continue
        item_id="$(jq --raw-output --arg key "${key}" '.[$key]' "${bleat_ids_file}")"
        bleat_curl --request PATCH --header "Authorization: Bearer ${access_token}" \
            --header 'Content-Type: application/json' --data "${progress}" \
            "${bleat_base_url}/api/me/progress/${item_id}" >/dev/null
    done < <(jq --raw-output '.books[] | select(.progress) | .key' "${bleat_fixture}")

    hero="$(bleat_curl --header "Authorization: Bearer ${access_token}" "${bleat_base_url}/api/items/${hero_id}?expanded=1&include=progress")"
    print -r -- "${hero}" | jq --exit-status '
        .media.duration == 46800
        and (.media.chapters | length == 13)
        and ([.media.chapters[].start] == [range(0; 46800; 3600)])
        and ([.media.chapters[].title] | index("happy goats"))
        and ([.media.chapters[].title] | index("bouncing goats"))
        and ([.media.chapters[].title] | index("romantic goats"))
        and ([.media.chapters[].title] | index("oh no leave each other alone"))
    ' >/dev/null || bleat_fail "Barnyard hero metadata or chapter verification failed"
    bleat_curl --header "Authorization: Bearer ${access_token}" \
        "${bleat_base_url}/api/me/progress/${hero_id}" \
        | jq --exit-status '.currentTime == 19800 and .isFinished == false' >/dev/null \
        || bleat_fail "Barnyard hero progress verification failed"

    playback_session="$(
        bleat_curl --request POST --header "Authorization: Bearer ${access_token}" \
            --header 'Content-Type: application/json' \
            --data '{
                "forceDirectPlay": true,
                "forceTranscode": false,
                "mediaPlayer": "AVPlayer",
                "supportedMimeTypes": ["audio/mp4", "audio/mpeg"],
                "deviceInfo": {
                    "deviceId": "bleat-release-screenshot-harness",
                    "clientName": "Bleat Release Screenshots",
                    "clientVersion": "1.0",
                    "manufacturer": "Apple",
                    "model": "Screenshot Harness"
                }
            }' "${bleat_base_url}/api/items/${hero_id}/play"
    )"
    playback_session_id="$(print -r -- "${playback_session}" | jq --exit-status --raw-output '.id | select(type == "string" and length > 0)')"
    track_index="$(print -r -- "${playback_session}" | jq --exit-status --raw-output '.audioTracks[0].index | select(type == "number" and . >= 0)')"
    range_status="$(bleat_curl --range 0-1023 --output /dev/null --write-out '%{http_code}' \
        "${bleat_base_url}/public/session/${playback_session_id}/track/${track_index}")"
    bleat_curl --request POST --header "Authorization: Bearer ${access_token}" \
        "${bleat_base_url}/api/session/${playback_session_id}/close" >/dev/null || true
    [[ "${range_status}" == "206" ]] \
        || bleat_fail "Barnyard hero playback session does not support HTTP range requests"
}

bleat_configure_simulator() {
    local simulator="$1"
    local locale_bcp47="${bleat_locale/_/-}"
    xcrun simctl boot "${simulator}"
    xcrun simctl bootstatus "${simulator}" -b
    xcrun simctl spawn "${simulator}" defaults write NSGlobalDomain AppleLanguages -array "${locale_bcp47}"
    xcrun simctl spawn "${simulator}" defaults write NSGlobalDomain AppleLocale -string "${bleat_locale}"
    xcrun simctl spawn "${simulator}" defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool NO
    xcrun simctl shutdown "${simulator}"
    xcrun simctl boot "${simulator}"
    xcrun simctl bootstatus "${simulator}" -b
    xcrun simctl status_bar "${simulator}" override \
        --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --batteryState charged --batteryLevel 100
    xcrun simctl keychain "${simulator}" add-root-cert "${bleat_ca_file}"
}

bleat_suffixed_filename() {
    local base="$1"
    local appearance="$2"
    if [[ "${appearance}" == "dark" ]]; then
        print -r -- "${base%.png}-dark.png"
    else
        print -r -- "${base}"
    fi
}

bleat_expected_screenshot_names() {
    local appearance="$1"
    local base
    while IFS= read -r base; do
        bleat_suffixed_filename "${base}" "${appearance}"
    done < <(jq --raw-output '.screenshots[].file' "${bleat_fixture}")
}

bleat_expected_screenshot_names_json() {
    local appearance="$1"
    jq --compact-output --arg appearance "${appearance}" '
        [.screenshots[].file
            | if $appearance == "dark" then sub("\\.png$"; "-dark.png") else . end]
    ' "${bleat_fixture}"
}

bleat_set_xctestrun_env() {
    local key="$1"
    local value="$2"
    if ! plutil -replace "${key}" -string "${value}" "${bleat_xctestrun}" >/dev/null 2>&1; then
        plutil -insert "${key}" -string "${value}" "${bleat_xctestrun}"
    fi
}

bleat_image_dimensions() {
    sips -g pixelWidth -g pixelHeight "$1" \
        | awk '/pixelWidth:/ { width = $2 } /pixelHeight:/ { height = $2 } END { if (width > 0 && height > 0) print width "x" height; else exit 1 }'
}

bleat_expected_dimensions() {
    local device_type="$1"
    case "${device_type}" in
        com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max) print '1320x2868' ;;
        com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB) print '2064x2752' ;;
        *) print '' ;;
    esac
}

bleat_oriented_dimensions() {
    local dimensions="$1"
    local orientation="$2"
    case "${orientation}" in
        portrait) print -r -- "${dimensions}" ;;
        landscapeLeft)
            print -r -- "${dimensions#*x}x${dimensions%x*}"
            ;;
        *) bleat_fail "Unsupported screenshot orientation: ${orientation}" ;;
    esac
}

bleat_validate_attachment_manifest() {
    local attachment_manifest="$1"
    local appearance="$2"
    [[ -f "${attachment_manifest}" ]] \
        || bleat_fail "Screenshot attachment manifest is missing"
    local expected_names
    expected_names="$(bleat_expected_screenshot_names_json "${appearance}")"
    jq --exit-status --argjson expected "${expected_names}" '
        def isScreenshotName($expectedName):
            . == $expectedName
            or (
                startswith($expectedName | sub("\\.png$"; "") + "_")
                and endswith(".png")
            );
        [.[].attachments[]? | .suggestedHumanReadableName] as $attachmentNames
        | [
            $expected[] as $expectedName
            | [$attachmentNames[] | select(isScreenshotName($expectedName))] as $matches
            | select($matches | length == 1)
            | $matches[0]
        ] as $found
        | ($found | length == ($expected | length))
          and ($found | unique | length == ($expected | length))
    ' "${attachment_manifest}" >/dev/null \
        || bleat_fail "Result bundle does not contain exactly the required named screenshot attachments for ${appearance}"
}

bleat_exported_attachment_name() {
    local attachment_manifest="$1"
    local expected_filename="$2"
    jq --raw-output --arg expected_filename "${expected_filename}" '
        def isScreenshotName($expectedName):
            . == $expectedName
            or (
                startswith($expectedName | sub("\\.png$"; "") + "_")
                and endswith(".png")
            );
        [
            .[].attachments[]?
            | select(.suggestedHumanReadableName | isScreenshotName($expected_filename))
            | .exportedFileName
        ]
        | if length == 1 then .[0] else empty end
    ' "${attachment_manifest}"
}

bleat_validate_exported_screenshot() {
    local screenshot="$1"
    local expected_dimensions="$2"
    local device_label="$3"
    local filename="$4"
    local orientation="$5"
    [[ -f "${screenshot}" ]] \
        || bleat_fail "Screenshot attachment export is missing ${filename} for ${device_label}"
    local dimensions
    dimensions="$(bleat_image_dimensions "${screenshot}")"
    [[ "${dimensions}" == "${expected_dimensions}" ]] \
        || bleat_fail "Screenshot dimensions for ${device_label}/${filename} were ${dimensions}, expected ${expected_dimensions}"
    local width="${dimensions%x*}"
    local height="${dimensions#*x}"
    case "${orientation}" in
        portrait)
            (( height > width )) || bleat_fail "Screenshot is not portrait: ${device_label}/${filename}"
            ;;
        landscapeLeft)
            (( width > height )) || bleat_fail "Screenshot is not landscape: ${device_label}/${filename}"
            ;;
        *)
            bleat_fail "Unsupported screenshot orientation: ${orientation}"
            ;;
    esac
}

bleat_normalize_exported_screenshot() {
    local screenshot="$1"
    local orientation="$2"
    [[ "${orientation}" == "landscapeLeft" ]] || return 0

    local dimensions
    dimensions="$(bleat_image_dimensions "${screenshot}")"
    local width="${dimensions%x*}"
    local height="${dimensions#*x}"
    (( height > width )) || return 0

    local rotated="${screenshot%.png}-landscapeLeft.png"
    sips --rotate -90 "${screenshot}" --out "${rotated}" >/dev/null
    mv "${rotated}" "${screenshot}"
}

bleat_validate_public_manifest() {
    local manifest="$1"
    [[ -f "${manifest}" ]] || bleat_fail "Release screenshot manifest is missing"
    jq --exit-status '
        ([.. | objects | keys_unsorted[]? | select(test("token|password|credential|resolved|response"; "i"))] | length == 0)
        and ([.. | strings | select(test("bearer[[:space:]]|access[_-]?token|refresh[_-]?token|https?://|/Users/"; "i"))] | length == 0)
    ' "${manifest}" >/dev/null \
        || bleat_fail "Release screenshot manifest contains sensitive data"
}

bleat_validate_exported_artifacts() {
    local attachment_manifest="$1"
    local attachment_directory="$2"
    local expected_dimensions="$3"
    local device_label="$4"
    local appearance="$5"
    local orientation="$6"
    bleat_validate_attachment_manifest "${attachment_manifest}" "${appearance}"

    local filename exported_name
    while IFS= read -r filename; do
        exported_name="$(bleat_exported_attachment_name "${attachment_manifest}" "${filename}")"
        [[ -n "${exported_name}" ]] \
            || bleat_fail "Screenshot attachment export is missing ${filename} for ${device_label}"
        bleat_validate_exported_screenshot \
            "${attachment_directory}/${exported_name}" "${expected_dimensions}" \
            "${device_label}" "${filename}" "${orientation}"
    done < <(bleat_expected_screenshot_names "${appearance}")
}

bleat_export_screenshots() {
    local result_bundle="$1"
    local device_label="$2"
    local expected_dimensions="$3"
    local appearance="$4"
    local orientation="$5"
    local exported_directory="${bleat_work_directory}/attachments-${device_label}-${orientation}-${appearance}"
    local destination_directory="${bleat_output_directory}/${device_label}"
    if [[ "${orientation}" != "portrait" ]]; then
        destination_directory="${destination_directory}/${orientation}"
    fi
    mkdir -p "${exported_directory}" "${destination_directory}"
    xcrun xcresulttool export attachments --path "${result_bundle}" \
        --output-path "${exported_directory}" >/dev/null
    bleat_validate_attachment_manifest "${exported_directory}/manifest.json" "${appearance}"

    local filename exported_name
    while IFS= read -r filename; do
        exported_name="$(bleat_exported_attachment_name "${exported_directory}/manifest.json" "${filename}")"
        [[ -n "${exported_name}" ]] \
            || bleat_fail "Screenshot attachment export is missing ${filename} for ${device_label}"
        bleat_normalize_exported_screenshot \
            "${exported_directory}/${exported_name}" "${orientation}"
        bleat_validate_exported_screenshot \
            "${exported_directory}/${exported_name}" "${expected_dimensions}" \
            "${device_label}" "${filename}" "${orientation}"
        cp "${exported_directory}/${exported_name}" "${destination_directory}/${filename}"
        bleat_validate_exported_screenshot \
            "${destination_directory}/${filename}" "${expected_dimensions}" \
            "${device_label}" "${filename}" "${orientation}"
    done < <(bleat_expected_screenshot_names "${appearance}")
}

bleat_validate_test_result() {
    local result_bundle="$1"
    local device_label="$2"
    local orientation="$3"
    local appearance="$4"
    local summary
    summary="$(
        xcrun xcresulttool get test-results summary \
            --path "${result_bundle}" --compact
    )"
    jq --exit-status '
        .result == "Passed"
        and .totalTestCount == 1
        and .passedTests == 1
        and .failedTests == 0
        and .skippedTests == 0
        and .expectedFailures == 0
    ' <<<"${summary}" >/dev/null \
        || bleat_fail "Screenshot result for ${device_label} ${orientation} ${appearance} did not contain exactly one passing test"
    print "Verified ${device_label} ${orientation} ${appearance}: exactly one screenshot test passed"
}

bleat_build_manifest() {
    local iphone_dimensions="$1"
    local ipad_dimensions="$2"
    local iphone_type="$3"
    local ipad_type="$4"
    local xcode_version
    xcode_version="$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    local commit
    commit="$(git -C "${bleat_repository_root}" rev-parse HEAD)"
    local dirty=false
    [[ -n "$(git -C "${bleat_repository_root}" status --porcelain)" ]] && dirty=true
    local appearances_json
    appearances_json="$(jq --compact-output -n --args '$ARGS.positional' -- "${bleat_appearances[@]}")"
    local orientations_json
    orientations_json="$(jq --compact-output -n --args '$ARGS.positional' -- "${bleat_orientations[@]}")"
    local screenshots_json
    screenshots_json="$(
        jq --compact-output --argjson appearances "${appearances_json}" --argjson orientations "${orientations_json}" '
            .screenshots as $base
            | [$orientations[] as $orientation | $appearances[] as $appearance
                | $base | map(. + {
                    appearance: $appearance,
                    orientation: $orientation,
                    file: (if $appearance == "dark"
                        then (.file | sub("\\.png$"; "-dark.png"))
                        else .file end)
                })] | add
        ' "${bleat_fixture}"
    )"
    jq --null-input \
        --arg app_version "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${bleat_derived_data}/Build/Products/Release-iphonesimulator/Bleat.app/Info.plist")" \
        --arg build_number "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${bleat_derived_data}/Build/Products/Release-iphonesimulator/Bleat.app/Info.plist")" \
        --arg commit "${commit}" --arg xcode "${xcode_version}" \
        --arg runtime "${bleat_runtime}" --arg locale "${bleat_locale}" \
        --argjson appearances "${appearances_json}" \
        --argjson orientations "${orientations_json}" \
        --arg iphone_dimensions "${iphone_dimensions}" \
        --arg ipad_dimensions "${ipad_dimensions}" --arg iphone_type "${iphone_type}" \
        --arg ipad_type "${ipad_type}" --arg abs_image "${bleat_abs_image}" \
        --arg caddy_image 'caddy:2.10.2-alpine@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d' \
        --argjson dirty "${dirty}" \
        --argjson schema_version "$(jq '.schemaVersion' "${bleat_fixture}")" \
        --argjson screenshots "${screenshots_json}" '
            def captures($dimensions):
                $orientations | map({
                    orientation: ., pixelDimensions: (
                        if . == "portrait" then $dimensions
                        else ($dimensions | split("x") | "\(.[1])x\(.[0])")
                        end
                    )
                });
            {
                app: {version: $app_version, build: $build_number},
                git: {commit: $commit, dirtyWorktree: $dirty},
                xcode: $xcode,
                simulator: ({
                    runtime: $runtime,
                    locale: $locale,
                    appearances: $appearances,
                    orientations: $orientations,
                    iphone: {deviceType: $iphone_type, captures: captures($iphone_dimensions)}
                } + (if $ipad_dimensions == "" then {} else {
                    ipad: {deviceType: $ipad_type, captures: captures($ipad_dimensions)}
                } end)),
                images: {audiobookshelf: $abs_image, caddy: $caddy_image},
                fixtureSchemaVersion: $schema_version,
                screenshots: $screenshots
            }
        ' >"${bleat_output_directory}/manifest.json"
    bleat_validate_public_manifest "${bleat_output_directory}/manifest.json"
}

bleat_capture_device() {
    local device_type="$1"
    local label="$2"
    local simulator
    simulator="$(xcrun simctl create "Bleat Release ${label} ${bleat_run_id}" "${device_type}" "${bleat_runtime}")"
    bleat_simulators+=("${simulator}")
    bleat_configure_simulator "${simulator}"

    local calibration_image="${bleat_work_directory}/${label}-calibration.png"
    xcrun simctl io "${simulator}" screenshot "${calibration_image}"
    local dimensions
    dimensions="$(bleat_image_dimensions "${calibration_image}")"
    local documented_dimensions
    documented_dimensions="$(bleat_expected_dimensions "${device_type}")"
    if [[ -n "${documented_dimensions}" && "${dimensions}" != "${documented_dimensions}" ]]; then
        bleat_fail "${label} simulator dimensions were ${dimensions}, expected ${documented_dimensions}"
    fi

    xcodebuild -quiet \
        -project "${bleat_repository_root}/Bleat.xcodeproj" \
        -scheme Bleat -configuration Release \
        -destination "id=${simulator}" \
        -derivedDataPath "${bleat_derived_data}" \
        -parallel-testing-enabled NO \
        ENABLE_TESTABILITY=YES \
        BUILD_WITHOUT_PAID_DEVELOPER=YES \
        BLEAT_CARPLAY_MODE="${BLEAT_CARPLAY_MODE:-disabled}" \
        build-for-testing
    bleat_xctestrun="$(find "${bleat_derived_data}/Build/Products" -name '*.xctestrun' -print -quit)"
    [[ -n "${bleat_xctestrun}" ]] || bleat_fail "Xcode did not produce an xctestrun file"
    plutil -insert 'BleatUITests.EnvironmentVariables.BLEAT_SCREENSHOT_APP_URL' -string "${bleat_base_url}" "${bleat_xctestrun}"
    plutil -insert 'BleatUITests.EnvironmentVariables.BLEAT_SCREENSHOT_USERNAME' -string "$(jq --raw-output '.account.username' "${bleat_fixture}")" "${bleat_xctestrun}"
    plutil -insert 'BleatUITests.EnvironmentVariables.BLEAT_SCREENSHOT_PASSWORD' -string "${bleat_password}" "${bleat_xctestrun}"
    plutil -insert 'BleatUITests.EnvironmentVariables.BLEAT_SCREENSHOT_ENABLED' -string '1' "${bleat_xctestrun}"

    mkdir -p "${bleat_output_directory}/results"
    local orientation appearance
    for orientation in "${bleat_orientations[@]}"; do
        local oriented_dimensions
        oriented_dimensions="$(bleat_oriented_dimensions "${dimensions}" "${orientation}")"
        for appearance in "${bleat_appearances[@]}"; do
            xcrun simctl ui "${simulator}" appearance "${appearance}"
            bleat_set_xctestrun_env 'BleatUITests.EnvironmentVariables.BLEAT_SCREENSHOT_APPEARANCE' "${appearance}"
            bleat_set_xctestrun_env 'BleatUITests.EnvironmentVariables.BLEAT_SCREENSHOT_ORIENTATION' "${orientation}"

            local result_bundle="${bleat_output_directory}/results/${label}-${orientation}-${appearance}.xcresult"
            bleat_result_bundles+=("${result_bundle}")
            bleat_start_screen_recording "${simulator}" "${label}" "${orientation}" "${appearance}"
            xcodebuild -quiet -xctestrun "${bleat_xctestrun}" \
                -destination "id=${simulator}" -parallel-testing-enabled NO \
                -resultBundlePath "${result_bundle}" \
                -only-testing:BleatUITests/BleatReleaseScreenshotTests/testReleaseScreenshots \
                test-without-building
            bleat_stop_screen_recording \
                || bleat_fail "Simulator screen recording did not produce a video for ${label} ${orientation} ${appearance}"
            [[ -f "${result_bundle}/Info.plist" ]] \
                || bleat_fail "Screenshot test did not produce a result bundle for ${label} ${orientation} ${appearance}"
            bleat_validate_test_result \
                "${result_bundle}" "${label}" "${orientation}" "${appearance}"
            bleat_export_screenshots "${result_bundle}" "${label}" "${oriented_dimensions}" "${appearance}" "${orientation}"
        done
    done
    bleat_captured_dimensions="${dimensions}"
}

bleat_resolve_appearances() {
    local raw appearance
    local -a parsed
    for raw in "${(@s:,:)bleat_appearances_raw}"; do
        appearance="${raw//[[:space:]]/}"
        case "${appearance}" in
            light|dark) ;;
            *) bleat_fail "BLEAT_SCREENSHOT_APPEARANCES must be a comma-separated list of light and/or dark (got: ${bleat_appearances_raw})" ;;
        esac
        if (( ${parsed[(Ie)${appearance}]} == 0 )); then
            parsed+=("${appearance}")
        fi
    done
    (( ${#parsed} >= 1 )) || bleat_fail "BLEAT_SCREENSHOT_APPEARANCES must contain at least one appearance"
    bleat_appearances=("${parsed[@]}")
}

bleat_resolve_orientations() {
    local raw orientation
    local -a parsed
    for raw in "${(@s:,:)bleat_orientations_raw}"; do
        orientation="${raw//[[:space:]]/}"
        case "${orientation}" in
            portrait|landscapeLeft) ;;
            *) bleat_fail "BLEAT_SCREENSHOT_ORIENTATIONS must be a comma-separated list of portrait and/or landscapeLeft (got: ${bleat_orientations_raw})" ;;
        esac
        if (( ${parsed[(Ie)${orientation}]} == 0 )); then
            parsed+=("${orientation}")
        fi
    done
    (( ${#parsed} >= 1 )) || bleat_fail "BLEAT_SCREENSHOT_ORIENTATIONS must contain at least one orientation"
    bleat_orientations=("${parsed[@]}")
}

bleat_main() {
    bleat_validate_fixture
    bleat_require_prerequisites
    bleat_resolve_appearances
    bleat_resolve_orientations
    [[ "${bleat_record_video}" == 0 || "${bleat_record_video}" == 1 ]] \
        || bleat_fail "BLEAT_SCREENSHOT_RECORD_VIDEO must be 0 or 1"
    [[ "${bleat_locale}" == [a-z][a-z]_[A-Z][A-Z] ]] \
        || bleat_fail "BLEAT_SCREENSHOT_LOCALE must use a language_REGION value such as en_AU"
    bleat_resolve_runtime

    local -a device_types
    device_types=("${(@f)$(bleat_device_types)}")
    if [[ -e "${bleat_output_directory}" ]]; then
        rm -rf "${bleat_output_directory}"
    fi
    mkdir -p "${bleat_output_directory}" "${bleat_work_directory}"
    bleat_cleanup_armed=1
    trap 'bleat_abort 129' HUP
    trap 'bleat_abort 130' INT
    trap 'bleat_abort 131' QUIT
    trap 'bleat_abort 143' TERM

    export BLEAT_SCREENSHOT_ABS_IMAGE="${bleat_abs_image}"
    export BLEAT_SCREENSHOT_MEDIA_DIR="${bleat_media_directory}"
    export BLEAT_SCREENSHOT_HTTPS_PORT="${bleat_requested_port}"
    bleat_generate_media
    bleat_harness_started=1
    bleat_compose up --detach --wait
    bleat_https_port="$(bleat_compose port caddy 8443 | sed -E 's/.*:([0-9]+)$/\1/')"
    [[ "${bleat_https_port}" == <-> ]] || bleat_fail "Could not determine Barnyard HTTPS port"
    bleat_server_hostname="$(jq --raw-output '.server.hostname' "${bleat_fixture}")"
    bleat_base_url="https://${bleat_server_hostname}:${bleat_https_port}/audiobookshelf"
    bleat_wait_for_https
    local access_token
    access_token="$(bleat_initialize_and_login)"
    bleat_seed_library "${access_token}"

    local iphone_dimensions=""
    local ipad_dimensions=""
    local iphone_type=""
    local ipad_type=""
    local device_type
    for device_type in "${device_types[@]}"; do
        case "${device_type}" in
            *iPhone*)
                iphone_type="${device_type}"
                bleat_capture_device "${device_type}" iphone
                iphone_dimensions="${bleat_captured_dimensions}"
                ;;
            *iPad*)
                ipad_type="${device_type}"
                bleat_capture_device "${device_type}" ipad
                ipad_dimensions="${bleat_captured_dimensions}"
                ;;
        esac
    done
    [[ -n "${iphone_dimensions}" ]] \
        || bleat_fail "An iPhone screenshot device is required"
    bleat_build_manifest "${iphone_dimensions}" "${ipad_dimensions}" \
        "${iphone_type}" "${ipad_type}"
    print "Release screenshots are available in .build/release-screenshots"
}

trap bleat_handle_exit EXIT
trap bleat_handle_exit ZERR

case "${1:-}" in
    --validate-options)
        bleat_resolve_appearances
        bleat_resolve_orientations
        ;;
    --validate-fixtures)
        bleat_validate_fixture
        ;;
    --validate-artifacts)
        bleat_validate_fixture
        [[ -n "${BLEAT_SCREENSHOT_ATTACHMENT_MANIFEST:-}" ]] \
            || bleat_fail "BLEAT_SCREENSHOT_ATTACHMENT_MANIFEST is required"
        [[ -n "${BLEAT_SCREENSHOT_ATTACHMENT_DIRECTORY:-}" ]] \
            || bleat_fail "BLEAT_SCREENSHOT_ATTACHMENT_DIRECTORY is required"
        [[ -n "${BLEAT_SCREENSHOT_EXPECTED_DIMENSIONS:-}" ]] \
            || bleat_fail "BLEAT_SCREENSHOT_EXPECTED_DIMENSIONS is required"
        [[ -n "${BLEAT_SCREENSHOT_EXPECTED_ORIENTATION:-}" ]] \
            || bleat_fail "BLEAT_SCREENSHOT_EXPECTED_ORIENTATION is required"
        bleat_resolve_appearances
        local appearance
        for appearance in "${bleat_appearances[@]}"; do
            bleat_validate_exported_artifacts \
                "${BLEAT_SCREENSHOT_ATTACHMENT_MANIFEST}" \
                "${BLEAT_SCREENSHOT_ATTACHMENT_DIRECTORY}" \
                "${BLEAT_SCREENSHOT_EXPECTED_DIMENSIONS}" artifact-check "${appearance}" \
                "${BLEAT_SCREENSHOT_EXPECTED_ORIENTATION}"
        done
        ;;
    --validate-manifest)
        [[ -n "${BLEAT_SCREENSHOT_MANIFEST:-}" ]] \
            || bleat_fail "BLEAT_SCREENSHOT_MANIFEST is required"
        bleat_validate_public_manifest "${BLEAT_SCREENSHOT_MANIFEST}"
        ;;
    '')
        bleat_main
        ;;
    *)
        print -u2 "Usage: $0 [--validate-fixtures|--validate-artifacts|--validate-manifest]"
        exit 64
        ;;
esac
