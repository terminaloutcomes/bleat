# Scaling `bleat-api`

## Purpose

Use this playbook to change the number of `bleat-api` pods in Kubernetes. The
API can run behind the existing Service without session affinity: PostgreSQL
stores installation state, assertion counters, and single-use challenges, and
production pods read the same mounted ES256 signing key.

Scaling the API changes telemetry enrollment and token-issuance capacity only.
It does not scale PostgreSQL or the OpenTelemetry Collector, and it does not
remove their availability limits.

## Scaling properties and limits

- A challenge issued by one pod can be consumed by another. PostgreSQL uses a
  conditional update so exactly one consumer succeeds.
- Assertion counters use an atomic compare-and-update operation. Concurrent
  requests cannot both advance the same stored counter transition.
- Every production pod must receive the same issuer, App Attest policy,
  database URL, signing-key Secret, and optional public rotation-key set.
- `BLEAT_API_DATABASE_MAX_CONNECTIONS` is a per-pod pool limit. Its default is
  16, so the API's possible database connections increase by 16 for every pod
  unless the deployment overrides it.
- `BLEAT_API_CHALLENGE_ISSUANCE_PER_MINUTE` is also per pod. Its default is 600,
  so two pods can collectively issue approximately 1,200 challenges per
  minute. Use ingress-level or shared enforcement if an incident requires one
  global limit.
- `BLEAT_API_MAX_CONCURRENT_REQUESTS` is per pod and intentionally adds request
  capacity as replicas are added.
- Each pod checks and applies SeaORM migrations before binding its listener.
  Scaling an unchanged image against an up-to-date schema is safe. Coordinate
  a schema-changing release separately; do not use replica scaling as a
  migration mechanism.
- Kubernetes node clocks must remain synchronized because challenge and token
  validity use wall-clock timestamps.

The database connection budget must include every API pod and other PostgreSQL
clients. For `R` replicas and a per-pod API pool of `C`, reserve up to `R * C`
API connections. Reduce the per-pod pool before scaling if that total would
consume required database headroom. Scaling API pods does not make the current
single PostgreSQL deployment highly available.

## Safety rules

- Make planned replica and pool changes in the authoritative declarative
  deployment configuration. Review its plan before applying it.
- Use `kubectl scale` only for an intentional temporary override or incident
  response. Record the previous replica count and reconcile the override
  declaratively afterward.
- Do not scale PostgreSQL or the Collector as part of this procedure.
- Do not scale during a concurrent API rollout, signing-key rotation, database
  migration, or unresolved database incident.
- Keep at least one replica for ordinary service. Scaling to zero is the
  telemetry issuance kill switch described below.
- A successful command exit is not enough. Confirm the desired, updated,
  available, and ready replica counts and the number of ready Service
  endpoints.

## Preparation

Choose the target count and record the current deployment, pods, image, and
Service endpoints:

```sh
export BLEAT_NAMESPACE="bleat"
export BLEAT_API_DEPLOYMENT="bleat-api"
export BLEAT_API_TARGET_REPLICAS="2"

kubectl --namespace "${BLEAT_NAMESPACE}" get deployment "${BLEAT_API_DEPLOYMENT}" \
  --output=custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,UPDATED:.status.updatedReplicas,AVAILABLE:.status.availableReplicas,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image
kubectl --namespace "${BLEAT_NAMESPACE}" get pods \
  --selector=app=bleat-api --output=wide
kubectl --namespace "${BLEAT_NAMESPACE}" get endpointslice \
  --selector=kubernetes.io/service-name=bleat-api
```

Stop before changing anything if the deployment is not stable, pods are not
ready, `/readyz` reports unavailable, or the target would exceed the database
connection budget. When increasing replicas for availability, confirm the
cluster has more than one suitable node; multiple pods on one node do not
protect against a node failure.

## Scale up

For a planned change, update the authoritative deployment's replica count. If
needed, also set `BLEAT_API_DATABASE_MAX_CONNECTIONS` so the aggregate pool
remains within the database budget. Apply only the reviewed declarative plan.

For a temporary override, scale the Deployment directly:

```sh
kubectl --namespace "${BLEAT_NAMESPACE}" scale \
  deployment/"${BLEAT_API_DEPLOYMENT}" \
  --replicas="${BLEAT_API_TARGET_REPLICAS}"
kubectl --namespace "${BLEAT_NAMESPACE}" rollout status \
  deployment/"${BLEAT_API_DEPLOYMENT}" --timeout=180s
```

Proceed to verification. If new pods cannot become ready, inspect their typed
startup error and Kubernetes events. Common operational causes are exhausted
database connections, unavailable PostgreSQL, or inconsistent mounted signing
configuration. Do not repeatedly restart pods until the error disappears.

## Verify the target state

Verify deployment status and require exactly the target number of ready
Service endpoints:

```sh
kubectl --namespace "${BLEAT_NAMESPACE}" get deployment "${BLEAT_API_DEPLOYMENT}" \
  --output=custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,UPDATED:.status.updatedReplicas,AVAILABLE:.status.availableReplicas,READY:.status.readyReplicas

kubectl --namespace "${BLEAT_NAMESPACE}" get endpointslice \
  --selector=kubernetes.io/service-name=bleat-api --output=json \
  | jq --argjson expected "${BLEAT_API_TARGET_REPLICAS}" --exit-status \
      '[.items[].endpoints[] | select(.conditions.ready == true)] | length == $expected'
```

Then verify the public health, readiness, discovery, and JWKS routes through the
normal production hostname:

```sh
export BLEAT_API_ISSUER="https://replace-with-production-issuer"

curl --fail --silent --show-error "${BLEAT_API_ISSUER}/healthz" | jq --exit-status '.status == "ok"'
curl --fail --silent --show-error "${BLEAT_API_ISSUER}/readyz" | jq --exit-status '.status == "ready"'
curl --fail --silent --show-error \
  "${BLEAT_API_ISSUER}/.well-known/openid-configuration" \
  | jq --arg issuer "${BLEAT_API_ISSUER}" --exit-status '.issuer == $issuer'

set -o pipefail
for attempt in {1..20}; do
  curl --fail --silent --show-error \
    "${BLEAT_API_ISSUER}/.well-known/jwks.json" || exit 1
done | jq --slurp --exit-status 'unique | length == 1'
```

The final command must return `true`. A failure or more than one structurally
distinct response means replicas may disagree about signing or public rotation
keys; return to the recorded replica count and correct the mounted configuration
before continuing.

Also confirm:

- each ready pod has a distinct `service.instance.id` in API telemetry;
- API error and latency rates remain normal;
- PostgreSQL connection use and latency retain headroom; and
- challenge issuance has not unexpectedly multiplied beyond the intended
  per-pod limit.

For a capacity change, monitor through at least one normal peak period before
considering the change complete. For an availability change, confirm replicas
are placed on different nodes. Add topology spreading or pod anti-affinity and
a PodDisruptionBudget if the deployment does not already enforce that outcome.

## Scale down

Confirm the remaining replicas have capacity for current traffic and database
pool settings. For a planned change, update and apply the authoritative replica
count. For a temporary override:

```sh
export BLEAT_API_TARGET_REPLICAS="1"

kubectl --namespace "${BLEAT_NAMESPACE}" scale \
  deployment/"${BLEAT_API_DEPLOYMENT}" \
  --replicas="${BLEAT_API_TARGET_REPLICAS}"
kubectl --namespace "${BLEAT_NAMESPACE}" rollout status \
  deployment/"${BLEAT_API_DEPLOYMENT}" --timeout=180s
kubectl --namespace "${BLEAT_NAMESPACE}" get pods \
  --selector=app=bleat-api --output=wide
```

Run the target-state verification again. Kubernetes sends `SIGTERM`, and the
API stops accepting work through its graceful-shutdown path. Requests already
accepted by a terminating pod must either complete or return a typed failure;
clients may safely retry challenge acquisition, but a challenge already
consumed by a failed enrollment or token request cannot be reused.

Do not consider a temporary scale-down complete until the authoritative desired
count is reconciled. Otherwise the next deployment apply may unexpectedly
restore the old count.

## Scale to zero and restore

Scaling `bleat-api` to zero is an incident kill switch, not an ordinary capacity
change. It stops new enrollment and token issuance. Tokens already issued can
remain valid for their configured lifetime, which is ten minutes by default,
and the Collector can continue accepting them. Disable public Collector ingress
separately when ingestion must stop immediately.

Activate the temporary kill switch and wait until API pods are gone:

```sh
kubectl --namespace "${BLEAT_NAMESPACE}" scale \
  deployment/"${BLEAT_API_DEPLOYMENT}" --replicas=0
kubectl --namespace "${BLEAT_NAMESPACE}" wait --for=delete pod \
  --selector=app=bleat-api --timeout=120s
```

Restore the previously recorded replica count, not an assumed default, and run
the full target-state verification:

```sh
export BLEAT_API_TARGET_REPLICAS="replace-with-recorded-count"

kubectl --namespace "${BLEAT_NAMESPACE}" scale \
  deployment/"${BLEAT_API_DEPLOYMENT}" \
  --replicas="${BLEAT_API_TARGET_REPLICAS}"
kubectl --namespace "${BLEAT_NAMESPACE}" rollout status \
  deployment/"${BLEAT_API_DEPLOYMENT}" --timeout=180s
```

If the signing key may be compromised, scaling to zero is insufficient because
the key holder can mint tokens without the API. Follow
`docs/operations/jwks-revocation.md` instead.

## Completion checklist

- [ ] Previous and target replica counts were recorded.
- [ ] The aggregate database connection budget was checked.
- [ ] No rollout, migration, key rotation, or database incident overlapped the
      change.
- [ ] Desired, updated, available, and ready replica counts equal the target.
- [ ] The Service has exactly the target number of ready endpoints.
- [ ] Public health, readiness, discovery, and JWKS checks passed.
- [ ] Every sampled JWKS response was structurally identical.
- [ ] Error rate, latency, database load, and issuance volume remain normal.
- [ ] Availability replicas are distributed across failure domains when that
      was the purpose of the change.
- [ ] Temporary overrides were reconciled into declarative configuration.

## Related documentation

- `bleat-api/README.md` — API configuration, route behavior, and signing-key
  rotation.
- `docs/architecture-logging.md` — production topology and telemetry kill
  switch semantics.
- `docs/operations/jwks-revocation.md` — emergency signing-key revocation.
