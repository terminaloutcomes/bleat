# Requirements Traceability

This file links specification requirements to implementation and verification.
Add a row before implementing a requirement and retain its ID for the life of
the project.

Status values are `not-started`, `in-progress`, `implemented`, and `verified`.
“Verified” means the listed automated test currently passes.

| ID | Specification | Requirement | Implementation | Evidence | Status |
| --- | --- | --- | --- | --- | --- |
| CORE-ID-001 | 3.1, 7, 12.1, 13 | Remote IDs stay opaque and domain-specific IDs cannot be mixed | `Sources/BleatCore/Identifiers.swift` | `IdentifiersTests` | verified |
| URL-001 | 6.1 | A configured server URL requires HTTPS and a host | `Sources/BleatCore/ServerURL.swift` | `ServerURLTests.testRejectsNonHTTPSAndMissingScheme`, `testRejectsMissingHost` | verified |
| URL-002 | 6.1 | Embedded credentials are rejected | `Sources/BleatCore/ServerURL.swift` | `ServerURLTests.testRejectsEmbeddedCredentials` | verified |
| URL-003 | 6.1 | Query and fragment are removed during normalization | `Sources/BleatCore/ServerURL.swift` | `ServerURLTests.testRemovesQueryAndFragment` | verified |
| URL-004 | 6.1 | The path prefix is retained and only the final trailing slash is removed | `Sources/BleatCore/ServerURL.swift` | `ServerURLTests.testNormalizesHostAndFinalTrailingSlash`, `testRemovesOnlyOneFinalTrailingSlash`, `testPreservesEncodedPathPrefix` | verified |
| ROUTE-001 | 3.1, 6.1, 15 | Audited endpoint paths are centralized under the normalized server base | `Sources/BleatCore/AudiobookshelfRoute.swift` | `AudiobookshelfRouteTests.testBuildsEveryAuditedRouteUnderServerPrefix` | verified |
| ROUTE-002 | 3.1, 7 | Opaque remote IDs are encoded as single path components | `Sources/BleatCore/AudiobookshelfRoute.swift` | `AudiobookshelfRouteTests.testPercentEncodesOpaquePathComponents`, `testEncodesTraversalLikeOpaqueIDWithoutChangingRoute` | verified |
| ROUTE-003 | 3.2, 6.4, 9.3, 10.1 | Access tokens are never accepted as route query items | `Sources/BleatCore/AudiobookshelfRoute.swift` | `AudiobookshelfRouteTests.testRejectsTokenQueryItems`, `testRejectsTokenBearingReturnedPaths` | verified |
| ROUTE-004 | 9.3 | Direct-play URLs use the public session route under the server path prefix | `Sources/BleatCore/AudiobookshelfRoute.swift` | `AudiobookshelfRouteTests.testBuildsEveryAuditedRouteUnderServerPrefix` | verified |
| ROUTE-005 | 9.3 | Returned HLS paths are server-base-relative rather than origin-relative | `Sources/BleatCore/AudiobookshelfRoute.swift` | `AudiobookshelfRouteTests.testAppendsReturnedHLSPathUnderServerPrefix`, `testReturnedPathMayOmitLeadingSlashAndPreserveSafeQuery` | verified |
| ROUTE-006 | 9.3, 17 | Absolute, traversal, fragment-bearing, and token-bearing returned media paths are rejected | `Sources/BleatCore/AudiobookshelfRoute.swift` | `AudiobookshelfRouteTests.testRejectsUnsafeReturnedPaths`, `testRejectsTokenBearingReturnedPaths` | verified |
| ROUTE-007 | 11.3 | Bookmark times retain integer or fractional path representation | `Sources/BleatCore/AudiobookshelfRoute.swift` | `AudiobookshelfRouteTests.testFormatsWholeSecondBookmarkWithoutDecimalSuffix`, `testBuildsEveryAuditedRouteUnderServerPrefix` | verified |
| DISCOVERY-001 | 3.1, 6.1 | Status decoding matches the pinned 2.36.0 implementation and ignores unknown fields | `Sources/BleatCore/ServerDiscovery.swift` | `ServerDiscoveryTests.testDecodesPinnedLiveStatusFixture`, `ServerStatusLiveTests.testPinnedRootAndPrefixStatusContracts` | verified |
| DISCOVERY-002 | 6.1 | Discovery requires the Audiobookshelf app marker and an initialized server | `Sources/BleatCore/ServerDiscovery.swift` | `ServerDiscoveryTests.testRejectsInvalidServerResponses` | verified |
| DISCOVERY-003 | 2, 6.1 | Versions older than 2.26.0 and malformed versions are rejected | `Sources/BleatCore/ServerDiscovery.swift` | `ServerDiscoveryTests.testRejectsInvalidServerResponses`, `testServerVersionOrderingAndPrereleaseParsing` | verified |
| DISCOVERY-004 | 3.1, 6.1 | Unknown authentication methods do not break status decoding | `Sources/BleatCore/ServerDiscovery.swift` | `ServerDiscoveryTests.testUnknownAuthenticationMethodIsPreserved` | verified |
| DISCOVERY-005 | 6.1 | Same-origin redirects are bounded and cross-origin redirects require confirmation | `Sources/BleatCore/HTTPTransport.swift`, `Sources/BleatCore/ServerDiscovery.swift` | `ServerDiscoveryTests.testFollowsOneSameOriginRedirectAndUpdatesBasePath`, `testRequiresConfirmationForCrossOriginRedirect`, `testRejectsSecondRedirect` | verified |
| DISCOVERY-006 | 6.1, 15 | Root and `/audiobookshelf` status routes work against a fresh pinned live server | `TestSupport/ServerHarness/compose.yaml` | `ServerStatusLiveTests.testPinnedRootAndPrefixStatusContracts` through `scripts/test-live.sh` | verified |
| AUTH-001 | 6.2 | Local login requests JSON tokens and validates the access token before persistence | `Sources/BleatCore/Authentication.swift` | `AuthenticationTests.testLocalLoginValidatesBeforePersistingCredentials`, `testLocalLoginRejectsInvalidAuthorizationWithoutPersisting` | verified |
| AUTH-002 | 6.2, 7 | Authorized user identity and permission fields are decoded without exposing remote DTOs | `Sources/BleatCore/AuthenticationModels.swift` | `AuthenticationTests.testLocalLoginValidatesBeforePersistingCredentials` | verified |
| AUTH-003 | 3.2, 6.4 | Access tokens are applied only as HTTPS bearer headers and token-bearing URLs are rejected | `Sources/BleatCore/Authentication.swift` | `AuthenticationTests.testBearerAuthorizerAddsHeaderWithoutChangingURL`, `testBearerAuthorizerRejectsUnsafeRequestOrToken` | verified |
| AUTH-004 | 6.4, 14.1 | Each account's rotating token pair is stored as one non-synchronizing, after-first-unlock device-only Keychain item | `Sources/BleatCore/TokenVault.swift` | `TokenVaultTests.testRoundTripReplacementIsolationAccessibilityAndDeletion` | verified |
| AUTH-005 | 6.2, 15 | Root and `/audiobookshelf` login and bearer authorization work against fresh pinned servers | `Tests/BleatCoreLiveTests/LocalAuthenticationLiveTests.swift` | `LocalAuthenticationLiveTests.testPinnedRootAndPrefixLocalAuthenticationContracts` through `scripts/test-live.sh` | verified |
| AUTH-006 | 6.2, 16 | Invalid credentials, missing tokens, rejected validation, user mismatch, and persistence failure remain typed and do not persist credentials | `Sources/BleatCore/Authentication.swift` | `AuthenticationTests.testLocalLoginRejectsInvalidLoginResultsWithoutPersisting`, `testLocalLoginRejectsInvalidAuthorizationWithoutPersisting`, `testLocalLoginRejectsEmptyAccountAndPersistenceFailure` | verified |

The complete AC-01 through AC-28 release mapping is defined in
`IMPLEMENTATION_PLAN.md` and will be copied here as its implementation work
begins.
