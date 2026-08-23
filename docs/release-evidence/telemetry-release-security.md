# Telemetry release security evidence

Release evidence for [GitHub issue
#114](https://github.com/terminaloutcomes/bleat/issues/114). This record evaluates
the current source tree at the commit below. It makes no Git-history claim and
contains no signing identity, credential, device identifier, private key, or
private deployment value.

## Evaluated source

| item | recorded value |
| --- | --- |
| source commit | `b19161b986107211331a4129fd8e33eb111b1052` |
| evaluation date | 2026-08-24 (Australia/Brisbane) |
| pull request | [#122](https://github.com/terminaloutcomes/bleat/pull/122) |
| security workflow | [run 32645898196](https://github.com/terminaloutcomes/bleat/actions/runs/32645898196) |

## Secret scanning

Gitleaks is pinned through `mise.toml` at 8.30.1 and reported version 8.30.1.
`mise run security:secrets` generated private-key, Apple `.p8`, PKCS#12,
provisioning-profile, and telemetry-JWT signing-key fixtures. The unsafe fixture
set produced six expected findings across all four repository rules. The public
Apple certificate and public JWKS fixtures produced no findings. The final
current-source scan covered 5.76 MB of Git-tracked and non-ignored files and
produced no findings.

Generated build products are excluded by constructing the scan input from the
current Git index plus non-ignored working-tree files. Public certificates and
JWKS remain allowed; private PEM/PKCS#8 material and private signing or
provisioning artifact paths remain rejected.

The pull-request `repository-security` job passed with repository permission
limited to `contents: read`. The workflow has no `pull_request_target` trigger
and requests no Actions, identity-token, package, deployment, signing, or secret
permission. The existing release workflow runs only after a push to `main`,
uses repository variables rather than production credentials for telemetry
endpoints, and does not expose signing or deployment secrets. The container
workflow does not push for external-fork pull requests.

## Dependency review

`cargo-audit` is pinned and installed through mise package version 0.22.2. The
installed executable identifies itself as `cargo-audit-audit 0.22.0`; both
values are retained here to avoid overstating the embedded binary metadata.
The RustSec advisory database revision was
`bf5c0d245a92671908518d7e765914d437954ed6`, dated 2026-08-21. The audit loaded
1,225 advisories and scanned 544 locked Rust crates with yanked crates denied.

Two reviewed exceptions are retained in `.cargo/audit.toml`:

- `RUSTSEC-2026-0235`: `rkyv` is lockfile-only through an optional
  `rust_decimal` edge and is absent from the enabled feature graph. The gate
  fails if that graph boundary changes.
- `RUSTSEC-2023-0071`: `compact_jwt` includes affected RSA support without a
  feature boundary and has no fixed release. Bleat signs, publishes, accepts,
  and validates ES256 only; its tests reject non-EC material.

The direct unmaintained `rustls-pemfile` dependency was removed. Certificate
loading now uses the already-required `rustls-pki-types` package, and the two
focused trust-material tests passed.

The final resolved Swift graph includes AppAuth 2.0.0, OpenTelemetry Swift and
Core 2.4.1, SwiftProtobuf 1.38.1, Swift Crypto 4.5.1, SwiftNIO 2.101.3, and
SwiftNIO SSL 2.37.2. GitHub reported 616 packages in the repository SBOM and
zero open Dependabot alerts at evaluation time. The dependency-review action,
pinned to commit `a1d282b36b6f3519aa1f3fc636f609c47dddb294`, passed on pull
request #122 with `fail-on-severity: low`.

## Kill-switch validation

The telemetry kill switch is an operational scale-to-zero of `bleat-api` while
PostgreSQL and the Collector remain running. New enrollment and token issuance
stop immediately. Previously issued ten-minute JWTs can permit an ingestion
tail of at most ten minutes; immediate ingestion shutdown requires separately
disabling the public Collector route.

`mise run test:telemetry` passed against disposable local containers without
touching production. Its three recovery tests passed. In
`testApiShutdownKillSwitchRetainsThenRelaunchDrainsWithoutReenrollment`, API
shutdown made token renewal fail with the typed temporary-unavailability state,
an ordinary cached library refresh completed within its 100 ms bound, retained
telemetry stayed within the configured storage limit, and restoration issued a
new token and drained delivery using the original enrollment. The restarted
ephemeral development API also rejected the token signed by the replaced key.

Restoration returns the API to one replica, waits for `/readyz`, verifies token
renewal and retained delivery, then reconciles the declarative deployment
state. Client retry, retention, and storage bounds remain unchanged.

## Rollout, monitoring, and retention

Remote telemetry remains default-off and explicit opt-in. Opted-in traces retain
100% of spans by deliberate policy; this is not probabilistic sampling. The
closed operation and attribute allowlist, 1 MiB ingress limit, bounded client
storage and retention, finite Collector queue, and workload resource limits are
the conservative controls.

The documented monitoring posture covers authentication rejection, rate-limit,
and 5xx rates; Collector receiver rejection, exporter failure, retry, and queue
exhaustion; API and Collector resources and restarts; and daily ingestion and
storage growth. Escalation occurs above 5% authentication or export errors for
ten minutes, on any queue exhaustion, or when daily volume exceeds twice the
trailing seven-day median. Sustained breaches activate the kill switch.

Production retention remains linked to `docs/architecture-logging.md`: traces
expire after seven days and logs after 90 days, with access limited to the
private backend boundary. `APP-TELEMETRY-SECURITY-001` links this evidence from
`docs/requirements-traceability.md`; issue #36 retains the release-readiness
dependency.

## Validation result

The source commit recorded above passed:

- `mise run security:validate`, locally and in the pull-request security job;
- `mise run test:telemetry`, including all three live recovery tests;
- the two focused Rust trust-material tests;
- all pull-request checks, including the pinned dependency review and both
  container architectures.

The local `mise run check` execution passed its security, API formatting,
Clippy, Rust unit/integration/process, API Release build, telemetry, site, Swift
host, Swift Release, and app-test stages before the serial UI stage reported 33
passes, four intentional skips, and two failures. The telemetry-consent failure
passed a focused rerun. The unrelated restored-account test failed again because
`diagnostics.webSocketState` was absent; issue #114 changes neither that UI nor
its test. This limitation is retained rather than represented as a complete
local gate pass.
