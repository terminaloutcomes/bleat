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

The complete AC-01 through AC-28 release mapping is defined in
`IMPLEMENTATION_PLAN.md` and will be copied here as its implementation work
begins.
