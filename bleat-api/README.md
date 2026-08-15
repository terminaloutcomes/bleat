# bleat-api

`bleat-api` is the Rust foundation for Bleat's anonymous telemetry
authentication service. This initial service exposes health/readiness checks and
reserved versioned authentication routes. Challenge validation, App Attest
verification, persistence, and token signing are not implemented yet.

## Run locally

From the repository root:

```sh
mise run api:run
```

The development defaults listen on `127.0.0.1:8080`. Check the service with:

```sh
curl --fail http://127.0.0.1:8080/healthz
curl --fail http://127.0.0.1:8080/readyz
```

Run every Rust validation gate with:

```sh
mise run api:validate
```

## Service configuration

Flags and matching environment variables configure the service:

| Flag | Environment variable | Development default |
| --- | --- | --- |
| `--bind-address` | `BLEAT_API_BIND_ADDRESS` | `127.0.0.1:8080` |
| `--public-issuer` | `BLEAT_API_PUBLIC_ISSUER` | `http://127.0.0.1:8080` |
| `--deployment-mode` | `BLEAT_API_DEPLOYMENT_MODE` | `development` |
| `--apple-team-id` | `BLEAT_API_APPLE_TEAM_ID` | unset |
| `--app-identifier` | `BLEAT_API_APP_IDENTIFIER` | unset |
| `--app-attest-environment` | `BLEAT_API_APP_ATTEST_ENVIRONMENT` | `development` |
| `--challenge-lifetime-seconds` | `BLEAT_API_CHALLENGE_LIFETIME_SECONDS` | `120` |
| `--token-lifetime-seconds` | `BLEAT_API_TOKEN_LIFETIME_SECONDS` | `600` |
| `--request-timeout-seconds` | `BLEAT_API_REQUEST_TIMEOUT_SECONDS` | `10` |
| `--max-request-body-bytes` | `BLEAT_API_MAX_REQUEST_BODY_BYTES` | `65536` |
| `--max-concurrent-requests` | `BLEAT_API_MAX_CONCURRENT_REQUESTS` | `64` |
| `--log-filter` | `BLEAT_API_LOG_FILTER` | `bleat_api=info,opentelemetry=warn,opentelemetry_sdk=warn,opentelemetry-otlp=warn` |
| `--log-format` | `BLEAT_API_LOG_FORMAT` | `compact` |

Production mode requires an HTTPS public issuer, Apple team ID, app identifier,
and the production App Attest environment. Invalid configuration stops startup
before the listener is bound.

## OpenTelemetry

Local logs are always written to stderr. Set an OTLP endpoint to additionally
export both traces and logs over OTLP/HTTP protobuf:

```sh
OTEL_EXPORTER_OTLP_ENDPOINT=https://collector.example \
  mise run api:run
```

The common endpoint derives `/v1/traces` and `/v1/logs`. Standard
`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` and `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT`
values override either signal independently. Standard OTLP header, timeout,
sampling, batching, and resource environment variables are passed to the
OpenTelemetry SDK. Header values may contain credentials and are never logged.

Remote exporter failures do not affect health, readiness, or request handling.
The service uses Rustls with system trust and does not support gRPC export.

## Routes

- `GET /healthz` returns process liveness.
- `GET /readyz` returns readiness after successful startup.
- `POST /v1/attestation/challenge`
- `POST /v1/attestation/enroll`
- `POST /v1/token/challenge`
- `POST /v1/token`

The four versioned routes currently accept bounded JSON and return the typed
`temporarily_unavailable` response reserved for the later authentication work.
