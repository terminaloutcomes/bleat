#!/usr/bin/env zsh
set -euo pipefail

: "${BLEAT_IPAD_ID:?Set BLEAT_IPAD_ID to the connected iPad UDID}"
readonly bleat_bundle_id="${BLEAT_BUNDLE_ID:?Set BLEAT_BUNDLE_ID to the bundle identifier for the app}"

xcrun devicectl device process launch \
  --device "${BLEAT_IPAD_ID}" \
  --terminate-existing \
  "${bleat_bundle_id}"