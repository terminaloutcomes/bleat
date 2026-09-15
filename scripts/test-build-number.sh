#!/bin/zsh

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
readonly bleat_resolver="${bleat_script_dir}/resolve-build-number.sh"

readonly bleat_utc_minute_before="$(date -u '+%Y%m%d.%H%M')"
readonly bleat_generated_build="$("${bleat_resolver}")"
readonly bleat_utc_minute_after="$(date -u '+%Y%m%d.%H%M')"
if [[ ! "${bleat_generated_build}" =~ ^[0-9]{8}[.][0-9]{4}[.][0-9]{2}$ ]]; then
    print -u2 "Generated build number does not use YYYYMMDD.HHmm.SS"
    exit 1
fi

if [[ "${bleat_generated_build%.*}" != "${bleat_utc_minute_before}" \
    && "${bleat_generated_build%.*}" != "${bleat_utc_minute_after}" ]]; then
    print -u2 "Generated build number is not from the current UTC minute"
    exit 1
fi

readonly bleat_override="20260915.1234.56"
if [[ "$(BLEAT_BUILD_NUMBER="${bleat_override}" "${bleat_resolver}")" != "${bleat_override}" ]]; then
    print -u2 "Explicit build-number override was not preserved"
    exit 1
fi

typeset bleat_invalid_build
for bleat_invalid_build in \
    "20260915.1234.56.7" \
    "20260915.123x.56" \
    "20260915..56"
do
    if BLEAT_BUILD_NUMBER="${bleat_invalid_build}" \
        "${bleat_resolver}" >/dev/null 2>&1
    then
        print -u2 "Invalid build number unexpectedly passed: ${bleat_invalid_build}"
        exit 1
    fi
done

print "Build-number generation and override validation passed."
