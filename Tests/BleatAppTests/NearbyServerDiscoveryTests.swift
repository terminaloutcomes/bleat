import BleatCore
import Foundation
import Network
import XCTest
import dnssd

@testable import Bleat

@MainActor
final class NearbyServerDiscoveryTests: XCTestCase {
    func testReleaseScreenshotLaunchModeUsesNoResultsDiscovery() {
        let mode = AppLaunchMode(
            arguments: [AppLaunchMode.releaseScreenshotArgument]
        )

        XCTAssertEqual(mode, .releaseScreenshot)
        XCTAssertTrue(
            mode.makeNearbyServerDiscovery()
                is NoResultsNearbyServerDiscovery
        )
    }

    func testStandardLaunchModeUsesBonjourDiscovery() {
        let mode = AppLaunchMode(arguments: [])

        XCTAssertEqual(mode, .standard)
        XCTAssertTrue(
            mode.makeNearbyServerDiscovery()
                is BonjourNearbyServerDiscovery
        )
    }

    func testNoResultsDiscoveryImmediatelyPublishesNoResults() {
        let discovery = NoResultsNearbyServerDiscovery()
        var states: [NearbyServerDiscoveryState] = []

        discovery.start { state in
            states.append(state)
        }

        XCTAssertEqual(states, [.noResults])
    }

    func testResolveRequestUsesInstanceComponentsAndInterfaceIndex() {
        let service = discoveredService(
            name: "Audiobookshelf",
            interfaceIndex: 14
        )

        XCTAssertEqual(
            BonjourResolveRequest(service: service),
            BonjourResolveRequest(
                name: "Audiobookshelf",
                type: "_audiobookshelf._tcp",
                domain: "local.",
                interfaceIndex: 14
            )
        )
    }

    func testDNSPolicyDenialIsPermissionDenied() {
        for code in [kDNSServiceErr_PolicyDenied, kDNSServiceErr_NotPermitted] {
            XCTAssertEqual(
                BonjourNearbyServerDiscovery.failure(for: .dns(Int32(code))),
                .permissionDenied
            )
        }
    }

    func testLiveAdvertisementBuildsExpectedNormalizedURL() throws {
        let resolved = try AudiobookshelfEndpointBuilder.resolvedService(
            service: discoveredService(interfaceIndex: 14),
            host: "audiobookshelf.housenet.yaleman.org.",
            port: 443,
            txtData: txtData(["path": Data("/".utf8)])
        )

        XCTAssertEqual(resolved.host, "audiobookshelf.housenet.yaleman.org")
        XCTAssertEqual(resolved.port, 443)
        XCTAssertEqual(resolved.path, "/")
        XCTAssertEqual(
            resolved.baseURL.url.absoluteString,
            "https://audiobookshelf.housenet.yaleman.org"
        )
    }

    func testNonDefaultPortAndPathAreRetained() throws {
        let resolved = try AudiobookshelfEndpointBuilder.resolvedService(
            service: discoveredService(),
            host: "books.example.com.",
            port: 8443,
            txtData: txtData(["path": Data("/audiobookshelf".utf8)])
        )

        XCTAssertEqual(
            resolved.baseURL.url.absoluteString,
            "https://books.example.com:8443/audiobookshelf"
        )
    }

    func testMissingTXTPathDefaultsToRoot() throws {
        let resolved = try AudiobookshelfEndpointBuilder.resolvedService(
            service: discoveredService(),
            host: "books.example.com.",
            port: 443,
            txtData: Data()
        )

        XCTAssertEqual(resolved.path, "/")
        XCTAssertEqual(
            resolved.baseURL.url.absoluteString,
            "https://books.example.com"
        )
    }

    func testInvalidUTF8TXTPathIsRejected() {
        XCTAssertThrowsError(
            try AudiobookshelfEndpointBuilder.resolvedService(
                service: discoveredService(),
                host: "books.example.com.",
                port: 443,
                txtData: txtData(["path": Data([0xC3, 0x28])])
            )
        ) { error in
            XCTAssertEqual(
                error as? BonjourResolutionError,
                .invalidTXTPath
            )
        }
    }

    func testInvalidHostsPortsAndPathsAreRejected() {
        let invalidValues: [(String, UInt16, String)] = [
            ("", 443, "/"),
            ("books..example.com", 443, "/"),
            ("books.example.com..", 443, "/"),
            ("books.example.com", 0, "/"),
            ("books.example.com", 443, "relative"),
            ("books.example.com", 443, "//other-host/path"),
            ("books.example.com", 443, "/path?query=value"),
            ("books.example.com", 443, "/path#fragment"),
        ]

        for (host, port, path) in invalidValues {
            XCTAssertThrowsError(
                try AudiobookshelfEndpointBuilder.normalizedURL(
                    host: host,
                    port: port,
                    path: path
                ),
                "Expected rejection for \(host):\(port)\(path)"
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
            try nearbyResult(name: "Zulu", server: primary),
            try nearbyResult(name: "Alpha", server: duplicate),
            try nearbyResult(name: "Beta", server: second),
        ])

        XCTAssertEqual(results.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(
            results.map(\.server.baseURL.url.absoluteString),
            ["https://books.local/audiobookshelf", "https://other.local"]
        )
        XCTAssertEqual(
            results.map(\.resolution.host),
            ["books.local", "other.local"]
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

    func testPhysicalDeviceResolvesAndVerifiesLiveAdvertisement() async throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("Physical-device Bonjour validation")
        #else
            guard
                ProcessInfo.processInfo.environment[
                    "BLEAT_RUN_PHYSICAL_BONJOUR_TESTS"
                ] == "1"
            else {
                throw XCTSkip(
                    "Set BLEAT_RUN_PHYSICAL_BONJOUR_TESTS=1 on the advertising LAN"
                )
            }
            let browser = BonjourServiceBrowser()
            let resolver = BonjourServiceResolver()
            let completed = expectation(
                description: "Resolved live Bonjour service")
            var outcome: Result<ResolvedBonjourService, Error>?
            var startedResolution = false

            browser.start { event in
                guard case .added(let service) = event,
                    service.name == "Audiobookshelf",
                    !startedResolution
                else {
                    return
                }
                startedResolution = true
                Task { @MainActor in
                    do {
                        outcome = .success(try await resolver.resolve(service))
                    } catch {
                        outcome = .failure(error)
                    }
                    completed.fulfill()
                }
            }

            await fulfillment(of: [completed], timeout: 15)
            browser.cancel()
            resolver.cancelAll()
            let resolved = try XCTUnwrap(outcome).get()

            XCTAssertEqual(
                resolved.host,
                "audiobookshelf.housenet.yaleman.org"
            )
            XCTAssertEqual(resolved.port, 443)
            XCTAssertEqual(resolved.path, "/")
            XCTAssertEqual(
                resolved.baseURL.url.absoluteString,
                "https://audiobookshelf.housenet.yaleman.org"
            )

            let discovered = try await ServerDiscoveryClient(
                transport: URLSessionHTTPTransport(routesRequests: false)
            ).discover(resolved.baseURL)
            XCTAssertEqual(discovered.baseURL, resolved.baseURL)
        #endif
    }

    private func discoveredService(
        name: String = "Audiobookshelf",
        interfaceIndex: UInt32 = 7
    ) -> BonjourDiscoveredService {
        BonjourDiscoveredService(
            id: BonjourServiceID(
                name: name,
                type: "_audiobookshelf._tcp",
                domain: "local.",
                interfaceIndex: interfaceIndex
            ),
            interfaceName: "en0"
        )
    }

    private func txtData(_ values: [String: Data]) -> Data {
        NetService.data(fromTXTRecord: values)
    }

    private func discoveredServer(
        _ value: String
    ) async throws -> DiscoveredServer {
        let server = try NormalizedServerURL(value)
        return try await ServerDiscoveryClient(
            transport: NearbyStatusTransport()
        ).discover(server)
    }

    private func nearbyResult(
        name: String,
        server: DiscoveredServer
    ) throws -> NearbyServerResult {
        guard let host = server.baseURL.url.host,
            let port = UInt16(exactly: server.baseURL.url.port ?? 443)
        else {
            throw BonjourResolutionError.invalidURL
        }
        let path =
            server.baseURL.url.path.isEmpty
            ? "/"
            : server.baseURL.url.path
        return NearbyServerResult(
            name: name,
            resolution: ResolvedBonjourService(
                service: discoveredService(name: name),
                host: host,
                port: port,
                txt: [:],
                path: path,
                baseURL: server.baseURL
            ),
            server: server
        )
    }
}

@MainActor
private final class TestNearbyServerDiscovery: NearbyServerDiscovering {
    private var update:
        (@MainActor @Sendable (NearbyServerDiscoveryState) -> Void)?
    private(set) var cancelCount = 0

    func start(
        update:
            @escaping @MainActor @Sendable (
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
