# Emergency telemetry signing-key revocation

## Purpose

Use this playbook when the active ES256 private key used by `bleat-api` is
confirmed or reasonably suspected to be compromised. A stolen bearer token is
not a signing-key compromise: an ordinary token expires after ten minutes. If
one stolen token requires immediate containment, disable public device telemetry
ingress until it expires.

Normal key rotation is documented in `bleat-api/README.md`. Normal rotation
deliberately retains the old public key until tokens already issued with it have
expired. Emergency revocation instead removes the compromised public key
immediately and invalidates every token signed by it.

## Why restarting the Collector is required

The stock OpenTelemetry Collector uses `coreos/go-oidc` for OIDC verification.
Its remote key set tries cached keys before fetching JWKS again. A valid
signature from a cached key succeeds without a refresh, even if that key has
since been removed from the issuer's JWKS document. See the pinned verifier's
[`RemoteKeySet.verify`](https://github.com/coreos/go-oidc/blob/v3.20.0/oidc/jwks.go#L145-L178)
implementation.

Removing a key from JWKS and restarting only `bleat-api` therefore does not
revoke a compromised key from a running Collector. An attacker holding the old
private key could continue creating fresh, unexpired tokens accepted from the
Collector's cache. A successful revocation requires all of the following:

1. disable public device telemetry ingress;
2. stop new token issuance;
3. replace the active private key and remove the compromised public key;
4. replace every Collector process that may have cached the key;
5. prove an unexpired old-key token is rejected and a replacement-key token is
   accepted; and
6. reopen ingress only after those checks pass.

Scaling only `bleat-api` to zero is not sufficient during signing-key
compromise. The party holding the key does not need the API to mint another JWT.

## Safety rules

- Keep public device telemetry ingress closed throughout revocation and
  verification.
- Make emergency changes in the authoritative deployment and secret-management
  configuration. Reconcile any temporary scale override before closing the
  incident.
- Generate the replacement P-256 key through the existing secret workflow. Do
  not print, copy into shell arguments, attach, or commit private key material.
- Give the replacement key a new `kid`. Never reuse the compromised key or its
  identifier.
- Remove the compromised public JWK immediately. Do not retain the normal
  token-expiry overlap during emergency revocation.
- Never record JWTs, authorization headers, private key bytes, or decrypted
  secret values in logs, tickets, command output, or retained evidence.
- Record only public key identifiers, timestamps, resource versions, pod
  identities, HTTP outcomes, and privacy-safe telemetry counters.
- If any verification step is inconclusive, keep ingress closed and fix
  forward. Never roll back to the compromised key.

## Preparation

Before changing state, record:

- the incident start and containment timestamps;
- the compromised public `kid`;
- the current API and Collector image identities and pod UIDs;
- the current API and Collector replica counts;
- the authoritative ingress or tunnel route serving device telemetry; and
- whether an unexpired token signed by the compromised key is already available
  in a controlled, memory-only test path.

The negative verification requires an old-key token whose `exp` remains in the
future. An expired token proves only expiry enforcement. Prefer a legitimate
token obtained before containment. If none is available, create a short-lived
canary only in an approved incident environment that already has lawful custody
of the compromised key. Do not extract the mounted production key merely to
construct a test token. Report the negative verification as incomplete if a
safe canary cannot be obtained.

## 1. Contain ingestion and issuance

Disable the public route to the Collector's device OTLP receiver in the
authoritative ingress or tunnel configuration. Confirm the route is unreachable
externally; an HTTP authentication rejection is not evidence that the route is
disabled.

Then stop the API and Collector processes:

```sh
kubectl --namespace bleat scale deployment/bleat-api --replicas=0
kubectl --namespace bleat scale deployment/bleat-otel-collector --replicas=0
kubectl --namespace bleat wait --for=delete pod \
  --selector=app=bleat-api --timeout=120s
kubectl --namespace bleat wait --for=delete pod \
  --selector=app=bleat-otel-collector --timeout=120s
```

If either deployment is automatically reconciled, suspend or update that
reconciliation through its supported workflow. Do not leave a controller able
to restore the compromised configuration during the incident.

## 2. Replace the signer and published key set

Generate a new P-256 signing key and update the mounted signing-key Secret
through the existing encrypted, declarative secret workflow. Update any
public-only rotation-key file at the same time:

- the replacement public JWK must be present;
- the compromised `kid` must be absent;
- no public JWK may contain private `d` material; and
- publication windows must not retain the compromised key.

Keep the API's desired replica count at zero in the authoritative configuration
while applying the replacement Secret. An apply must not silently reconcile the
deployment back to one replica before the old public key has been removed.
Inspect the planned change and the resulting Secret metadata without rendering
secret data.

Start only `bleat-api` and wait for readiness:

```sh
kubectl --namespace bleat scale deployment/bleat-api --replicas=1
kubectl --namespace bleat rollout status deployment/bleat-api --timeout=180s
```

Verify OIDC discovery and JWKS from a trusted administrative path. The public
values below are safe to compare, but do not put a JWT into these variables:

```sh
export BLEAT_REVOCATION_ISSUER="https://replace-with-production-issuer"
export BLEAT_REVOKED_KID="replace-with-revoked-public-kid"
export BLEAT_REPLACEMENT_KID="replace-with-replacement-public-kid"

curl --fail --silent --show-error \
  "${BLEAT_REVOCATION_ISSUER}/.well-known/openid-configuration" \
  | jq -e --arg issuer "${BLEAT_REVOCATION_ISSUER}" \
      '.issuer == $issuer and (.jwks_uri | type == "string")'

curl --fail --silent --show-error \
  "${BLEAT_REVOCATION_ISSUER}/.well-known/jwks.json" \
  | jq -e \
      --arg revoked "${BLEAT_REVOKED_KID}" \
      --arg replacement "${BLEAT_REPLACEMENT_KID}" \
      '([.keys[].kid] | index($revoked) == null)
       and ([.keys[].kid] | index($replacement) != null)
       and all(.keys[]; has("d") | not)'
```

Stop if discovery or JWKS contains the revoked key, omits the replacement key,
or exposes private material.

## 3. Replace the Collector process

Keep the public device route disabled. Start a new Collector pod and wait for it
to become ready:

```sh
kubectl --namespace bleat scale deployment/bleat-otel-collector --replicas=1
kubectl --namespace bleat rollout status deployment/bleat-otel-collector --timeout=180s
kubectl --namespace bleat get pods --selector=app=bleat-otel-collector \
  --output=custom-columns=NAME:.metadata.name,UID:.metadata.uid,STARTED:.status.startTime,IMAGE:.status.containerStatuses[0].imageID
```

The pod UID and process start time must be newer than containment. A ConfigMap
reload or API restart does not clear the Collector's in-memory OIDC key cache.

## 4. Verify rejection and recovery

Run the probe against the authenticated device receiver from a controlled
internal path while public ingress remains disabled. Use a valid minimal
OTLP/HTTP protobuf request and keep authorization material out of arguments and
logs.

Verify all of these outcomes:

1. an unexpired token signed by the revoked key receives HTTP `401`;
2. the same probe without a bearer token receives HTTP `401`, proving it reached
   the authenticated receiver rather than a different endpoint;
3. a token issued by the replacement key succeeds; and
4. Collector logs and metrics show authentication rejection without containing
   either token or its authorization header.

A timeout, connection refusal, `404`, expired-token rejection, or failed OTLP
payload is not proof of key revocation. Record only status codes, public `kid`
values, timestamps, and the new Collector pod UID.

If the old-key token succeeds, immediately scale the Collector back to zero,
keep ingress disabled, and investigate whether:

- an old Collector process is still serving traffic;
- the compromised public key remains in JWKS or a mounted public-key file;
- traffic reached a different Collector instance; or
- the probe reached a receiver without OIDC authentication.

## 5. Restore public service

After both negative and positive token checks pass:

1. re-enable the public device telemetry route through its authoritative
   configuration;
2. confirm the API and Collector each have their intended replica count;
3. verify API readiness, Collector readiness, token renewal, and authenticated
   OTLP delivery;
4. reconcile temporary scale or ingress overrides into declarative state; and
5. monitor authentication rejection, issuance, Collector restarts, queue state,
   and ingestion volume for at least the next token-lifetime window.

Clients holding old tokens will receive authentication failures and obtain a
replacement token through the normal retry path. Retained client telemetry may
drain after authentication recovers.

## Incident closure checklist

- [ ] Public device ingress was disabled before signer or Collector changes.
- [ ] New token issuance stopped during containment.
- [ ] The compromised private key was replaced and its public `kid` removed.
- [ ] The replacement key uses a new `kid` and no JWKS entry contains `d`.
- [ ] Every Collector process that could cache the old key was replaced.
- [ ] An unexpired old-key token was rejected by the authenticated receiver.
- [ ] A replacement-key token was accepted by the same receiver.
- [ ] No JWT, authorization header, or private key entered retained artifacts.
- [ ] Public ingress and intended replica counts were restored declaratively.
- [ ] Monitoring remained normal for at least one token-lifetime window.
- [ ] The compromise source, affected secret stores, backups, automation, and
      administrator access paths were investigated and remediated.

## Related documentation

- `bleat-api/README.md` — normal JWT signing-key rotation.
- `docs/architecture-logging.md` — ordinary telemetry kill switch and recovery.
- `docs/security/app-attest-review.md` — signing-key and bearer-token threat
  analysis.
