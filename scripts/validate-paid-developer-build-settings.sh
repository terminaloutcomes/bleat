#!/usr/bin/env bash

set -euo pipefail

case "${BUILD_WITHOUT_PAID_DEVELOPER:-}" in
  YES | NO) ;;
  *)
    echo "BUILD_WITHOUT_PAID_DEVELOPER must be YES or NO" >&2
    exit 2
    ;;
esac

case "${BLEAT_CLOUDKIT_MODE:-}" in
  enabled | disabled) ;;
  *)
    echo "BLEAT_CLOUDKIT_MODE must be enabled or disabled" >&2
    exit 2
    ;;
esac

case "${BLEAT_APP_ATTEST_MODE:-}" in
  enabled | disabled) ;;
  *)
    echo "BLEAT_APP_ATTEST_MODE must be enabled or disabled" >&2
    exit 2
    ;;
esac
