import Foundation
import XCTest

@testable import BleatCore

final class ServerStatusLiveTests: XCTestCase {
    func testPinnedRootAndPrefixStatusContracts() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootURL = environment["BLEAT_LIVE_ROOT_URL"],
              let prefixURL = environment["BLEAT_LIVE_PREFIX_URL"]
        else {
            throw XCTSkip(
                "Run scripts/test-live.sh to provide live server URLs"
            )
        }

        for baseURL in [rootURL, prefixURL] {
            let url = try XCTUnwrap(URL(string: "\(baseURL)/status"))
            let (data, response) = try await URLSession.shared.data(from: url)
            let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
            let status = try JSONDecoder().decode(
                ServerStatusResponse.self,
                from: data
            )

            XCTAssertEqual(httpResponse.statusCode, 200)
            XCTAssertEqual(status.app, "audiobookshelf")
            XCTAssertEqual(status.serverVersion, "2.36.0")
            XCTAssertTrue(status.isInitialized)
            XCTAssertEqual(status.authenticationMethods, [.local])
        }
    }
}
