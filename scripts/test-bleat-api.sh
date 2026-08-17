#!/usr/bin/env zsh
set -euo pipefail

readonly project_name="bleat-api-test-$$"
readonly compose_file="bleat-api/compose.yml"
export BLEAT_API_TEST_PORT="$((20000 + RANDOM % 20000))"
readonly telemetry_tls_ca="$(mktemp /tmp/bleat-telemetry-ca.XXXXXX)"
readonly telemetry_tls_cert="$(mktemp /tmp/bleat-telemetry-cert.XXXXXX)"
readonly telemetry_tls_intermediate="$(mktemp /tmp/bleat-telemetry-intermediate.XXXXXX)"
readonly telemetry_tls_key="$(mktemp /tmp/bleat-telemetry-key.XXXXXX)"

cleanup() {
  docker compose --project-name "${project_name}" --file "${compose_file}" \
    down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -f \
    "${telemetry_tls_ca}" \
    "${telemetry_tls_cert}" \
    "${telemetry_tls_intermediate}" \
    "${telemetry_tls_key}"
}
trap cleanup EXIT INT TERM

docker compose --project-name "${project_name}" --file "${compose_file}" \
  up --build --abort-on-container-exit --exit-code-from tests tests

docker compose --project-name "${project_name}" --file "${compose_file}" \
  up --detach --build --wait api tls-fixture

# Caddy writes the leaf and private key independently after the storage paths
# first appear. Let that one-time issuance settle before copying the pair.
sleep 2

for _ in {1..30}; do
  if curl --silent --fail "http://127.0.0.1:${BLEAT_API_TEST_PORT}/readyz" >/dev/null; then
    break
  fi
  sleep 1
done

curl --silent --fail "http://127.0.0.1:${BLEAT_API_TEST_PORT}/healthz" >/dev/null
curl --silent --fail "http://127.0.0.1:${BLEAT_API_TEST_PORT}/readyz" >/dev/null

docker compose --project-name "${project_name}" --file "${compose_file}" \
  cp tls-fixture:/data/caddy/pki/authorities/local/root.crt "${telemetry_tls_ca}"
docker compose --project-name "${project_name}" --file "${compose_file}" \
  cp tls-fixture:/data/caddy/certificates/local/localhost/localhost.crt \
  "${telemetry_tls_cert}"
docker compose --project-name "${project_name}" --file "${compose_file}" \
  cp tls-fixture:/data/caddy/pki/authorities/local/intermediate.crt \
  "${telemetry_tls_intermediate}"
docker compose --project-name "${project_name}" --file "${compose_file}" \
  cp tls-fixture:/data/caddy/certificates/local/localhost/localhost.key \
  "${telemetry_tls_key}"

BLEAT_TELEMETRY_AUTH_BASE_URL="http://127.0.0.1:${BLEAT_API_TEST_PORT}" \
  swift test --filter TelemetryAuthenticationLiveTests

BLEAT_TELEMETRY_AUTH_BASE_URL="http://127.0.0.1:${BLEAT_API_TEST_PORT}" \
BLEAT_TELEMETRY_TLS_CA_CERT="${telemetry_tls_ca}" \
BLEAT_TELEMETRY_TLS_CERT="${telemetry_tls_cert}" \
BLEAT_TELEMETRY_TLS_INTERMEDIATE_CERT="${telemetry_tls_intermediate}" \
BLEAT_TELEMETRY_TLS_KEY="${telemetry_tls_key}" \
  swift test --filter AuthenticatedOtlpSpanExporterLiveTests

readonly challenge_response="$(
  curl --silent --fail-with-body \
    --header 'content-type: application/json' \
    --data '{}' \
    "http://127.0.0.1:${BLEAT_API_TEST_PORT}/v1/attestation/challenge"
)"
jq -e '
  (.challenge_id | type == "string") and
  (.challenge | type == "string" and length == 43) and
  (.expires_at | type == "string")
' >/dev/null <<<"${challenge_response}"

readonly runtime_image="$(
  docker compose --project-name "${project_name}" --file "${compose_file}" images --quiet api
)"
readonly runtime_user="$(
  docker image inspect --format '{{.Config.User}}' "${runtime_image}"
)"
if [[ -z "${runtime_user}" || "${runtime_user}" == "0" || "${runtime_user}" == "root" ]]; then
  print -u2 "bleat-api runtime container must not run as root"
  exit 1
fi
