# Telemetry App Store privacy and archive evidence

Release evidence for [GitHub issue
#113](https://github.com/terminaloutcomes/bleat/issues/113). This record applies
to the exact signed archive inspected below. Remote telemetry is iOS-only,
explicit opt-in, and default-off.

This evidence predates the addition of `service.instance.id` to exported
telemetry. A subsequent archive and App Store declaration must mark Product
Interaction and Performance Data as linked before this evidence can be treated
as current for a new release.

## Artifact

| item | recorded value |
| --- | --- |
| source commit | `d38b8f21fe77228736cfded7b677a32f2aa4dadd` |
| app version | 0.1.2 |
| build | 1 |
| archive | signed iOS Release archive |
| Xcode | 26.6 (17F113) |
| SDK | iPhoneOS 26.5 (23F81a) |
| minimum OS | iOS 26.0 |

`mise run archive` completed from the committed source. The repository-owned
archive inspector verified the archived version and privacy settings, the deep
code signature, package linkage, bundled privacy manifests, and dynamic-library
boundary. No signing identity, team identifier, credential, device identifier,
or private account identifier is retained in this evidence.

## App privacy declaration

The App Store Connect declaration was published on 2026-08-23 with this exact
matrix:

| collected data | purpose | linked to identity | tracking |
| --- | --- | --- | --- |
| Identifiers / Device ID | App Functionality | yes | no |
| Usage Data / Product Interaction | Analytics | no | no |
| Diagnostics / Performance Data | App Functionality | no | no |
| Diagnostics / Other Diagnostic Data | App Functionality | yes | no |

The Device ID answer covers the opaque persistent installation UUID used for
App Attest enrollment and telemetry-upload authentication. It is not copied
into exported telemetry, but the authentication service retains it as a stable
installation principal, so it is conservatively declared linked.

Product Interaction and Performance Data use only the reviewed telemetry
allowlist. Account identifiers, installation identifiers, audiobook content,
credentials, server addresses, searches, transcripts, filesystem paths, and
media URLs are excluded. The Collector validates the bearer token but does not
copy its opaque subject into exported telemetry.

Other Diagnostic Data is declared linked because authentication-service server
spans may retain the resolved client network address and a bounded user-agent.
No declared data is used for advertising, cross-app tracking, sale, or sharing
with a data broker.

The application privacy manifest contains the same four collected-data rows,
sets tracking to false, declares no tracking domains, and retains the required
reasons for Disk Space (`E174.1`), File Timestamp (`C617.1`), and User Defaults
(`CA92.1`). The Xcode aggregate privacy report matched the four-row matrix and
reported no additional required-reason or collected-data finding.

The consent text in Settings identifies the bounded technical data and
exclusions. Consent can be withdrawn at any time. Withdrawal stops new remote
telemetry and token renewal, clears memory-only credentials, and purges buffered
telemetry without affecting local Diagnostics. Production signal retention is
seven days for traces and 90 days for logs; authentication enrollment has no
automatic expiry. Access and retention boundaries are documented in
`docs/architecture-logging.md`.

The public Privacy Policy and User Privacy Choices URLs remain separately
tracked by [GitHub issue
#118](https://github.com/terminaloutcomes/bleat/issues/118); that release-metadata
task does not change the published data-category answers recorded here.

## Package and archive inspection

The archive contains these privacy manifests:

- the application `PrivacyInfo.xcprivacy`;
- `AppAuth_AppAuthCore.bundle/PrivacyInfo.xcprivacy`;
- `SwiftProtobuf_SwiftProtobuf.bundle/PrivacyInfo.xcprivacy`.

Relevant resolved versions and final archive linkage:

| package | version | archive result |
| --- | --- | --- |
| AppAuth iOS | 2.0.0 | linked statically; privacy manifest bundled |
| OpenTelemetry Swift | 2.4.1 | linked statically |
| OpenTelemetry Swift Core | 2.4.1 | linked statically |
| SwiftProtobuf | 1.38.1 | linked statically; privacy manifest bundled |
| Swift Crypto | 4.5.1 | resolved, not linked |
| SwiftNIO | 2.101.3 | resolved, not linked |
| SwiftNIO SSL | 2.37.2 | resolved, not linked |

The signed app embeds no third-party dynamic frameworks. The application links
only system dynamic libraries; archive symbol inspection found no linked
SwiftNIO, NIOSSL, BoringSSL, or Swift Crypto implementation. AppAuth is consumed
as source and linked into the signed application rather than shipped as an
independently signed binary SDK. The final application code signature passed
deep strict verification.

Apple's current [third-party SDK
requirements](https://developer.apple.com/support/third-party-SDK-requirements/)
require privacy manifests for listed SDKs and signatures when those SDKs are
included as binary dependencies. The archive result satisfies the applicable
source-package and final-signature boundary.

## Encryption and export compliance

The shipped app uses standard HTTPS through Apple networking and security
facilities, App Attest/CryptoKit for authentication proof, and source-linked
AppAuth for OAuth authorization. It does not ship a linked SwiftNIO SSL,
BoringSSL, Swift Crypto, or other non-system encryption implementation.

`ITSAppUsesNonExemptEncryption` is therefore `false` in the shipped app. For
this artifact, the App Store export-compliance answer is that the app does not
use non-exempt encryption and no separate export-compliance document is
required. This decision is based on the inspected archive and Apple's current
[encryption export-regulation
guidance](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)
and [App Store Connect export-compliance
overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/).
It must be reassessed if the linked dependency graph or cryptographic behavior
changes.

## Verification result

The signed archive workflow passed twice while this evidence was prepared. The
final run used the committed source recorded above and passed all manifest,
version, package-linkage, code-signature, and dynamic-framework checks. The
published App Store declaration was then compared with the archived privacy
manifest and the Xcode aggregate report; all four rows match.
