import XCTest

@testable import Bleat

final class DocumentationLinkTests: XCTestCase {
    func testOpenIDSetupGuideUsesStablePublicURLWithoutUserData() throws {
        let url = try XCTUnwrap(AppDocumentationLink.openIDSetupGuide)

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "bleat.terminaloutcomes.com")
        XCTAssertEqual(
            url.absoluteString,
            "https://bleat.terminaloutcomes.com/help/oidc-setup/"
        )
        XCTAssertEqual(url.path, "/help/oidc-setup")
        XCTAssertNil(url.query)
        XCTAssertNil(url.fragment)
        XCTAssertNil(url.user)
        XCTAssertNil(url.password)
    }
}
