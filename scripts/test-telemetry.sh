#!/usr/bin/env zsh
set -euo pipefail

readonly project_name="bleat-telemetry-test-$$"
readonly compose_file="bleat-api/compose.yml"
readonly port_base="$((20000 + RANDOM % 19990))"
readonly artifact_root="TestSupport/ServerHarness/artifacts/telemetry"
readonly temporary_capture="$(mktemp -d /tmp/bleat-telemetry-capture.XXXXXX)"
readonly database_password="test-${project_name}-${RANDOM}"
readonly telemetry_tls_ca="$(mktemp /tmp/bleat-telemetry-ca.XXXXXX)"
readonly telemetry_tls_cert="$(mktemp /tmp/bleat-telemetry-cert.XXXXXX)"
readonly telemetry_tls_intermediate="$(mktemp /tmp/bleat-telemetry-intermediate.XXXXXX)"
readonly telemetry_tls_key="$(mktemp /tmp/bleat-telemetry-key.XXXXXX)"
test_succeeded=0

export BLEAT_API_TEST_PORT="${port_base}"
export BLEAT_API_POSTGRES_PASSWORD="${database_password}"
export BLEAT_API_PUBLIC_ISSUER="http://host.docker.internal:${BLEAT_API_TEST_PORT}"
export BLEAT_TELEMETRY_COLLECTOR_TEST_PORT="$((port_base + 1))"
export BLEAT_TELEMETRY_COLLECTOR_HEALTH_TEST_PORT="$((port_base + 2))"
export BLEAT_TELEMETRY_OUTAGE_COLLECTOR_TEST_PORT="$((port_base + 3))"
export BLEAT_TELEMETRY_OUTAGE_COLLECTOR_HEALTH_TEST_PORT="$((port_base + 4))"
export BLEAT_TELEMETRY_OUTAGE_COLLECTOR_METRICS_TEST_PORT="$((port_base + 5))"
export BLEAT_TELEMETRY_CAPTURE_DIRECTORY="${temporary_capture}"

cleanup() {
  local exit_status=$?
  trap - EXIT INT TERM
  if [[ "${test_succeeded}" != "1" ]]; then
    mkdir -p "${artifact_root}"
    docker compose --project-name "${project_name}" --file "${compose_file}" \
      logs --no-color 2>&1 \
      | sed -E \
        -e 's#(postgres(ql)?://[^:[:space:]]+:)[^@[:space:]]+#\1[REDACTED]#g' \
        -e 's#(authorization: bearer )[A-Za-z0-9._-]+#\1[REDACTED]#Ig' \
        -e 's#eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+#[REDACTED_JWT]#g' \
        >"${artifact_root}/containers.log" || true
    if [[ -d "${temporary_capture}" ]]; then
      for capture in "${temporary_capture}"/*.json(N); do
        jq --compact-output \
          'walk(if type == "string" then "[REDACTED]" else . end)' \
          "${capture}" \
          >"${artifact_root}/${capture:t:r}.structure.json" || true
      done
    fi
    print -u2 "Telemetry failure artifacts retained in ${artifact_root}"
  fi
  docker compose --project-name "${project_name}" --file "${compose_file}" \
    down --volumes --remove-orphans >/dev/null 2>&1 || exit_status=1
  if [[ -n "$(docker ps --all --quiet \
    --filter "label=com.docker.compose.project=${project_name}")" ]]; then
    print -u2 "Disposable telemetry containers remain after cleanup"
    exit_status=1
  fi
  rm -f \
    "${telemetry_tls_ca}" \
    "${telemetry_tls_cert}" \
    "${telemetry_tls_intermediate}" \
    "${telemetry_tls_key}"
  case "${temporary_capture}" in
    /tmp/bleat-telemetry-capture.*) rm -rf "${temporary_capture}" ;;
  esac
  return "${exit_status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for production_key_variable in \
  BLEAT_API_JWT_SIGNING_KEY_FILE \
  BLEAT_API_JWT_PUBLIC_KEY_SET_FILE; do
  if (( ${+parameters[$production_key_variable]} )) \
    && [[ -n "${(P)production_key_variable}" ]]; then
    print -u2 "${production_key_variable} must not be supplied to the disposable telemetry gate"
    exit 1
  fi
done

docker compose --project-name "${project_name}" --file "${compose_file}" \
  up --detach --build --wait api tls-fixture

# Caddy writes the leaf and key independently after their storage paths appear.
sleep 2

curl --silent --fail "http://127.0.0.1:${BLEAT_API_TEST_PORT}/healthz" >/dev/null
curl --silent --fail "http://127.0.0.1:${BLEAT_API_TEST_PORT}/readyz" >/dev/null

docker compose --project-name "${project_name}" --file "${compose_file}" \
  run --rm --no-deps telemetry-collector validate --config=/etc/otelcol/config.yaml
docker compose --project-name "${project_name}" --file "${compose_file}" \
  run --rm --no-deps telemetry-capture validate --config=/etc/otelcol/config.yaml
docker compose --project-name "${project_name}" --file "${compose_file}" \
  up --detach telemetry-capture telemetry-collector telemetry-collector-outage

for health_port in \
  "${BLEAT_TELEMETRY_COLLECTOR_HEALTH_TEST_PORT}" \
  "${BLEAT_TELEMETRY_OUTAGE_COLLECTOR_HEALTH_TEST_PORT}"; do
  for _ in {1..30}; do
    curl --silent --fail "http://127.0.0.1:${health_port}/" >/dev/null && break
    sleep 1
  done
  curl --silent --fail "http://127.0.0.1:${health_port}/" >/dev/null
done

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

# Receiver success proves only queue admission. Require bounded retry exhaustion.
outage_metrics=""
for _ in {1..30}; do
  outage_metrics="$(curl --silent --fail \
    "http://127.0.0.1:${BLEAT_TELEMETRY_OUTAGE_COLLECTOR_METRICS_TEST_PORT}/metrics")"
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
  [[ -s "${temporary_capture}/traces.json" \
    && -s "${temporary_capture}/logs.json" ]] && break
  sleep 1
done
readonly captured_traces="${temporary_capture}/traces.json"
readonly captured_logs="${temporary_capture}/logs.json"
test -s "${captured_traces}"
test -s "${captured_logs}"

jq --slurp -e '
  ([.. | objects | select(.name? == "bleat.app.launch")] | length) >= 1
  and ([.. | objects | select(.key? == "service.name" and .value.stringValue? == "bleat")] | length) >= 1
  and ([.. | objects | select(.key? == "service.version" and .value.stringValue? == "1.2.3")] | length) >= 1
  and ([.. | objects | select(.key? == "bleat.app.build" and .value.stringValue? == "68")] | length) >= 1
  and ([.. | objects | select(.key? == "os.type" and .value.stringValue? == "ios")] | length) >= 1
  and ([.. | objects | select(.key? == "bleat.outcome" and .value.stringValue? == "succeeded")] | length) >= 1
  and ([.. | objects | select(.key? == "bleat.source" and .value.stringValue? == "offline")] | length) >= 1
  and ([.. | objects | select(.key? == "bleat.retry.bucket" and .value.stringValue? == "one")] | length) >= 1
' "${captured_traces}" >/dev/null
jq --slurp -e '
  [.. | objects | select(.eventName? == "bleat.cloudkit.sync.failed")] | length >= 1
' "${captured_logs}" >/dev/null

readonly prohibited_pattern='authorization|bearer|telemetry:write|installation|reader@example\.com|books\.example|secret audiobook|refresh-token|private/var|transcript words|search phrase|session/opaque'
if rg -i "${prohibited_pattern}" "${captured_traces}" "${captured_logs}"; then
  print -u2 "captured telemetry contains prohibited data"
  exit 1
fi

readonly runtime_image="$(docker compose --project-name "${project_name}" \
  --file "${compose_file}" images --quiet api)"
readonly runtime_user="$(docker image inspect --format '{{.Config.User}}' "${runtime_image}")"
if [[ -z "${runtime_user}" || "${runtime_user}" == "0" || "${runtime_user}" == "root" ]]; then
  print -u2 "bleat-api runtime container must not run as root"
  exit 1
fi

test_succeeded=1
rm -rf "${artifact_root}"
