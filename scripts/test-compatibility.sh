#!/bin/zsh

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
source "${bleat_script_dir}/live-profile.sh"
if [[ -n "${BLEAT_COMPOSE_PROJECT_NAME:-}" || -n "${BLEAT_LIVE_TEST_FILTER:-}" \
    || -n "${BLEAT_COMPOSE_OVERRIDE_FILE:-}" ]]; then
    print -u2 "Compose project, override, and test selection are managed by test-compatibility.sh"
    exit 64
fi
"${bleat_script_dir}/test-live-profiles.sh"

typeset -a results
local_failed=0
for profile in minimum current-stable; do
    bleat_select_live_profile "${profile}"
    version="${BLEAT_EXPECTED_SERVER_VERSION}"
    if "${bleat_script_dir}/test-live.sh" "${profile}"; then
        results+=("${profile} ${version} PASS")
    else
        results+=("${profile} ${version} FAIL")
        local_failed=1
    fi
done

print 'Audiobookshelf compatibility'
print -- '----------------------------'
printf '%s\n' "${results[@]}"
exit "${local_failed}"
