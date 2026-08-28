#!/usr/bin/env bash

set -euo pipefail

: "${BLEAT_IPHONE_ID:?Set BLEAT_IPHONE_ID to the connected iPhone UDID}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to identify the Bleat process" >&2
  exit 1
fi

process_listing="$(mktemp "${TMPDIR:-/tmp}/bleat-iphone-processes.XXXXXX")"
readonly process_listing
trap 'rm -f "${process_listing}"' EXIT

xcrun devicectl device info processes \
  --device "${BLEAT_IPHONE_ID}" \
  --json-output "${process_listing}" \
  --quiet

bleat_process_ids=()
while IFS= read -r process_id; do
  bleat_process_ids+=("${process_id}")
done < <(
  jq -r '
    ..
    | objects
    | select((.executable? // "") | endswith("/Bleat.app/Bleat"))
    | .processIdentifier
  ' "${process_listing}"
)

if [[ "${#bleat_process_ids[@]}" -eq 0 ]]; then
  echo "Bleat is not running on the configured iPhone" >&2
  exit 1
fi

if [[ "${#bleat_process_ids[@]}" -ne 1 ]]; then
  echo "Refusing to terminate ${#bleat_process_ids[@]} matching Bleat processes" >&2
  exit 1
fi

readonly bleat_process_id="${bleat_process_ids[0]}"
if [[ ! "${bleat_process_id}" =~ ^[0-9]+$ ]]; then
  echo "devicectl returned an invalid Bleat process identifier" >&2
  exit 1
fi

xcrun devicectl device process terminate \
  --device "${BLEAT_IPHONE_ID}" \
  --pid "${bleat_process_id}" \
  --kill

echo "Terminated Bleat process ${bleat_process_id} on the configured iPhone"
