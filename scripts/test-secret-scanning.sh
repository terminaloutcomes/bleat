#!/usr/bin/env zsh

set -euo pipefail

repository_root="$(git rev-parse --show-toplevel)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/bleat-secret-scan.XXXXXX")"
trap 'rm -rf "${fixture_root}"' EXIT
cd "${repository_root}"

safe_root="${fixture_root}/safe"
unsafe_root="${fixture_root}/unsafe"
source_root="${fixture_root}/source"
report_path="${fixture_root}/findings.json"
mkdir -p "${safe_root}" "${unsafe_root}" "${source_root}"

cp \
  "${repository_root}/bleat-api/trust/Apple_App_Attestation_Root_CA.pem" \
  "${safe_root}/Apple_App_Attestation_Root_CA.pem"
printf '%s\n' \
  '{"keys":[{"kty":"EC","crv":"P-256","x":"public-x","y":"public-y"}]}' \
  > "${safe_root}/jwks.json"

gitleaks dir \
  --config "${repository_root}/.gitleaks.toml" \
  --no-banner \
  --redact \
  "${safe_root}"

printf '%s%s\nfixture\n%s%s\n' \
  '-----BEGIN ' 'PRIVATE KEY-----' \
  '-----END ' 'PRIVATE KEY-----' \
  > "${unsafe_root}/private.pem"
printf 'fixture\n' > "${unsafe_root}/AuthKey_TEST.p8"
printf 'fixture\n' > "${unsafe_root}/distribution.p12"
printf 'fixture\n' > "${unsafe_root}/Bleat.mobileprovision"
printf 'fixture\n' > "${unsafe_root}/telemetry-jwt-signing-key.der"

if gitleaks dir \
  --config "${repository_root}/.gitleaks.toml" \
  --no-banner \
  --redact \
  --report-format json \
  --report-path "${report_path}" \
  "${unsafe_root}"
then
  print -u2 "Secret-scanning fixtures unexpectedly passed"
  exit 1
fi

for rule_id in \
  private-key-block \
  apple-private-key-file \
  pkcs12-or-provisioning-file \
  telemetry-jwt-signing-key-file
do
  jq -e --arg rule_id "${rule_id}" \
    'any(.[]; .RuleID == $rule_id)' \
    "${report_path}" >/dev/null \
    || {
      print -u2 "Expected secret-scanning rule did not fire: ${rule_id}"
      exit 1
    }
done

git -C "${repository_root}" ls-files \
  --cached \
  --others \
  --exclude-standard \
  | while IFS= read -r source_path; do
      [[ -e "${repository_root}/${source_path}" ]] || continue
      print -r -- "${source_path}"
    done \
  | tar --files-from=- --create \
  | tar --directory "${source_root}" --extract

gitleaks dir \
  --config "${repository_root}/.gitleaks.toml" \
  --no-banner \
  --redact \
  "${source_root}"

print "Secret-scanning fixtures and current-source scan passed"
