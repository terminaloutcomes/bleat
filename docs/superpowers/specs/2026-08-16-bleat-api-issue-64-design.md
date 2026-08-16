# Bleat API Issue 64 Design

## Goal

Complete the telemetry-authentication service foundation with PostgreSQL-backed
opaque challenges, persistent installation state, atomic assertion counters,
and a reproducible container workflow. App Attest verification and JWT issuance
remain owned by issues 65 and 66.

## Storage

SeaORM uses PostgreSQL in every environment. Application-owned migrations
create typed installation and challenge records. Installations retain an opaque
server UUID, App Attest key ID, verified uncompressed P-256 public key,
environment, status, monotonic assertion counter, and timestamps.

Challenges contain an opaque UUID, SHA-256 digest, purpose, optional
installation binding, expiry, consumption timestamp, and creation timestamp.
The service generates 32 random bytes and returns them as unpadded base64url;
raw challenge bytes are never stored or logged. Challenge consumption is one
conditional update matching the identifier, digest, purpose, binding, expiry,
and unused state.

## HTTP Contract

`POST /v1/attestation/challenge` accepts `{}`. `POST /v1/token/challenge`
accepts an opaque `installation_id`. Both return `201` with `challenge_id`,
`challenge`, and `expires_at`. The token challenge uses the installation ID
only as lookup context and returns the same authentication rejection for
missing and disabled installations.

Enrollment and token submission remain typed unavailable placeholders until
issues 65 and 66. Health is process liveness. Readiness checks PostgreSQL and
returns a privacy-safe typed failure when unavailable.

## Bounds and Failures

Configuration includes the PostgreSQL URL, connection bounds, challenge
cleanup batch size, and process-local issuance rate. Expired challenges are
removed opportunistically in bounded batches. All public and persistence
outcomes use enums or dedicated structs; decisions never inspect error text.
Database URLs, raw challenges, installation identifiers, key identifiers,
public keys, and database internals are excluded from logs and responses.

## Validation

Tests use disposable PostgreSQL and cover migrations, challenge entropy and
encoding, digest-only persistence, purpose and installation binding, expiry,
replay, concurrent consumption, installation transitions, atomic assertion
counters, readiness, request limits, typed failures, and redaction. A
multi-stage Rust container runs as a non-root user and is exercised with
PostgreSQL through Docker Compose. The dependency tree must contain neither
OpenSSL nor `openssl-sys`.
