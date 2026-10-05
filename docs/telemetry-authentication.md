# Telemetry authentication

Bleat authenticates an app installation through Apple App Attest, then uses a
short-lived token to send diagnostic telemetry. Authentication verifies the
configured application's cryptographic identity. **App versions, build numbers,
and distribution categories are metadata, never admission gates.** Shipping a
new app build does not require an authentication-policy update on the backend.

This flow is separate from Audiobookshelf account login. Audiobookshelf access
and refresh tokens are not used to authenticate telemetry.

## The two keys

| Key | Owner | Purpose | Private key storage |
| --- | --- | --- | --- |
| Installation App Attest key | One app installation on one device | Prove possession of the key that Apple attested for the configured app identity | Managed on the device by Apple App Attest; never uploaded |
| API JWT signing key | `bleat-api` | Sign short-lived telemetry access tokens | Mounted backend secret; never included in the container image |

The API stores the installation's verified public key. The Collector obtains
the API's public signing keys through its discovery and JWKS endpoints. These
keys have different owners and purposes.

## 1. Consent and lazy authentication

Remote telemetry is opt-in. Enabling **Share diagnostic telemetry** does not
immediately generate an App Attest key, enroll the installation, or request a
token. Authentication starts when the exporter first needs a bearer token.

Concurrent token requests share one acquisition operation. Bleat reuses its
memory-held token while it has more than the configured refresh window remaining
(two minutes by default). When a token needs renewal, Bleat proves possession of
the existing installation key again.

## 2. Enroll the installation key

An installation without a completed enrollment performs this sequence:

1. Bleat asks Apple App Attest to generate an installation key. It saves the key
   identifier as a pending enrollment in device-only Keychain storage.
2. Bleat requests `POST /v1/attestation/challenge` from `bleat-api`.
3. Both client and server construct the same SHA-256 client-data hash, binding
   the protocol domain, enrollment purpose, challenge identifier, and challenge
   value. Enrollment does not yet have an installation identifier.
4. Bleat asks Apple App Attest to attest the generated key using that hash.
5. Bleat submits the key identifier, challenge, and attestation evidence to
   `POST /v1/attestation/enroll`.

The production API verifies:

- the certificate chain against the pinned Apple App Attest root;
- the application identity hash against the configured Apple Team ID and bundle
  identifier;
- the expected App Attest environment and zero initial counter;
- consistency between the credential identifier, submitted key identifier,
  certificate public key, and encoded public key; and
- the attestation nonce binding the evidence to this enrollment's client-data
  hash and authenticator data.

Present extension claims must have valid bounded encoding and remain covered by
the cryptographic verification. Their version and category values do not control
acceptance.

After verification, the API validates and consumes the unexpired,
enrollment-purpose challenge once. It creates an opaque installation identifier
and stores the verified public key, App Attest environment, active status, and
assertion counter in PostgreSQL. Bleat saves the completed key identifier and
installation identifier in device-only Keychain storage.

The installation identifier locates a record; knowing it is not proof of
possession of the installation's private key.

## 3. Obtain or renew a telemetry token

The enrolled app performs this sequence whenever it needs a fresh token:

1. Request `POST /v1/token/challenge` for its installation identifier.
2. Construct a client-data hash binding the protocol domain, token-issuance
   purpose, challenge identifier, challenge value, and installation identifier.
3. Ask App Attest to generate an assertion with the enrolled key and that hash.
4. Submit the assertion, installation identifier, and challenge to
   `POST /v1/token`.

The API loads the active installation's public key and verifies the assertion's
application identity, environment, and signature. The assertion counter must be
nonzero and greater than the stored counter. The signature covers the complete
authenticator data, including any appended version and category claims, together
with the client-data hash construction.

The API then validates and consumes the challenge: its value, purpose,
installation binding, expiry, and unused status must match. It conditionally
advances the stored counter from the previously read value. Concurrent requests
cannot both advance that same counter; a conflict rejects authentication. These
steps are separate conditional operations, not one transaction. A later counter
conflict can therefore leave the challenge consumed without issuing a token.

Only after these checks succeed does the API issue a ten-minute ES256 JWT with:

- the configured issuer;
- the opaque installation identifier as its subject;
- audience `bleat-telemetry`;
- scope `telemetry:write`; and
- issue and expiry timestamps.

The JWT stays in app memory. It is not persisted in Keychain, SwiftData, retained
telemetry batches, or logs. Normal renewal reuses the enrollment; it does not
repeat Apple attestation. If App Attest reports that the key is invalidated, the
client allows one bounded replacement-enrollment attempt.

## 4. Send telemetry through the Collector

```text
Bleat -- enrollment/assertion proof --> bleat-api
Bleat <-- short-lived signed JWT ----- bleat-api

Bleat -- HTTPS OTLP + bearer JWT --> authenticated Collector receiver
Collector -- accepted logs/traces --> ClickHouse --> HyperDX
```

The Collector's OIDC authenticator obtains the API's discovery document and
public JWKS. It verifies the bearer token's signature, exact issuer, audience,
and standard time claims before accepting device telemetry.

The token carries `telemetry:write`, but the stock Collector does not enforce
arbitrary custom scope claims. The configured issuer and audience serve the
single-purpose telemetry token boundary.

The API's own server telemetry uses a separate internal receiver. It does not
authenticate through the device's App Attest flow. See
[Logging and telemetry architecture](architecture-logging.md) for receiver
ports, ingress exposure, and the full deployment topology.

## Metadata and rejection behavior

After successful cryptographic verification, the API records present claims as
`app_attest.bundle_version` and `app_attest.validation_category`, with operation
`attestation.verify` or `assertion.verify`. These fields describe the verified
evidence; they never select an authentication outcome. Supported older Apple
systems can omit these extensions, so absent claims are not fabricated.

App Attest environment remains a separate cryptographic check. A development
signing category is not the same thing as the App Attest development environment,
and neither is the API's fake-evidence development mode.

Malformed evidence, incorrect application identity, invalid certificates,
nonces or signatures, expired or reused challenges, disabled installations, and
replayed counters still fail authentication. Internal diagnostics identify the
typed cause and processing stage. External authentication errors remain small
and do not disclose raw evidence or cryptographic material.

The key implementations are `Sources/BleatCore/TelemetryAuthentication.swift`,
`App/AppAttestTelemetryAttester.swift`, `bleat-api/src/app_attest.rs`,
`bleat-api/src/http.rs`, and `bleat-api/src/telemetry_auth.rs`. See the
[App Attest security review](security/app-attest-review.md) for the threat model
and residual risks.
