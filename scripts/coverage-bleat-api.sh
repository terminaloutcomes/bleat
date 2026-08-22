#!/usr/bin/env zsh
set -euo pipefail

readonly output_directory="../.build/coverage/bleat-api"
readonly report=".build/coverage/bleat-api/tarpaulin-report.json"
readonly overall_coverage_warning_threshold="80"

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
  -- \
  --test-threads=4

readonly overall_covered="$(jq -er '.covered' "${report}")"
readonly overall_coverable="$(jq -er '.coverable' "${report}")"
readonly overall_coverage="$(jq -er '.coverage' "${report}")"

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

print "Overall coverage: ${overall_coverage}% (${overall_covered}/${overall_coverable})"
print "App Attest coverage: ${app_attest_coverage}% (${app_attest_covered}/${app_attest_coverable})"

if awk -v coverage="${overall_coverage}" \
  -v threshold="${overall_coverage_warning_threshold}" \
  'BEGIN { exit !(coverage < threshold) }'; then
  print -u2 \
    "warning: overall coverage ${overall_coverage}% is below ${overall_coverage_warning_threshold}%"
fi
