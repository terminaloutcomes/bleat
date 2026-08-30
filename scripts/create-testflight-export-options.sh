#!/bin/zsh

set -euo pipefail

if [[ "$#" -ne 4 ]]; then
    print -u2 "usage: $0 OUTPUT_PATH DEVELOPMENT_TEAM BUNDLE_ID DESTINATION"
    exit 64
fi

readonly bleat_output_path="$1"
readonly bleat_development_team="$2"
readonly bleat_bundle_id="$3"
readonly bleat_destination="$4"

if [[ ! "${bleat_development_team}" =~ ^[A-Z0-9]{10}$ ]]; then
    print -u2 "Development team must be a ten-character Apple team identifier"
    exit 64
fi
if [[ ! "${bleat_bundle_id}" =~ ^[A-Za-z0-9.-]+$ ]]; then
    print -u2 "Bundle identifier contains unsupported characters"
    exit 64
fi
if [[ "${bleat_destination}" != export && "${bleat_destination}" != upload ]]; then
    print -u2 "Destination must be export or upload"
    exit 64
fi

mkdir -p "${bleat_output_path:h}"
plutil -create xml1 "${bleat_output_path}"
plutil -insert destination -string "${bleat_destination}" "${bleat_output_path}"
plutil -insert distributionBundleIdentifier -string "${bleat_bundle_id}" "${bleat_output_path}"
plutil -insert manageAppVersionAndBuildNumber -bool NO "${bleat_output_path}"
plutil -insert method -string app-store-connect "${bleat_output_path}"
plutil -insert signingStyle -string automatic "${bleat_output_path}"
plutil -insert teamID -string "${bleat_development_team}" "${bleat_output_path}"
plutil -insert testFlightInternalTestingOnly -bool YES "${bleat_output_path}"
plutil -insert uploadSymbols -bool YES "${bleat_output_path}"
plutil -lint "${bleat_output_path}"
