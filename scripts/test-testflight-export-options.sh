#!/bin/zsh

set -euo pipefail

readonly bleat_script_dir="${0:A:h}"
readonly bleat_test_directory="$(mktemp -d "${TMPDIR:-/tmp}/bleat-testflight-options.XXXXXX")"
trap 'rm -rf "${bleat_test_directory}"' EXIT

readonly bleat_options_path="${bleat_test_directory}/ExportOptions.plist"
"${bleat_script_dir}/create-testflight-export-options.sh" \
    "${bleat_options_path}" \
    ABCDE12345 \
    com.example.Bleat \
    upload

[[ "$(plutil -extract destination raw "${bleat_options_path}")" == upload ]]
[[ "$(plutil -extract distributionBundleIdentifier raw "${bleat_options_path}")" == com.example.Bleat ]]
[[ "$(plutil -extract manageAppVersionAndBuildNumber raw "${bleat_options_path}")" == false ]]
[[ "$(plutil -extract method raw "${bleat_options_path}")" == app-store-connect ]]
[[ "$(plutil -extract signingStyle raw "${bleat_options_path}")" == automatic ]]
[[ "$(plutil -extract teamID raw "${bleat_options_path}")" == ABCDE12345 ]]
[[ "$(plutil -extract testFlightInternalTestingOnly raw "${bleat_options_path}")" == true ]]
[[ "$(plutil -extract uploadSymbols raw "${bleat_options_path}")" == true ]]

readonly bleat_key_count="$(plutil -convert json -o - "${bleat_options_path}" | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))')"
[[ "${bleat_key_count}" == 8 ]]

if "${bleat_script_dir}/create-testflight-export-options.sh" \
    "${bleat_test_directory}/invalid-team.plist" \
    invalid \
    com.example.Bleat \
    upload >/dev/null 2>&1
then
    print -u2 "Invalid team identifier unexpectedly passed"
    exit 1
fi

if "${bleat_script_dir}/create-testflight-export-options.sh" \
    "${bleat_test_directory}/invalid-bundle.plist" \
    ABCDE12345 \
    'com.example.$(id)' \
    upload >/dev/null 2>&1
then
    print -u2 "Invalid bundle identifier unexpectedly passed"
    exit 1
fi

readonly bleat_local_options_path="${bleat_test_directory}/LocalExportOptions.plist"
"${bleat_script_dir}/create-testflight-export-options.sh" \
    "${bleat_local_options_path}" \
    ABCDE12345 \
    com.example.Bleat \
    export
[[ "$(plutil -extract destination raw "${bleat_local_options_path}")" == export ]]

if "${bleat_script_dir}/create-testflight-export-options.sh" \
    "${bleat_test_directory}/invalid-destination.plist" \
    ABCDE12345 \
    com.example.Bleat \
    invalid >/dev/null 2>&1
then
    print -u2 "Invalid export destination unexpectedly passed"
    exit 1
fi

print "TestFlight export-options validation passed."
