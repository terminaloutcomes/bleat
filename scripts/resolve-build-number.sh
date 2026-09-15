#!/bin/zsh

set -euo pipefail

if [[ "$#" -ne 0 ]]; then
    print -u2 "Usage: ${0:t}"
    exit 64
fi

readonly bleat_build_number="${BLEAT_BUILD_NUMBER:-$(date -u '+%Y%m%d.%H%M.%S')}"

if [[ ! "${bleat_build_number}" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
    print -u2 "BLEAT_BUILD_NUMBER must contain one to three dot-separated integers"
    exit 64
fi

print -r -- "${bleat_build_number}"
