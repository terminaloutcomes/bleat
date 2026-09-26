#!/bin/zsh

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
    print -u2 "Usage: ${0:t} BUILD_NUMBER"
    exit 64
fi

readonly bleat_build_number="$1"

if [[ -n "${BLEAT_MARKETING_VERSION:-}" ]]; then
    readonly bleat_marketing_version="${BLEAT_MARKETING_VERSION}"
elif [[ "${bleat_build_number}" =~ ^[0-9]{8}[.][0-9]{4}[.][0-9]{2}$ ]]; then
    readonly bleat_marketing_version="${bleat_build_number[1,4]}.${bleat_build_number[5,6]}.${bleat_build_number[7,8]}"
else
    print -u2 "BLEAT_MARKETING_VERSION is required when BLEAT_BUILD_NUMBER is not a UTC timestamp"
    exit 65
fi

if [[ ! "${bleat_marketing_version}" =~ ^[0-9]{4}[.][0-9]{2}[.][0-9]{2}$ ]]; then
    print -u2 "BLEAT_MARKETING_VERSION must use YYYY.MM.DD"
    exit 66
fi

readonly bleat_compact_date="${bleat_marketing_version//./}"
if bleat_normalized_date="$(date -j -f '%Y%m%d' "${bleat_compact_date}" '+%Y.%m.%d' 2>/dev/null)"; then
    :
elif bleat_normalized_date="$(date -d "${bleat_marketing_version//./-}" '+%Y.%m.%d' 2>/dev/null)"; then
    :
else
    bleat_normalized_date=""
fi
readonly bleat_normalized_date
if [[ "${bleat_normalized_date}" != "${bleat_marketing_version}" ]]; then
    print -u2 "BLEAT_MARKETING_VERSION must contain a valid calendar date"
    exit 67
fi

print -r -- "${bleat_marketing_version}"
