# Logging and telemetry architecture

This document is the source of truth for how Bleat produces, authenticates,
transports, stores, and queries diagnostic logs and traces. The product and
privacy rules remain defined in `docs/audiobookshelf-ios-app-spec.md`; this
document defines the deployment topology and component boundaries.

## Signals and identities

Bleat has two telemetry producers:

- `bleat-api` emits structured logs and server spans with
  `service.name=bleat-api`. Local stderr logging remains active if remote
  export fails or is not configured.
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
the opaque installation subject are not copied into exported telemetry.

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

## Explicit non-designs

Bleat telemetry does not use:

- an Envoy or other separate authentication gateway;
- JWT translation into a HyperDX ingestion key;
- the ClickStack-managed ingestion Collector;
- per-installation quotas or accounting;
- authentication headers, JWT claims, installation identifiers, account data,
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
