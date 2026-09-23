#!/bin/zsh

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
readonly bleat_resolver="${bleat_script_dir}/resolve-marketing-version.sh"

readonly bleat_timestamp_build="20260923.0642.54"
if [[ "$("${bleat_resolver}" "${bleat_timestamp_build}")" != "2026.09.23" ]]; then
    print -u2 "Marketing version was not derived from the UTC build date"
    exit 1
fi

readonly bleat_override="2026.09.24"
if [[ "$(BLEAT_MARKETING_VERSION="${bleat_override}" "${bleat_resolver}" 7)" != "${bleat_override}" ]]; then
    print -u2 "Explicit marketing-version override was not preserved"
    exit 1
fi

typeset bleat_invalid_version bleat_expected_status bleat_actual_status
for bleat_invalid_version bleat_expected_status in \
    "2026.9.23" 66 \
    "2026.02.30" 67 \
    "release-2026.09.23" 66
do
    if BLEAT_MARKETING_VERSION="${bleat_invalid_version}" \
        "${bleat_resolver}" "${bleat_timestamp_build}" >/dev/null 2>&1
    then
        print -u2 "Invalid marketing version unexpectedly passed: ${bleat_invalid_version}"
        exit 1
    else
        bleat_actual_status="$?"
    fi
    if [[ "${bleat_actual_status}" -ne "${bleat_expected_status}" ]]; then
        print -u2 "Invalid marketing version returned ${bleat_actual_status}, expected ${bleat_expected_status}"
        exit 1
    fi
done

if "${bleat_resolver}" 7 >/dev/null 2>&1; then
    print -u2 "Custom build number passed without an explicit marketing version"
    exit 1
else
    bleat_actual_status="$?"
fi
if [[ "${bleat_actual_status}" -ne 65 ]]; then
    print -u2 "Missing marketing version returned ${bleat_actual_status}, expected 65"
    exit 1
fi

print "Marketing-version derivation and override validation passed."
