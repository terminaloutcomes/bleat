# Logging and telemetry architecture

This document is the source of truth for how Bleat produces, authenticates,
transports, stores, and queries diagnostic logs and traces. The product and
privacy rules remain defined in `docs/audiobookshelf-ios-app-spec.md`; this
document defines the deployment topology and component boundaries.

## Signals and identities

Bleat has two telemetry producers:

- `bleat-api` emits structured logs and server spans with
  `service.name=bleat-api`, a per-replica `service.instance.id`, and container
  image identity. Docker runtimes also emit their hexadecimal `container.id`;
  an orchestrator can provide its authoritative runtime ID explicitly. Local
  stderr logging remains active if remote export fails or is not configured.
- The opted-in iOS application emits its reviewed spans and CloudKit lifecycle
  logs with `service.name=bleat`. Native macOS does not create remote telemetry
  state or send OTLP.

Both producers ultimately write the standard ClickHouse OpenTelemetry tables
queried by HyperDX. Neither producer sends telemetry to the HyperDX API or the
ClickStack-managed Collector.

## Control plane and data plane

Telemetry authentication and telemetry delivery are separate protocols.

The authentication control plane is:

```text
iOS
  -> bleat-api App Attest enrollment and assertion endpoints
  -> short-lived ES256 JWT
```

`bleat-api` verifies App Attest evidence and installation assertion counters.
The issued JWT has the exact production issuer, `aud=bleat-telemetry`, the
single-purpose `telemetry:write` scope, an opaque subject, and a ten-minute
lifetime. The JWT remains memory-only on the device.

The telemetry data plane is:

```text
bleat-api
  -> internal unauthenticated OTLP/HTTP receiver
                       \
                        bleat-otel-collector
                       /        |
iOS -> Cloudflare HTTPS         v
  -> OIDC-authenticated     ClickHouse -> HyperDX
     OTLP/HTTP receiver
```

One stock OpenTelemetry Collector Contrib process owns both receivers and the
shared traces and logs pipelines. It exports directly to ClickHouse.

## Collector receiver boundaries

The Collector pod listens on two distinct ports:

| Receiver | Pod port | Authentication | Exposure |
| --- | ---: | --- | --- |
| Device OTLP/HTTP | 4318 | Collector `oidc` extension; exact issuer and `bleat-telemetry` audience | Only through the `bleat-telemetry-ingress` ClusterIP service and Cloudflare Tunnel |
| API OTLP/HTTP | 4319 | None | Only through the internal `bleat-otel-collector` ClusterIP service |

The internal service keeps its stable endpoint
`http://bleat-otel-collector.bleat.svc.cluster.local:4318` and maps that service
port to pod port 4319. The API therefore needs no bearer token and does not need
to change its configured endpoint.

The public `bleat-telemetry-ingress` service maps port 4318 only to the
authenticated device receiver. The Cloudflare public hostname must never point
at the internal API receiver.

The OIDC authenticator validates the bearer signature, issuer, audience, and
standard time claims through `bleat-api` discovery and JWKS. Stock Collector
authentication cannot hard-reject an arbitrary custom scope claim. That is not
an additional authorization boundary while `bleat-api` issues only the narrow
telemetry token for this issuer and audience. The bearer token, its claims, and
the App Attest evidence are not copied into exported telemetry. Bleat's separate
random app-installation identifier is included as `service.instance.id` and is
propagated to `bleat-api` with W3C baggage so both services can be queried by the
same opaque correlation key. The complete authentication dance is recorded as
`bleat.telemetry.authentication`; its `bleat.telemetry.challenge`,
`bleat.telemetry.enrolment`, and `bleat.telemetry.token` HTTP client spans inject
W3C trace context so the corresponding `bleat-api` server spans have the client
request spans as their distributed parents.

## Transport and trust

The iOS application sends protobuf OTLP/HTTP requests to the standard
`/v1/traces` and `/v1/logs` paths over HTTPS using `URLSession`, system trust,
and the negotiated HTTP version. OTLP/HTTP is intentional because Cloudflare
Tunnel public hostnames do not support gRPC. This changes OTLP framing, not the
external HTTPS requirement.

Cloudflare terminates the public TLS connection and forwards HTTP to the
authenticated ClusterIP receiver inside the Kubernetes network. The API also
uses HTTP only across the private cluster network. There is no trust-all TLS
mode, certificate pin, public cleartext listener, NodePort, or LoadBalancer.

## Processing and operational bounds

Both receivers feed the same log and trace pipelines. The device receiver caps
decoded requests at 1 MiB. Receiver read timeouts, Collector and pod memory
limits, explicit batch sizes, finite ClickHouse retry, and a bounded exporter
queue prevent an unavailable destination from creating unbounded work.

The stock OTLP/HTTP receiver does not expose a hard maximum concurrent-request
count. Do not claim that it does. Concurrency pressure is bounded indirectly by
request timeouts, the memory limiter, the exporter queue, and pod CPU and memory
limits. Add a separate, measured control only if production evidence shows
these bounds are insufficient; do not introduce a proxy solely to manufacture
a nominal request counter.

Application telemetry is best effort. Collector, ClickHouse, HyperDX,
Cloudflare, authentication, or network failure must not affect API request
handling or application behavior. The iOS persistence and retry bounds remain
defined in `docs/audiobookshelf-ios-app-spec.md`.

## Initial rollout and monitoring

Remote telemetry remains default-off and requires an explicit device-local
opt-in. The initial trace sampler deliberately retains 100% of opted-in spans.
That is not probabilistic sampling: the conservative boundary is the closed,
low-volume operation and attribute allowlist, combined with the 1 MiB ingress
limit, bounded client retention, finite Collector queue, and workload resource
limits. Revisit the sampler before expanding either the signal allowlist or the
eligible population.

The deployment operator monitors these privacy-safe aggregate signals:

- telemetry-authentication request, rejection, rate-limit, and 5xx rates;
- Collector receiver rejection, exporter failure, retry, and queue-exhaustion
  signals;
- API and Collector restart count, CPU, and memory against their limits;
- daily telemetry ingestion and retained-storage growth.

Investigate when authentication or export errors exceed 5% for ten minutes,
when any Collector queue is exhausted, or when daily ingestion exceeds twice
the trailing seven-day median. During initial rollout, review these signals
after each release and at least daily. A sustained threshold breach triggers
the telemetry kill switch while the operator determines whether the cause is
abuse, regression, backend failure, or unexpected cost growth.

## Telemetry kill switch

The server-side kill switch is the `bleat-api` deployment itself. Activate it
by scaling only the `bleat-api` deployment in the `bleat` namespace to zero
replicas. Keep PostgreSQL and the OpenTelemetry Collector running. This stops
new enrollment and token issuance immediately without an application update or
an additional control endpoint.

Previously issued JWTs remain valid until their ten-minute expiry, so accepted
device ingestion can continue for at most that window. If an incident requires
immediate ingestion shutdown, separately disable the public device Collector
route; that stronger response is not the normal kill switch.

If the JWT signing private key is compromised, scaling only `bleat-api` to zero
is insufficient because the key holder can mint new tokens without the API.
Follow `docs/operations/jwks-revocation.md` to remove the key, replace the
Collector's cached verifier state, prove old-key rejection, and restore ingress.

API unavailability is isolated from launch, Audiobookshelf login, browsing,
downloads, playback, synchronization, and transcription. Telemetry token
renewal backs off, completed spans remain within the two-hour and 128 MiB local
bounds, and foreground export retries cap at one attempt per minute. The
disposable recovery journey stops the API, proves an ordinary cached library
refresh remains prompt, retains the failed telemetry batch, then restores the
API and drains without reenrollment.

Restore service by returning `bleat-api` to one replica. Wait for `/readyz` to
report ready, confirm a new telemetry token can be issued, and confirm retained
telemetry drains before declaring recovery complete. Reconcile any temporary
deployment override with the declarative infrastructure configuration so a
later deployment cannot unexpectedly reapply the emergency state.

Follow `docs/operations/bleat-api-scaling.md` for the complete scale-up,
scale-down, verification, and restoration procedure.

## Production retention and access

The production ClickHouse tables delete traces after seven days and logs after
90 days. Those table TTLs are the authoritative retention controls for both
the iOS and API signals; the Collector does not retain a second durable copy.
The iOS application may hold undelivered span batches locally for at most two
hours and deletes them after successful delivery or consent withdrawal.

Telemetry-authentication state is separate from the diagnostic signals.
PostgreSQL retains the opaque installation UUID, App Attest key identifier and
public key, environment, status, assertion counter, and timestamps. Challenge
rows retain only a digest and lifecycle metadata. These authentication records
currently have no automatic expiry and remain until an operator deletes them or
the service is decommissioned. Withdrawing consent immediately stops new
authentication and export and removes local telemetry state, but does not
delete an existing server enrollment.

Production signal queries are limited to the deployment operator through the
credential-protected HyperDX service. Direct ClickHouse and PostgreSQL access
is limited to cluster workloads and administrators holding the corresponding
deployment credentials. Telemetry is not sold, used for advertising or
tracking, or shared with a data broker. Access is for operating, securing, and
improving Bleat, including investigating typed failures and performance.

The authentication service's server spans retain the resolved client network
address and bounded user-agent when present. They do not retain authorization
headers, JWT claims, App Attest evidence, request bodies, account or media data,
or copy the opaque installation subject into exported telemetry. Because a
network address can still be associated with a device, the App Store privacy
declaration treats the corresponding other diagnostic data as linked.

## Explicit non-designs

Bleat telemetry does not use:

- an Envoy or other separate authentication gateway;
- JWT translation into a HyperDX ingestion key;
- the ClickStack-managed ingestion Collector;
- per-installation quotas or accounting;
- authentication headers, JWT claims, account data,
  server addresses, media values, URLs, or paths as exported log/span fields;
- remote OpenTelemetry export from native macOS.

The disposable `mise run test:telemetry` environment uses an authenticated
stock Collector followed by a private capture Collector. The capture Collector
is a test sink, not an additional production authentication layer.

## Verification

`mise run test:telemetry` is the repository contract for the authenticated
device receiver. It first runs the focused Swift telemetry and complete Rust
authentication-service suites, then validates the Collector configurations and
proves real JWT authentication, OTLP/HTTP delivery, rejection, request-size,
outage recovery, relaunch without token persistence, and wire privacy behavior
against generated test credentials. It also resolves and asserts the exact
Collector limits, exhausts the bounded exporter queue, and proves the capture
sink remains isolated on its internal network. The criterion-to-test mapping is
maintained in `docs/requirements-traceability.md`.

Production verification must independently prove both receiver paths:

- recent `service.name=bleat-api` logs and spans continue through the internal
  receiver;
- missing or malformed device credentials receive HTTP 401 from the Collector;
- an opted-in physical iOS run obtains a JWT and produces
  `service.name=bleat` logs or spans in ClickHouse and HyperDX;
- Collector refusal, export-failure, and queue metrics remain healthy;
- the unauthenticated API receiver is absent from every public route.
