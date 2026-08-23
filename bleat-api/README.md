# bleat-api

`bleat-api` is Bleat's anonymous telemetry authentication service. It uses
PostgreSQL for installation state and single-use opaque challenges. Development
mode verifies deterministic fake P-256 evidence and issues ephemeral ES256
tokens for end-to-end client testing. Production mode verifies Apple App Attest
enrollment and assertions, then issues narrow ES256 tokens from a mounted
deployment signing key.

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
Rust tests construct configuration explicitly rather than inheriting caller
application or OTLP settings. Each database-backed Rust test starts and removes
its own isolated PostgreSQL 17 container through Testcontainers, so Docker is
the only database-test prerequisite. Measure the separate Rust coverage gate
with:

```sh
mise run api:coverage
```

The coverage task writes its JSON report under `.build/coverage/bleat-api/`,
warns when overall line coverage falls below 80% without failing the task, and
reports `src/app_attest.rs` coverage separately so gaps in the security boundary
remain visible without turning its percentage into a substitute for
behavior-focused tests.
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
| `--app-attest-bundle-versions` | `BLEAT_API_APP_ATTEST_BUNDLE_VERSIONS` | unset |
| `--app-attest-validation-categories` | `BLEAT_API_APP_ATTEST_VALIDATION_CATEGORIES` | unset |
| `--database-url` | `BLEAT_API_DATABASE_URL` | required; supplied by the local container workflow |
| `--database-max-connections` | `BLEAT_API_DATABASE_MAX_CONNECTIONS` | `16` |
| `--database-connect-timeout-seconds` | `BLEAT_API_DATABASE_CONNECT_TIMEOUT_SECONDS` | `5` |
| `--challenge-lifetime-seconds` | `BLEAT_API_CHALLENGE_LIFETIME_SECONDS` | `120` |
| `--challenge-cleanup-batch-size` | `BLEAT_API_CHALLENGE_CLEANUP_BATCH_SIZE` | `1000` |
| `--challenge-issuance-per-minute` | `BLEAT_API_CHALLENGE_ISSUANCE_PER_MINUTE` | `600` |
| `--token-lifetime-seconds` | `BLEAT_API_TOKEN_LIFETIME_SECONDS` | `600` |
| `--jwt-signing-key-file` | `BLEAT_API_JWT_SIGNING_KEY_FILE` | unset; required in production |
| `--jwt-public-key-set-file` | `BLEAT_API_JWT_PUBLIC_KEY_SET_FILE` | unset |
| `--request-timeout-seconds` | `BLEAT_API_REQUEST_TIMEOUT_SECONDS` | `10` |
| `--max-request-body-bytes` | `BLEAT_API_MAX_REQUEST_BODY_BYTES` | `65536` |
| `--max-concurrent-requests` | `BLEAT_API_MAX_CONCURRENT_REQUESTS` | `64` |
| `--log-filter` | `BLEAT_API_LOG_FILTER` | `bleat_api=info,opentelemetry=warn,opentelemetry_sdk=warn,opentelemetry-otlp=warn` |
| `--log-format` | `BLEAT_API_LOG_FORMAT` | `compact` |

Only PostgreSQL URLs are accepted. Production mode also requires an HTTPS
public issuer, Apple team ID, app identifier, and the production App Attest
environment. It also requires comma-separated allowlists for accepted Apple
bundle versions and validation categories. Apple's currently documented
application categories are `1` through `6` and `10`; configure only the
categories appropriate to the deployed build, such as TestFlight (`2`) or App
Store (`4`). Invalid configuration or unavailable database migrations stop
startup before the listener is bound. The production issuer must be an HTTPS
origin without credentials, a path, a query, or a fragment. The JWT signing-key
file contains an unencrypted SEC1 DER P-256 private key supplied through a
mounted deployment secret; it is never copied into the image or repository.
The optional public-key-set file contains public rotation keys only. Database
credentials and signing-key paths are redacted from configuration diagnostics.
Once the database is ready and the listener is bound, the `bleat-api started`
event records the effective non-secret service settings. It reports only
whether Apple identifiers and signing configuration are present, and never
includes the database URL, key paths, or OTLP connection details.

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
HTTP server spans include the OpenTelemetry semantic `url.path` and
`url.scheme` attributes, plus `user_agent.original` when the request includes a
valid `User-Agent` header. The path uses the matched route shape so installation
identifiers are not exported, and raw query strings are excluded.

Remote exporter failures do not affect health, readiness, or request handling.
The service uses Rustls with system trust and does not support gRPC export.

## Telemetry Collector baseline

`TelemetryCollector.yaml` is the stock OpenTelemetry Collector Contrib ingress
configuration exercised by `scripts/test-bleat-api.sh`. The disposable stack
pins the Collector image by version and digest, validates both Collector
configurations, and sends the accepted trace to the private capture service in
`TelemetryCollectorCapture.yaml`.

The ingress validates the token issuer and `aud=bleat-telemetry` through OIDC,
accepts only authenticated OTLP/gRPC traffic, caps each received message at
1 MiB, and applies bounded memory, batch, retry, and in-memory queue settings.
The live test proves that a valid Bleat ES256 JWT reaches the private exporter,
missing and malformed credentials are rejected, oversized payloads fail, the
captured trace contains no authentication or installation data, and ingress
remains healthy while the private exporter is unavailable.

The JWT continues to carry `scope=telemetry:write`. Collector processors can
inspect verified claims and silently drop telemetry, but the stock OIDC
authenticator cannot hard-reject an OTLP RPC based on a custom claim. Hard
scope rejection is not required for this baseline because the issuer produces
only this narrow telemetry token with exact issuer and audience semantics.

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
- `GET /.well-known/openid-configuration` publishes the exact configured issuer,
  token endpoint, JWKS URI, and ES256 algorithm.
- `GET /.well-known/jwks.json` publishes the active ES256 public key plus any
  public rotation keys inside their configured publication windows.

The discovery and JWKS responses use deterministic strong ETags and
`Cache-Control: public, max-age=60`; matching `If-None-Match` requests return
`304` without a body.

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
`scope=telemetry:write`, `iat`, and `exp`, with no refresh token or additional
claims. The ES256 signing key is generated at process startup and is
intentionally not durable.

Production enrollment follows Apple's App Attest validation sequence. It
strictly and boundedly parses the attestation CBOR and authenticator data,
validates the certificate path, nonce, App ID hash, environment AAGUID,
credential ID, and certificate and encoded COSE public keys before persisting
an installation. On iOS 27 and later, it also validates the appended bundle
version and validation category against the configured application policy.
Earlier Apple operating systems do not emit those extensions, so their absence
does not bypass the certificate, nonce, application, credential, signature, or
counter checks. Assertions are checked against that stored public key and
environment, the token-purpose challenge, any supplied application-policy
extensions, and an atomically advanced monotonic counter. Externally these
failures share the small authentication error shape;
internal categories contain no evidence, challenge, signature, key ID, or
installation identifier. Production token requests use that authenticated
principal to issue the same narrow ten-minute JWT from the mounted signing key.
Disabling an installation prevents subsequent authentication and issuance;
already-issued tokens expire naturally within their bounded lifetime.

The production authenticator-data parser is kept aligned with Apple's public
[Attestation Object Validation Guide](https://developer.apple.com/documentation/devicecheck/attestation-object-validation-guide).
Its published 2026 authenticator data is retained unchanged as a versioned
regression fixture under `tests/fixtures/apple-app-attest/`, alongside its
provenance and update rules. In particular, Apple encodes
`apple_validation_category_01` as a four-byte little-endian byte string, not as
a CBOR integer; `apple_bundle_version_01` is a CBOR text string. The fixture test
checks the RP ID hash, counter, production AAGUID, credential ID, COSE public-key
hash, validation category, and bundle version together. The complete synthetic
production-verifier tests additionally cover certificate-chain, nonce, policy,
and assertion-signature validation without depending on Apple or external
configuration. Apple's
[WWDC26 App Attest session](https://developer.apple.com/videos/play/wwdc2026/201/)
documents that the extensions start in iOS 27. A separate synthetic regression
covers the extension-free attestation and assertion shapes emitted by earlier
supported systems.

## JWT signing-key rotation

The optional public-key-set file is bounded JSON with this shape:

```json
{
  "keys": [
    {
      "jwk": {
        "kty": "EC",
        "crv": "P-256",
        "x": "<base64url-public-x>",
        "y": "<base64url-public-y>",
        "alg": "ES256",
        "use": "sig",
        "kid": "<stable-key-id>"
      },
      "publish_from": "2026-08-22T00:00:00Z",
      "publish_until": "2026-08-22T00:20:00Z"
    }
  ]
}
```

Private `d` values, non-ES256 keys, duplicate key IDs, invalid windows, and
windows shorter than the token lifetime plus 30 seconds of clock skew are
rejected. A service restart continues publishing every key until its configured
`publish_until`, including during the final token-expiry overlap.

Rotate without invalidating otherwise-valid tokens:

1. Add the new public JWK to the public-key-set file and restart the service.
2. Wait at least the 60-second JWKS cache lifetime.
3. Mount the new private key as the active signing key, retain the old public
   JWK in the public-key-set file, and restart the service.
4. Keep the old public key published through the last old token expiry plus
   30 seconds of clock skew; its configured window then removes it from JWKS.

The active private key is the only private signing material loaded. Rotation
entries are public verification keys and can be distributed independently.
Ordinary logs record only bounded issuance outcomes, never JWTs, installation
identifiers, key material, or key-file paths.

## Apple App Attest trust anchor

`trust/Apple_App_Attestation_Root_CA.pem` is Apple's public App Attest root,
obtained from `https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem`.
The verifier embeds it at build time and pins the SHA-256 fingerprint of its DER
certificate:

```text
1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932
```

Authentication never downloads trust material at runtime. When Apple publishes
a replacement, obtain it from Apple's certificate-authority site, independently
confirm its published provenance, inspect its subject and validity, replace the
PEM, and update both the pinned DER fingerprint and its regression test in the
same reviewed change. Run `mise run api:validate` before deployment; an
unparseable root or fingerprint mismatch prevents production router startup.

All database schema and data access code uses SeaORM and typed SeaQuery
expressions. The service does not execute string-based SQL statements.

## Container images

GitHub Actions builds the release container with Docker's maintained
[`github-builder`](https://github.com/docker/github-builder) workflow and
publishes it to:

```text
ghcr.io/terminaloutcomes/bleat-api
```

Every published build receives a UTC `build-YYYYMMDD-HHmmss` tag. A push to
`main` also publishes `latest`. A `v*` Git tag also publishes its exact semantic
version without the `v` prefix. A same-repository pull request also publishes
the image under the full PR merge commit SHA selected and attested by GitHub
Actions. Fork pull requests build and validate the image but cannot publish it.

Published images include signed provenance and an SBOM. The reusable workflow
is pinned to an immutable commit from Docker's `v1` release line.
