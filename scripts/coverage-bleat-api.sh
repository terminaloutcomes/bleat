#!/usr/bin/env zsh
set -euo pipefail

readonly output_directory="../.build/coverage/bleat-api"
readonly report=".build/coverage/bleat-api/tarpaulin-report.json"
readonly minimum_overall_coverage="80"

mkdir -p ".build/coverage/bleat-api"
rm -f "${report}"

cargo tarpaulin \
  --locked \
  --manifest-path bleat-api/Cargo.toml \
  --all-features \
  --all-targets \
  --engine llvm \
  --out Json \
  --output-dir "${output_directory}" \
  --fail-under "${minimum_overall_coverage}" \
  -- \
  --test-threads=4

readonly app_attest_covered="$(
  jq -er '
    .files[]
    | select((.path | join("/")) | endswith("/src/app_attest.rs"))
    | .covered
  ' "${report}"
)"
readonly app_attest_coverable="$(
  jq -er '
    .files[]
    | select((.path | join("/")) | endswith("/src/app_attest.rs"))
    | .coverable
  ' "${report}"
)"
readonly app_attest_coverage="$(
  awk -v covered="${app_attest_covered}" -v coverable="${app_attest_coverable}" \
    'BEGIN { printf "%.2f", covered * 100 / coverable }'
)"

print "App Attest coverage: ${app_attest_coverage}% (${app_attest_covered}/${app_attest_coverable})"
