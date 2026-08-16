#!/usr/bin/env zsh
set -euo pipefail

readonly project_name="bleat-api-test-$$"
readonly compose_file="bleat-api/compose.yml"
export BLEAT_API_TEST_PORT="$((20000 + RANDOM % 20000))"

cleanup() {
  docker compose --project-name "${project_name}" --file "${compose_file}" \
    down --volumes --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker compose --project-name "${project_name}" --file "${compose_file}" \
  up --build --abort-on-container-exit --exit-code-from tests tests

docker compose --project-name "${project_name}" --file "${compose_file}" \
  up --detach --build api

for _ in {1..30}; do
  if curl --silent --fail "http://127.0.0.1:${BLEAT_API_TEST_PORT}/readyz" >/dev/null; then
    break
  fi
  sleep 1
done

curl --silent --fail "http://127.0.0.1:${BLEAT_API_TEST_PORT}/healthz" >/dev/null
curl --silent --fail "http://127.0.0.1:${BLEAT_API_TEST_PORT}/readyz" >/dev/null

BLEAT_TELEMETRY_AUTH_BASE_URL="http://127.0.0.1:${BLEAT_API_TEST_PORT}" \
  swift test --filter TelemetryAuthenticationLiveTests

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
