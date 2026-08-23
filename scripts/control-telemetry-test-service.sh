#!/usr/bin/env zsh
set -euo pipefail

readonly project_name="${1:-}"
readonly action="${2:-}"
readonly service="${3:-}"
readonly compose_file="bleat-api/compose.yml"

if [[ ! "${project_name}" =~ '^bleat-telemetry-test-[0-9]+$' ]]; then
  print -u2 "Refusing to control a non-disposable Compose project"
  exit 2
fi

case "${service}" in
  api | telemetry-collector) ;;
  *)
    print -u2 "Unsupported disposable telemetry service"
    exit 2
    ;;
esac

case "${action}" in
  stop)
    docker compose --project-name "${project_name}" --file "${compose_file}" \
      stop --timeout 10 "${service}"
    ;;
  start)
    docker compose --project-name "${project_name}" --file "${compose_file}" \
      up --detach "${service}"
    case "${service}" in
      api)
        readonly health_port="${BLEAT_API_TEST_PORT:?}"
        ;;
      telemetry-collector)
        readonly health_port="${BLEAT_TELEMETRY_COLLECTOR_HEALTH_TEST_PORT:?}"
        ;;
    esac
    for _ in {1..30}; do
      if curl --silent --fail \
        "http://127.0.0.1:${health_port}/healthz" >/dev/null 2>&1 \
        || curl --silent --fail \
          "http://127.0.0.1:${health_port}/" >/dev/null 2>&1; then
        exit 0
      fi
      sleep 1
    done
    print -u2 "Disposable telemetry service did not become healthy"
    exit 1
    ;;
  *)
    print -u2 "Unsupported disposable telemetry service action"
    exit 2
    ;;
esac
