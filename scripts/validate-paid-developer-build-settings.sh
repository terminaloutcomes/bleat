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

case "${BLEAT_CARPLAY_MODE:-}" in
  enabled | disabled) ;;
  *)
    echo "BLEAT_CARPLAY_MODE must be enabled or disabled" >&2
    exit 2
    ;;
esac

telemetry_url_scheme=""
telemetry_url_host=""

parse_telemetry_url() {
  local value="$1"
  local requires_origin="$2"
  local remainder authority path port

  telemetry_url_scheme=""
  telemetry_url_host=""
  case "${value}" in
    https://*) telemetry_url_scheme="https"; remainder="${value#https://}" ;;
    http://*) telemetry_url_scheme="http"; remainder="${value#http://}" ;;
    *) return 1 ;;
  esac
  [[ "${remainder}" != *[@\?\#]* ]] || return 1

  if [[ "${remainder}" == */* ]]; then
    authority="${remainder%%/*}"
    path="/${remainder#*/}"
  else
    authority="${remainder}"
    path=""
  fi
  [[ -n "${authority}" ]] || return 1
  if [[ "${requires_origin}" == true && -n "${path}" && "${path}" != / ]]; then
    return 1
  fi

  if [[ "${authority}" =~ ^\[([0-9A-Fa-f:.]+)\](:([0-9]+))?$ ]]; then
    telemetry_url_host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[3]:-}"
  elif [[ "${authority}" =~ ^([A-Za-z0-9.-]+)(:([0-9]+))?$ ]]; then
    telemetry_url_host="$(printf '%s\n' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
    port="${BASH_REMATCH[3]:-}"
  else
    return 1
  fi
  if [[ -n "${port}" && ( 10#${port} < 1 || 10#${port} > 65535 ) ]]; then
    return 1
  fi
}

case "${PLATFORM_NAME:-}" in
  iphoneos | iphonesimulator)
    if ! parse_telemetry_url "${BLEAT_TELEMETRY_AUTH_BASE_URL:-}" false; then
      echo "BLEAT_TELEMETRY_AUTH_BASE_URL must be a valid telemetry base URL" >&2
      exit 2
    fi
    case "${telemetry_url_scheme}" in
      https) ;;
      http)
        if [[ "${CONFIGURATION:-}" != Debug || ( "${telemetry_url_host}" != localhost && "${telemetry_url_host}" != 127.0.0.1 && "${telemetry_url_host}" != ::1 ) ]]; then
          echo "BLEAT_TELEMETRY_AUTH_BASE_URL must be HTTPS or Debug loopback HTTP" >&2
          exit 2
        fi
        ;;
      *) exit 2 ;;
    esac

    if ! parse_telemetry_url "${BLEAT_TELEMETRY_OTLP_ENDPOINT:-}" true \
      || [[ "${telemetry_url_scheme}" != https ]]; then
      echo "BLEAT_TELEMETRY_OTLP_ENDPOINT must be a valid HTTPS origin for iOS builds" >&2
      exit 2
    fi
    ;;
esac
