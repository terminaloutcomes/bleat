import Foundation
import XCTest

@testable import Bleat

final class AppMetadataTests: XCTestCase {
    func testUsesBundleMetadata() {
        let metadata = AppMetadata(
            infoDictionary: [
                "CFBundleDisplayName": "Bleat",
                "CFBundleShortVersionString": "1.2.3",
                "BleatBuildDate": "2026-08-03T12:34:56Z",
                "BleatDeveloperName": "James Hodgkinson",
            ],
            bundleIdentifier: "com.example.bleat"
        )

        XCTAssertEqual(metadata.appName, "Bleat")
        XCTAssertEqual(metadata.version, "1.2.3")
        XCTAssertEqual(
            metadata.compileDate,
            ISO8601DateFormatter().date(from: "2026-08-03T12:34:56Z")
        )
        XCTAssertEqual(metadata.developerName, "James Hodgkinson")
        XCTAssertEqual(metadata.bundleIdentifier, "com.example.bleat")
    }

    func testFallsBackWhenBundleMetadataIsMissing() {
        let metadata = AppMetadata(
            infoDictionary: [:],
            bundleIdentifier: nil
        )

        XCTAssertEqual(metadata.appName, "Bleat")
        XCTAssertEqual(metadata.version, "Unavailable")
        XCTAssertNil(metadata.compileDate)
        XCTAssertEqual(metadata.developerName, "Unavailable")
        XCTAssertEqual(metadata.bundleIdentifier, "Unavailable")
    }
}
