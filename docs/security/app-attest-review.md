# Apple App Attest telemetry-token security review

## Scope

This review covers the production Apple App Attest authentication path used by
`bleat-api` to issue short-lived telemetry bearer tokens. It focuses on the
trust boundary formed by App Attest enrollment, assertion verification,
challenge consumption, assertion-counter advancement, and ES256 JWT issuance.

Reviewed implementation: `terminaloutcomes/bleat` revision
`42849b370cff2186c5fa73eed04dbfd132120742`.

The principal question is whether a remote attacker can reproduce the HTTP
protocol in Python, construct arbitrary CBOR, and obtain a valid telemetry token
without control of a previously enrolled App Attest key.

This is a design and source review, not a claim that the iOS, Apple, database,
deployment, or cryptographic implementations are invulnerable.

## Security conclusion

Under the remote-client threat model, the design prevents an attacker from
minting a telemetry token solely by reproducing Bleat's requests or constructing
their own assertion CBOR. Token issuance requires a valid assertion signature
from the private key corresponding to an active, Apple-attested public key in
Bleat's installation database. Apple documents that the device creates this key
and keeps the private key in the Secure Enclave, where processes cannot directly
read or modify it.

The assertion signature covers both the complete Apple `authenticatorData` and
Bleat's client-data hash. Bleat's hash binds the protocol domain, operation
purpose, `challenge_id`, challenge value, and `installation_id`. Consequently,
an attacker cannot change the installation binding, purpose, challenge,
authenticator flags, counter, validation category, or bundle version while
retaining a valid signature. Challenge consumption and monotonic counter updates
also prevent successful assertion replay and concurrent reuse.

This conclusion does not extend to a compromised genuine device used as a
signing oracle, theft of an already-issued JWT, compromise of Bleat's JWT
signing key or installation database, or compromise of Apple or the applicable
Apple developer account.

## Reviewed trust flow

### Enrollment

1. `bleat-api` issues a random, expiring attestation challenge.
2. The client asks App Attest to attest a device-generated P-256 key using the
   Bleat enrollment client-data hash.
3. The production verifier validates the Apple certificate chain against the
   pinned App Attest root, the attestation nonce, App ID hash, environment,
   zero initial counter, credential identifier, and consistency between the
   certificate public key and encoded public key.
4. When validation-category and bundle-version claims are present, the verifier
   applies the configured allowlists.
5. The challenge is consumed once and the verified public key is stored against
   an opaque installation identifier. The private key is never supplied to
   Bleat or stored by `bleat-api`.

Enrollment establishes that the server-side public key is associated with an
App Attest key for the configured Apple application identity and environment.
An attacker-generated P-256 key is insufficient because it lacks an acceptable
Apple attestation for the enrollment challenge.

### Token issuance

For a token request, Bleat computes:

```text
clientDataHash = SHA256(
    "bleat-telemetry-auth/v1" + "\n" +
    "token_issue" + "\n" +
    challenge_id + "\n" +
    challenge + "\n" +
    installation_id
)

nonce = SHA256(authenticatorData || clientDataHash)
```

The App Attest assertion contains `authenticatorData` and an ECDSA signature
over `nonce`. `bleat-api` verifies that signature using the enrolled public key,
and also verifies:

- the installation exists and is active;
- the installation environment matches the verifier environment;
- the RP ID hash matches Bleat's configured Apple App ID;
- the App Attest authenticator flag has the expected value;
- the assertion counter is nonzero and greater than the stored counter;
- present validation-category and bundle-version claims match policy;
- the challenge digest, purpose, installation binding, expiry, and unconsumed
  state all match; and
- the counter can be conditionally advanced from the previously read value.

Only after these checks does the authenticated installation principal reach JWT
issuance. The JWT is ES256-signed and contains the configured issuer, the opaque
installation identifier as subject, `aud=bleat-telemetry`,
`scope=telemetry:write`, issuance time, and expiry.

## Attack analysis

### Hand-built Python or CBOR client

A client can reproduce the request schema and CBOR encoding, but cannot produce
a signature verifiable by an enrolled public key without using its corresponding
private key. Generating a new key does not help because Bleat verifies assertions
against the public key stored through enrollment. Copying another installation
identifier similarly leaves the attacker without that installation's private
key.

### Modification of flags or extensions

The signature input includes the complete `authenticatorData`. The authenticator
flag, RP ID hash, counter, validation category, bundle version, and any other
bytes in that structure are therefore integrity protected. Modifying, adding,
removing, or re-encoding those bytes after signing changes `nonce` and causes
signature verification to fail.

This property is stronger than merely parsing and checking the fields: even a
field that Bleat does not interpret cannot be altered without invalidating the
signature.

### Cross-purpose or cross-installation substitution

The operation purpose and installation identifier are part of Bleat's signed
client-data input. An assertion for enrollment cannot be substituted for token
issuance, and an assertion for installation A cannot authenticate installation
B. The challenge record independently stores the typed purpose and installation
binding and requires both to match during its conditional one-use update.

### Replay and races

The challenge is random, expiring, stored as a digest, and consumed with a
conditional update that requires it to be unconsumed. A reused challenge is
rejected. The App Attest counter must also be greater than the stored value, and
Bleat advances it with a compare-and-update against the previously observed
counter. Concurrent requests based on the same installation state cannot both
advance the counter.

Challenge consumption and counter advancement are separate conditional database
updates rather than one transaction. A failure or counter race after challenge
consumption fails closed and requires the client to obtain a new challenge; it
does not create a token-issuance bypass.

## Trust assumptions and limits

### Genuine device as a signing oracle

App Attest proves possession and use of an attested key; it does not make the
rest of the device or application logic trusted. If an attacker controls a
genuine enrolled device or sufficiently compromises the app environment, they
may be able to invoke App Attest with attacker-chosen client-data hashes. The
private key can remain non-exportable while the device is still abused as a
signing oracle. Challenge, purpose, and counter checks constrain replay but do
not prevent authorized key use by a compromised local environment.

### Bearer-token theft

Issued JWTs are bearer credentials. A party that steals one can replay it until
expiry from a different client without possessing the App Attest key. App Attest
protects token issuance, not subsequent proof of possession. The short token
lifetime bounds but does not eliminate this exposure.

The production OpenTelemetry Collector enforces the ES256 signature, issuer,
audience, expiration, and an optional `nbf` claim. It does not enforce `scope`
or a custom JWT payload schema. TLS and careful exclusion of authorization
headers from logs remain required.

### Server-side trusted assets

The JWT signing private key is a high-value credential. Its compromise permits
direct token forgery without App Attest. The installation database is also
trusted security state: modification of stored public keys, status, environment,
or counters can authorize attacker-controlled keys, disable installations, or
weaken replay protection. Database availability also affects authentication
availability.

The signing key, database credentials, backups, deployment configuration, and
administrative paths require access control, auditability, secret rotation, and
recovery procedures appropriate to authentication infrastructure.

### Apple and developer-account trust

Bleat ultimately trusts Apple's App Attest root, service behavior, Secure
Enclave implementation, and platform enforcement. Compromise of that trust
chain can invalidate the enrollment guarantee. Compromise of the Apple developer
account or its signing/distribution credentials can enable an attacker to ship
software under identities or distribution paths that Bleat is configured to
trust. App Attest is therefore an upstream trust dependency, not an independent
defense against Apple-platform or developer-account compromise.

### Missing iOS 27 claims

The current verifier deliberately accepts attestation and assertion
`authenticatorData` with no validation-category or bundle-version extensions for
compatibility with supported Apple operating systems before iOS 27. When the
claims are absent, `AppAttestPolicy::accepts` returns success and neither
allowlist is enforced. When an extension payload is present, Bleat requires both
claims to be structurally valid and allowlisted.

This is an explicit compatibility tradeoff. The category allowlist cannot prove
TestFlight or App Store distribution for evidence that lacks the category claim,
and the bundle-version allowlist cannot constrain such evidence to a configured
version. An attacker cannot strip claims from an already-signed modern assertion
without breaking its signature, but legitimately claim-less evidence receives
the legacy policy path.

## Suggested hardening

1. **Plan an enforceable end to the legacy claim-less path.** Measure the share
   of active installations producing claim-less evidence without logging raw
   evidence or stable device identifiers. When the supported OS floor permits,
   add a production configuration that requires both claims and fail closed.

2. **Use Apple's fraud-risk signal if abuse warrants it.** The verifier currently
   validates that an attestation receipt exists but does not retain it in the
   verified installation result. Consider securely storing the receipt and
   integrating Apple's App Attest fraud assessment to detect one compromised
   device serving many remote clients.

3. **Treat token theft as a separate control problem.** Keep the JWT lifetime at
   the minimum operationally practical value, ensure authorization headers and
   tokens never enter logs or telemetry, and require every receiver to validate
   the signature, issuer, audience, expiration, and optional `nbf`. Do not rely
   on `scope` or a custom JWT payload schema as Collector-enforced controls. If
   replay within the validity window becomes material, evaluate a
   sender-constrained request proof or an online revocation/session mechanism;
   adding a JWT identifier alone does not prevent replay.

4. **Harden and rehearse signing-key operations.** Maintain least-privilege
   access to the mounted JWT key, monitored rotation with JWKS overlap, emergency
   rotation and revocation procedures, and verification that private material is
   absent from images, repositories, logs, crash artifacts, and backups where it
   is not required. Follow `docs/operations/jwks-revocation.md` when compromise
   requires eviction of a revoked key from the Collector's verifier cache.

5. **Protect installation state as authentication data.** Restrict database and
   backup access, audit administrative mutations, preserve counter consistency
   during restore, and provide a tested way to disable suspicious installations.
   A database restore that rolls counters backward should be treated as a
   security event, not only a data-recovery event.

6. **Monitor the existing abuse controls.** Alert on challenge-issuance limiting,
   signature failures, replay and counter-conflict categories, abnormal
   enrollment volume, and token issuance by environment or claim-presence class.
   Avoid logging assertion objects, key identifiers, JWTs, challenges, or raw
   installation identifiers.

7. **Continuously test the signed boundary.** Keep regression fixtures for both
   legacy claim-less and current extension-bearing Apple structures. Tests should
   mutate the flag, RP ID, counter, purpose, challenge identifiers, challenge,
   installation identifier, validation category, and bundle version and prove
   that each mutation is rejected. Retain concurrent replay and counter-race
   tests against the real database implementation.

## Implementation references

- `bleat-api/src/app_attest.rs` — Apple attestation and assertion parsing,
  signature verification, application/environment policy, extensions, and
  counters.
- `bleat-api/src/telemetry_auth.rs` — canonical client-data hash and ES256 JWT
  claims/signing.
- `bleat-api/src/http.rs` — authentication ordering, challenge consumption,
  counter advancement, and token issuance.
- `bleat-api/src/challenge.rs` — one-use, expiring, purpose- and
  installation-bound challenge state.
- `bleat-api/src/installation.rs` — active installation lookup and conditional
  monotonic counter advancement.
- `bleat-api/tests/http_api.rs` and `bleat-api/tests/database.rs` — integrated
  replay, disabled-installation, and counter-race coverage.

## External references

- [Apple: Establishing your app's integrity](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity)
- [Apple: Validating apps that connect to your server](https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server)
- [Apple: Attestation Object Validation Guide](https://developer.apple.com/documentation/devicecheck/attestation-object-validation-guide)
