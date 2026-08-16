# bleat-api

`bleat-api` is Bleat's anonymous telemetry authentication service. It uses
PostgreSQL for installation state and single-use opaque challenges. Development
mode verifies deterministic fake P-256 evidence and issues ephemeral ES256
tokens for end-to-end client testing. Production App Attest verification and
persistent signing keys remain unavailable pending issues 65 and 66.

## Run locally

From the repository root:

```sh
mise run api:run
```

The supported local workflow starts both PostgreSQL and the API in containers.
The development defaults listen on `127.0.0.1:8080`. Check the service with:

```sh
curl --fail http://127.0.0.1:8080/healthz
curl --fail http://127.0.0.1:8080/readyz
```

Run every Rust validation gate with:

```sh
mise run api:validate
```

This runs formatting, compilation, strict Clippy, PostgreSQL-backed tests, a
Release build, and live HTTP checks against the disposable container stack.
Stop the development stack and delete its database volume with:

```sh
mise run api:down
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
| `--database-url` | `BLEAT_API_DATABASE_URL` | required; supplied by the local container workflow |
| `--database-max-connections` | `BLEAT_API_DATABASE_MAX_CONNECTIONS` | `16` |
| `--database-connect-timeout-seconds` | `BLEAT_API_DATABASE_CONNECT_TIMEOUT_SECONDS` | `5` |
| `--challenge-lifetime-seconds` | `BLEAT_API_CHALLENGE_LIFETIME_SECONDS` | `120` |
| `--challenge-cleanup-batch-size` | `BLEAT_API_CHALLENGE_CLEANUP_BATCH_SIZE` | `1000` |
| `--challenge-issuance-per-minute` | `BLEAT_API_CHALLENGE_ISSUANCE_PER_MINUTE` | `600` |
| `--token-lifetime-seconds` | `BLEAT_API_TOKEN_LIFETIME_SECONDS` | `600` |
| `--request-timeout-seconds` | `BLEAT_API_REQUEST_TIMEOUT_SECONDS` | `10` |
| `--max-request-body-bytes` | `BLEAT_API_MAX_REQUEST_BODY_BYTES` | `65536` |
| `--max-concurrent-requests` | `BLEAT_API_MAX_CONCURRENT_REQUESTS` | `64` |
| `--log-filter` | `BLEAT_API_LOG_FILTER` | `bleat_api=info,opentelemetry=warn,opentelemetry_sdk=warn,opentelemetry-otlp=warn` |
| `--log-format` | `BLEAT_API_LOG_FORMAT` | `compact` |

Only PostgreSQL URLs are accepted. Production mode also requires an HTTPS
public issuer, Apple team ID, app identifier, and the production App Attest
environment. Invalid configuration or unavailable database migrations stop
startup before the listener is bound. Database credentials are redacted from
configuration diagnostics.

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
- `GET /readyz` checks the PostgreSQL connection before returning readiness.
- `POST /v1/attestation/challenge` accepts `{}` and issues an unbound challenge.
- `POST /v1/token/challenge` accepts `{ "installation_id": "<uuid>" }` and
  issues a challenge bound to an active installation.
- `POST /v1/attestation/enroll` accepts `challenge_id`, `challenge`, `key_id`,
  and a base64url `attestation_object`.
- `POST /v1/token` accepts `installation_id`, `challenge_id`, `challenge`, and
  a base64url `assertion_object`.
- `GET /.well-known/openid-configuration` publishes development discovery.
- `GET /.well-known/jwks.json` publishes the development ES256 public key.

Challenge routes return `201` with `challenge_id`, `challenge`, and
`expires_at`. A challenge is 32 bytes of operating-system randomness encoded as
unpadded base64url. PostgreSQL stores only its SHA-256 digest, purpose, optional
installation binding, expiry, and consumption state. Consumption uses a
conditional typed ORM update, so only one concurrent consumer can succeed.
Expired challenge cleanup and per-process issuance are bounded by configuration.

Installation persistence records an opaque UUID, App Attest key identifier,
65-byte P-256 public key, typed App Attest environment, active or disabled
status, monotonic assertion counter, and timestamps. Counter advancement is an
atomic compare-and-update operation.

Development enrollment and token issuance verify domain-separated canonical
client-data hashes and fake P-256 proof-of-possession. Challenges are consumed
before installations are created or counters are advanced, so failed or
replayed evidence cannot be reused. Development JWTs live for ten minutes and
contain `iss`, opaque installation `sub`, `aud=bleat-telemetry`,
`scope=telemetry:write`, `iat`, `exp`, and `jti`. The ES256 signing key is
generated at process startup and is intentionally not durable. Production mode
rejects fake evidence and does not expose discovery or JWKS until the production
verifier and persistent signing-key lifecycle are implemented.

All database schema and data access code uses SeaORM and typed SeaQuery
expressions. The service does not execute string-based SQL statements.

## Container images

GitHub Actions builds the release container with Docker's maintained
[`github-builder`](https://github.com/docker/github-builder) workflow and
publishes it to:

```text
ghcr.io/terminaloutcomes/bleat-api
```

A push to `main` publishes `latest`. A `v*` Git tag publishes its exact semantic
version without the `v` prefix. A same-repository pull request publishes the
image under the full PR merge commit SHA selected and attested by GitHub
Actions. Fork pull requests build and validate the image but cannot publish it.

Published images include signed provenance and an SBOM. The reusable workflow
is pinned to an immutable commit from Docker's `v1` release line.
