import Foundation
import XCTest

final class TelemetryLiveTestConfigurationTests: XCTestCase {
    func testProductionAuthenticationURLDoesNotEnableLiveTests() throws {
        let url = try telemetryAuthenticationTestBaseURL(
            environment: [
                "BLEAT_TELEMETRY_AUTH_BASE_URL":
                    "https://bleat-api.terminaloutcomes.com"
            ]
        )

        XCTAssertNil(url)
    }

    func testAcceptsExplicitLoopbackHTTPOrigin() throws {
        let url = try telemetryAuthenticationTestBaseURL(
            environment: [
                "BLEAT_TELEMETRY_TEST_AUTH_BASE_URL":
                    "http://127.0.0.1:28123"
            ]
        )

        XCTAssertEqual(url?.absoluteString, "http://127.0.0.1:28123")
    }

    func testRejectsNonLoopbackAndMalformedTestURLs() {
        let rejectedValues = [
            "https://127.0.0.1:28123",
            "http://bleat-api.terminaloutcomes.com:8080",
            "http://user:password@127.0.0.1:28123",
            "http://127.0.0.1",
            "http://127.0.0.1:28123/v1",
            "http://127.0.0.1:28123?query=value",
            "http://127.0.0.1:28123#fragment",
            "not a URL",
        ]

        for value in rejectedValues {
            XCTAssertThrowsError(
                try telemetryAuthenticationTestBaseURL(
                    environment: [
                        "BLEAT_TELEMETRY_TEST_AUTH_BASE_URL": value
                    ]
                ),
                "Expected rejection for \(value)"
            ) { error in
                XCTAssertEqual(
                    error as? TelemetryLiveTestConfigurationError,
                    .invalidAuthenticationBaseURL
                )
            }
        }
    }
}
