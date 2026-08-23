#!/usr/bin/env zsh
set -euo pipefail

readonly project_name="bleat-telemetry-test-$$"
readonly compose_file="bleat-api/compose.yml"
readonly port_base="$((20000 + RANDOM % 19990))"
readonly artifact_root="TestSupport/ServerHarness/artifacts/telemetry"
readonly temporary_capture="$(mktemp -d /tmp/bleat-telemetry-capture.XXXXXX)"
readonly database_password="test-${project_name}-${RANDOM}"
readonly captured_data_prohibited_pattern='authorization|bearer|telemetry:write|installation|reader@example\.com|books\.example|secret audiobook|refresh-token|private/var|transcript words|search phrase|session/opaque'
readonly retained_secret_pattern='postgres(ql)?://[^:[:space:]]+:[^@[:space:]]+@|authorization: bearer [A-Za-z0-9._-]{8,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'
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
    if [[ -d "${artifact_root}" ]] \
      && rg --quiet -i "${retained_secret_pattern}" "${artifact_root}"; then
      print -u2 "Unsafe telemetry failure artifacts were removed"
      rm -rf "${artifact_root}"
      exit_status=1
    else
      print -u2 "Telemetry failure artifacts retained in ${artifact_root}"
    fi
  fi
  docker compose --project-name "${project_name}" --file "${compose_file}" \
    down --volumes --remove-orphans >/dev/null 2>&1 || exit_status=1
  if [[ -n "$(docker ps --all --quiet \
    --filter "label=com.docker.compose.project=${project_name}")" ]]; then
    print -u2 "Disposable telemetry containers remain after cleanup"
    exit_status=1
  fi
  if [[ -n "$(docker volume ls --quiet \
    --filter "label=com.docker.compose.project=${project_name}")" ]]; then
    print -u2 "Disposable telemetry volumes remain after cleanup"
    exit_status=1
  fi
  case "${temporary_capture}" in
    /tmp/bleat-telemetry-capture.*) rm -rf "${temporary_capture}" ;;
  esac
  if [[ -e "${temporary_capture}" ]]; then
    print -u2 "Unredacted telemetry capture remains after cleanup"
    exit_status=1
  fi
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

for test_suite in \
  TelemetryAuthenticationTests \
  AuthenticatedOtlpSpanExporterTests \
  RemoteTelemetryTests; do
  swift test --filter "${test_suite}"
done

./scripts/test-bleat-api.sh

docker compose --project-name "${project_name}" --file "${compose_file}" \
  up --detach --build --wait api

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

BLEAT_TELEMETRY_AUTH_BASE_URL="http://127.0.0.1:${BLEAT_API_TEST_PORT}" \
  swift test --filter TelemetryAuthenticationLiveTests

BLEAT_TELEMETRY_AUTH_BASE_URL="http://127.0.0.1:${BLEAT_API_TEST_PORT}" \
BLEAT_TELEMETRY_COLLECTOR_TEST_PORT="${BLEAT_TELEMETRY_COLLECTOR_TEST_PORT}" \
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

if rg --quiet -i "${captured_data_prohibited_pattern}" "${captured_traces}" "${captured_logs}"; then
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

rm -rf "${artifact_root}"
test_succeeded=1
