# Contributing to Bleat

Read the [repository instructions](https://github.com/terminaloutcomes/bleat/blob/main/AGENTS.md), [architecture](architecture.md),
and the relevant [specification](audiobookshelf-ios-app-spec.md) sections before
editing. The [development guide](development.md) is the canonical command
reference; this page explains how to choose and prepare those workflows.

## Clean-checkout setup

Use macOS 26 or newer and an Xcode toolchain providing Swift 6.2 or newer.
`Package.swift` and `project.yml` both require macOS 26/iOS 26. Install an iOS
Simulator runtime for application tests and Docker Compose 2 for disposable
server and PostgreSQL tests. The Cargo workspace requires Rust 1.97 or newer.
XcodeGen 2.46 or newer is needed to regenerate the main project and by the
signed host-test workflow. Install mise and XcodeGen through your package
manager, and install/select Xcode with its command-line tools. Install mdBook
through your package manager to render the documentation.

The ignored `.envrc` must exist before code work or building. Obtain the local
configuration from the maintainer for signed or production workflows; never
copy another contributor's credentials, signing material, or device identifiers.
For unsigned development only, create this deliberately non-production file:

```sh
(
set -C
cat > .envrc <<'CONFIG'
BLEAT_TELEMETRY_AUTH_BASE_URL=https://telemetry-auth.invalid
BLEAT_TELEMETRY_OTLP_ENDPOINT=https://telemetry-otlp.invalid
CONFIG
)
mise install
xcodebuild -version
swift --version
rustc --version
```

`mise.toml` loads `.envrc` as an environment file. Do not assume it is a shell
script or that direct Xcode/Swift/Cargo invocations load it. For direct commands,
export their required settings in the invoking shell. Xcode GUI builds require
telemetry build settings configured explicitly. The `.invalid` URLs satisfy
unsigned build validation but provide no working telemetry service.

| Workflow | Additional local configuration |
| --- | --- |
| Unsigned focused package tests | `BLEAT_HOST_SIGNING=unsigned`; synchronizable-Keychain validation is excluded |
| Complete signed host tests | `BLEAT_DEVELOPMENT_TEAM`, Apple Development identity, provisioning access |
| Simulator app tests | Telemetry URL settings; installed iOS runtime; see build-mode instructions |
| Personal Team builds | Explicit `BUILD_WITHOUT_PAID_DEVELOPER=YES`; CloudKit, App Attest, and CarPlay are disabled |
| Paid-team device builds | Team and selected device ID, authorized profiles, real HTTPS telemetry configuration |
| Live/server/backend tests | Docker; harness-generated credentials and disposable state |
| Production archive/upload | Production URLs, distribution authorization and secrets; development guide release procedure |

Never substitute an unsigned result for signed-Keychain evidence. Do not weaken
trust settings or relocate personal configuration to make tests pass. Preserve
existing `.envrc` contents and unrelated worktree changes.

## Choose validation

Start with the narrowest meaningful check, then use the broader gates required
by the affected behavior. Host resources require normal execution permissions.

| Change | Validation | Evidence and artifacts |
| --- | --- | --- |
| Core Swift logic | Focused Swift Testing, then `scripts/test-host.sh` when relevant | Host XML in `.build/host-results/`; signed lane rejects skips; unsigned excludes the named Keychain test |
| App model/framework adapter | Focused app-hosted Xcode tests | `.xcresult`; verify requested identities, count, and individual outcomes |
| UI/navigation, shared UI fixtures/helpers, playback/synchronization used by UI journeys | Focused repetitions and owning suite, mandatory local broad UI gate; accessibility/live tasks when affected | [Review checklist and broad UI receipt](test-reliability.md#change-review-checklist); Simulator evidence only; no physical routing/background claim |
| Audiobookshelf contract | `mise run test:compatibility`, redacted versioned fixtures | Both minimum/current profiles; root and prefixed routes; harness artifacts |
| Playback/download/offline integration | `mise run test:app-live` | Disposable HTTPS server and Simulator; harness cleanup; no device claim |
| Persistence/CloudKit | Migration fixtures/tests, `mise run test:cloudkit-schema` | Local migration and schema checks; signed two-device evidence remains separate |
| Telemetry/backend | `mise run api:validate`, `mise run test:telemetry` | Disposable PostgreSQL and Collector; physical App Attest evidence separate |
| Website/docs | `mise run docs:check`, `mise run site-check`, mdBook build | Links/tasks/navigation and rendered content; no external URL availability guarantee |
| Packaging/version | `mise run release:check`, supported archive workflow | Built metadata, privacy manifest, entitlements; upload/device validation separate |

`mise run check` is an aggregate gate, not a read-only command: it runs
`swift-fmt` and Rust validation dependencies run `rust:fmt`. API validation also
has formatting dependencies. Review `git diff` afterward and preserve unrelated
edits. Website checks install locked frontend dependencies and generate ignored
CSS; live gates create and remove their disposable resources. Use read-only
`swift-lint` and `cargo fmt --all -- --check` when formatting must not edit files.

## Codex validation permissions

The four command prefixes in `.codex/rules/bleat-validation.rules` allow host
execution outside the sandbox: unsigned Swift package tests through mise,
the host-test script through mise, strict Swift lint, and the documentation
checker. Prefix matching permits arbitrary remaining arguments. These commands
can execute repository code and access host resources, including signing state
where the selected workflow uses it; the rules are not a filesystem boundary.

Codex loads project-local rules at startup only when the project's `.codex`
configuration layer is trusted. Restart Codex after adding or updating the file.
New worktrees based on a commit containing it inherit the file and use their own
`.codex` layer; existing chats do not retroactively load it. More restrictive
rules or managed policy can still require approval or deny execution. Compound
shell commands and redirection may not match these prefixes. See the
[Codex rules documentation](https://learn.chatgpt.com/docs/agent-configuration/rules).

Check syntax and matching without executing the validation command:

```sh
codex execpolicy check --pretty --rules .codex/rules/bleat-validation.rules -- mise run docs:check
```

This checks the supplied rules file only; it does not demonstrate live loading
or guarantee that a running chat will execute without a prompt.

## Focused tests and evidence

Unsigned package tests use Swift Testing rather than XCTest discovery:

```sh
BLEAT_HOST_SIGNING=unsigned swift test --disable-xctest --no-parallel --filter TokenVaultTests
```

For complete signed host coverage, use `scripts/test-host.sh` with the configured
team. Add, rename, or remove identities in `TestSupport/HostTests/inventory.json`
when changing host tests. Preserve the inventory's function identity convention
for parameterized tests. Zero tests, missing/duplicate identities, unexpected
skips, runtime warnings, and crashes require investigation.

Application tests must run through Xcode, not `swift test`. From a configured
shell, select a fresh result-bundle path and an installed destination:

```sh
xcodebuild -project Bleat.xcodeproj -scheme Bleat \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -resultBundlePath .build/focused-documentation.xcresult \
  -only-testing:BleatAppTests/DocumentationLinkTests test
xcrun xcresulttool get test-results tests --path .build/focused-documentation.xcresult
```

Inspect every requested identifier and its outcome, not just the command exit.
Replace the class selection for your change; the example exercises the real
app-hosted documentation-link tests. Ordinary Simulator tests do not prove
Bluetooth, AirPlay, CarPlay head-unit, background, or physical-device behavior.

## Change persistence

1. Inspect `BleatPersistenceSchemaHistory`, `BleatPersistenceModelCatalog`, the
   affected SwiftData records, and account-scoped repository behavior. Preserve
   historical schema definitions; add the appropriate current schema and
   migration stage rather than rewriting a shipped shape.
2. Add a fixture for the real older persisted shape, including valid bytes with
   missing optional metadata. Keep fixtures redacted and versioned under
   `Tests/BleatCoreTests/Fixtures/Persistence/`.
3. Extend `PersistenceMigrationTests` and catalog coverage for the upgrade,
   retained records, account separation, and recovery boundary. Include removal
   and local-data lifecycle tests when ownership or deletion changes.
4. Recover absent fields only from authoritative, unambiguous local data.
   Otherwise preserve records, surface typed reconciliation failure, and emit
   the exact privacy-safe cause and processing stage. Do not fall through to a
   network-dependent path for downloaded playback.
5. For private CloudKit changes, update the desired schema and run schema
   validation. Production promotion and its tracked snapshot are separate from
   local code/schema consistency; follow the development guide.
6. Update the specification and traceability with actual implementation and
   evidence. Never equate a host migration test with signed-device recovery.

## Documentation checks

Run `mise run docs:check`. The Rust checker reads repository Markdown,
`docs/SUMMARY.md`, website content/front matter, and `mise.toml`; it checks local
paths, Markdown anchors, reference links, website routes, named task
references, and links to chapters missing from mdBook navigation. Diagnostics identify a project-relative file, line, and stable code.
It does not access the network or rewrite files. Generated output, dependency
checkouts, and disposable artifacts are excluded.

`docs/SUMMARY.md` contains mdBook part headings and page links in the supported
list hierarchy. Keep historical records in `docs/historical/`. Put overview
prose and evidence status on the linked pages.
Explicit heading IDs and duplicate headings are supported by the checker.
Non-Markdown target anchors and external URLs require the appropriate renderer
or human review. Render with `mdbook build --dest-dir .build/mdbook` and review
new pages alongside `mise run site-check`. Semantic scope and evidence claims
always require source inspection and review.

## Handoff

- Inspect the final diff and preserve unrelated source and configuration.
- Explain the behavior/documentation changes and which canonical references changed.
- Report exact checks, executed counts, exclusions, and artifact locations.
- Resolve or explicitly retain warnings, failures, and missing evidence.
- Distinguish host, Simulator, disposable-server, signed-host, and physical-device validation.
- Audit changed and adjacent failure/callback paths for traps, actor assumptions,
  cancellation reentrancy, and stale-operation acceptance.
- Complete the [test change review checklist](test-reliability.md#change-review-checklist),
  link required local broad UI evidence and revisit affected audit sign-offs.
- Update traceability for affected requirements without treating old results as
  fresh validation. Do not commit, push, or publish without authorization.
