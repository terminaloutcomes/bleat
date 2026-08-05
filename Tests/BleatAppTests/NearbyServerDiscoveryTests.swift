import BleatCore
import dnssd
import Network
import XCTest

@testable import Bleat

@MainActor
final class NearbyServerDiscoveryTests: XCTestCase {
    func testHTTPSAdvertisementBuildsRootURL() throws {
        let server = try NearbyServerAdvertisementMapper.serverURL(
            for: NearbyServerAdvertisement(
                name: "Library",
                serviceType: .https,
                host: "books.local",
                port: 443,
                path: "/ignored"
            )
        )

        XCTAssertEqual(server.url.absoluteString, "https://books.local")
    }

    func testAudiobookshelfAdvertisementRetainsPortAndPathPrefix() throws {
        let server = try NearbyServerAdvertisementMapper.serverURL(
            for: NearbyServerAdvertisement(
                name: "Library",
                serviceType: .audiobookshelf,
                host: "books.local",
                port: 8443,
                path: "/audiobookshelf"
            )
        )

        XCTAssertEqual(
            server.url.absoluteString,
            "https://books.local:8443/audiobookshelf"
        )
    }

    func testAdvertisementRejectsMalformedPathAndHost() {
        let advertisements = [
            NearbyServerAdvertisement(
                name: "Query",
                serviceType: .audiobookshelf,
                host: "books.local",
                port: 443,
                path: "/prefix?token=value"
            ),
            NearbyServerAdvertisement(
                name: "Fragment",
                serviceType: .audiobookshelf,
                host: "books.local",
                port: 443,
                path: "/prefix#fragment"
            ),
            NearbyServerAdvertisement(
                name: "Relative",
                serviceType: .audiobookshelf,
                host: "books.local",
                port: 443,
                path: "prefix"
            ),
            NearbyServerAdvertisement(
                name: "Credentials",
                serviceType: .audiobookshelf,
                host: "user@books.local",
                port: 443,
                path: nil
            ),
        ]

        for advertisement in advertisements {
            XCTAssertThrowsError(
                try NearbyServerAdvertisementMapper.serverURL(
                    for: advertisement
                )
            ) { error in
                XCTAssertEqual(
                    error as? NearbyServerDiscoveryFailure,
                    .invalidAdvertisement
                )
            }
        }
    }

    func testNonUTF8TXTPathIsAnInvalidAdvertisement() {
        XCTAssertThrowsError(
            try BonjourNearbyServerDiscovery.utf8Path(
                from: Data([0xC3, 0x28])
            )
        ) { error in
            XCTAssertEqual(
                error as? NearbyServerDiscoveryFailure,
                .invalidAdvertisement
            )
        }
    }

    func testDNSPolicyDenialIsPermissionDenied() {
        for code in [kDNSServiceErr_PolicyDenied, kDNSServiceErr_NotPermitted] {
            XCTAssertEqual(
                BonjourNearbyServerDiscovery.failure(for: .dns(Int32(code))),
                .permissionDenied
            )
        }
    }

    func testDeduplicationUsesNormalizedURLAndStableOrdering() async throws {
        let primary = try await discoveredServer(
            "https://books.local/audiobookshelf/"
        )
        let duplicate = try await discoveredServer(
            "https://books.local/audiobookshelf"
        )
        let second = try await discoveredServer("https://other.local")

        let results = NearbyServerAdvertisementMapper.deduplicated([
            NearbyServerResult(name: "Zulu", server: primary),
            NearbyServerResult(name: "Alpha", server: duplicate),
            NearbyServerResult(name: "Beta", server: second),
        ])

        XCTAssertEqual(results.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(
            results.map(\.server.baseURL.url.absoluteString),
            ["https://books.local/audiobookshelf", "https://other.local"]
        )
    }

    func testModelPublishesTypedDiscoveryStatesAndCancels() {
        let discovery = TestNearbyServerDiscovery()
        let model = AppModel(
            service: UnavailableAppService(),
            nearbyServerDiscovery: discovery
        )

        model.startNearbyServerDiscovery()
        XCTAssertEqual(model.nearbyServerDiscoveryState, .searching)

        discovery.send(.failed(.permissionDenied))
        XCTAssertEqual(
            model.nearbyServerDiscoveryState,
            .failed(.permissionDenied)
        )

        model.cancelNearbyServerDiscovery()
        XCTAssertEqual(model.nearbyServerDiscoveryState, .idle)
        XCTAssertEqual(discovery.cancelCount, 1)

        discovery.send(.failed(.resolutionFailed))
        XCTAssertEqual(model.nearbyServerDiscoveryState, .idle)
    }

    func testEveryFailureHasPrivacySafePresentation() {
        let failures: [NearbyServerDiscoveryFailure] = [
            .permissionDenied,
            .localNetworkUnavailable,
            .resolutionFailed,
            .invalidAdvertisement,
            .serverVerificationFailed,
        ]

        for failure in failures {
            XCTAssertFalse(failure.title.isEmpty)
            XCTAssertFalse(failure.message.isEmpty)
            XCTAssertFalse(failure.message.contains(".local"))
            XCTAssertFalse(failure.message.contains("https://"))
        }
    }

    private func discoveredServer(
        _ value: String
    ) async throws -> DiscoveredServer {
        let server = try NormalizedServerURL(value)
        return try await ServerDiscoveryClient(
            transport: NearbyStatusTransport()
        ).discover(server)
    }
}

@MainActor
private final class TestNearbyServerDiscovery: NearbyServerDiscovering {
    private var update: (@MainActor @Sendable (
        NearbyServerDiscoveryState
    ) -> Void)?
    private(set) var cancelCount = 0

    func start(
        update: @escaping @MainActor @Sendable (
            NearbyServerDiscoveryState
        ) -> Void
    ) {
        self.update = update
        update(.searching)
    }

    func cancel() {
        cancelCount += 1
        update = nil
    }

    func send(_ state: NearbyServerDiscoveryState) {
        update?(state)
    }
}

private struct NearbyStatusTransport: HTTPTransport {
    func send(_ request: TracedHTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(
            data: Data(
                """
                {
                  "app": "audiobookshelf",
                  "serverVersion": "2.36.0",
                  "isInit": true,
                  "language": "en-us",
                  "authMethods": ["local"]
                }
                """.utf8
            ),
            statusCode: 200,
            url: request.request.url
        )
    }
}
