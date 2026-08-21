#!/usr/bin/env zsh
set -euo pipefail

readonly project_name="bleat-api-test-$$"
readonly compose_file="bleat-api/compose.yml"
readonly port_base="$((20000 + RANDOM % 19990))"
export BLEAT_API_TEST_PORT="${port_base}"
export BLEAT_API_PUBLIC_ISSUER="http://host.docker.internal:${BLEAT_API_TEST_PORT}"
export BLEAT_TELEMETRY_COLLECTOR_TEST_PORT="$((port_base + 1))"
export BLEAT_TELEMETRY_COLLECTOR_HEALTH_TEST_PORT="$((port_base + 2))"
export BLEAT_TELEMETRY_OUTAGE_COLLECTOR_TEST_PORT="$((port_base + 3))"
export BLEAT_TELEMETRY_OUTAGE_COLLECTOR_HEALTH_TEST_PORT="$((port_base + 4))"
export BLEAT_TELEMETRY_OUTAGE_COLLECTOR_METRICS_TEST_PORT="$((port_base + 5))"
export BLEAT_TELEMETRY_CAPTURE_DIRECTORY="$(
  mktemp -d /tmp/bleat-telemetry-capture.XXXXXX
)"
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
  case "${BLEAT_TELEMETRY_CAPTURE_DIRECTORY}" in
    /tmp/bleat-telemetry-capture.*)
      rm -rf "${BLEAT_TELEMETRY_CAPTURE_DIRECTORY}"
      ;;
  esac
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
  run --rm --no-deps telemetry-collector validate --config=/etc/otelcol/config.yaml
docker compose --project-name "${project_name}" --file "${compose_file}" \
  run --rm --no-deps telemetry-capture validate --config=/etc/otelcol/config.yaml
docker compose --project-name "${project_name}" --file "${compose_file}" \
  up --detach telemetry-capture telemetry-collector telemetry-collector-outage

for _ in {1..30}; do
  if curl --silent --fail \
    "http://127.0.0.1:${BLEAT_TELEMETRY_COLLECTOR_HEALTH_TEST_PORT}/" \
    >/dev/null; then
    break
  fi
  sleep 1
done

curl --silent --fail \
  "http://127.0.0.1:${BLEAT_TELEMETRY_COLLECTOR_HEALTH_TEST_PORT}/" \
  >/dev/null

for _ in {1..30}; do
  if curl --silent --fail \
    "http://127.0.0.1:${BLEAT_TELEMETRY_OUTAGE_COLLECTOR_HEALTH_TEST_PORT}/" \
    >/dev/null; then
    break
  fi
  sleep 1
done

curl --silent --fail \
  "http://127.0.0.1:${BLEAT_TELEMETRY_OUTAGE_COLLECTOR_HEALTH_TEST_PORT}/" \
  >/dev/null

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

BLEAT_TELEMETRY_AUTH_BASE_URL="http://127.0.0.1:${BLEAT_API_TEST_PORT}" \
BLEAT_TELEMETRY_COLLECTOR_TEST_PORT="${BLEAT_TELEMETRY_COLLECTOR_TEST_PORT}" \
BLEAT_TELEMETRY_OUTAGE_COLLECTOR_TEST_PORT="${BLEAT_TELEMETRY_OUTAGE_COLLECTOR_TEST_PORT}" \
  swift test --filter OpenTelemetryCollectorLiveTests

# Receiver success only proves that the outage Collector queued the batch. Wait
# beyond the exporter's ten-second retry budget and require its stock internal
# metric to record the batch as permanently failed.
outage_metrics=""
for _ in {1..30}; do
  outage_metrics="$(
    curl --silent --fail \
      "http://127.0.0.1:${BLEAT_TELEMETRY_OUTAGE_COLLECTOR_METRICS_TEST_PORT}/metrics"
  )"
  if awk '
    /^otelcol_exporter_send_failed_spans([{ ]|$)/ && $NF + 0 >= 1 { found = 1 }
    END { exit !found }
  ' <<<"${outage_metrics}"; then
    break
  fi
  sleep 1
done

awk '
  /^otelcol_exporter_send_failed_spans([{ ]|$)/ && $NF + 0 >= 1 { found = 1 }
  END { exit !found }
' <<<"${outage_metrics}"

for _ in {1..30}; do
  if [[ -s "${BLEAT_TELEMETRY_CAPTURE_DIRECTORY}/traces.json" \
    && -s "${BLEAT_TELEMETRY_CAPTURE_DIRECTORY}/logs.json" ]]; then
    break
  fi
  sleep 1
done

readonly captured_telemetry="${BLEAT_TELEMETRY_CAPTURE_DIRECTORY}/traces.json"
readonly captured_logs="${BLEAT_TELEMETRY_CAPTURE_DIRECTORY}/logs.json"
test -s "${captured_telemetry}"
test -s "${captured_logs}"
jq --slurp -e '
  .. | objects
  | select(has("name") and .name == "bleat.app.launch")
' "${captured_telemetry}" >/dev/null
jq --slurp -e '
  .. | objects
  | select(
      has("eventName")
      and .eventName == "bleat.cloudkit.sync.failed"
    )
' "${captured_logs}" >/dev/null
if rg -i 'authorization|bearer|telemetry:write|installation' \
  "${captured_telemetry}" "${captured_logs}"; then
  print -u2 "captured telemetry contains authentication data"
  exit 1
fi

curl --silent --fail \
  "http://127.0.0.1:${BLEAT_TELEMETRY_COLLECTOR_HEALTH_TEST_PORT}/" \
  >/dev/null
curl --silent --fail \
  "http://127.0.0.1:${BLEAT_TELEMETRY_OUTAGE_COLLECTOR_HEALTH_TEST_PORT}/" \
  >/dev/null

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
