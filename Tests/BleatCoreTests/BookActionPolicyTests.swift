import XCTest

@testable import BleatCore

final class BookActionPolicyTests: XCTestCase {
    func testAllowedActionsExactlyMatchServerPermissions() {
        for download in [false, true] {
            for update in [false, true] {
                for upload in [false, true] {
                    let availability = BookActionAvailability(
                        user: Self.user(
                            download: download,
                            update: update,
                            upload: upload
                        ),
                        detail: Self.detail()
                    )
                    var expected: Set<BookAction> = [.play]
                    if download {
                        expected.insert(.download)
                    }
                    if update {
                        expected.insert(.editMetadata)
                        if upload {
                            expected.insert(.editCover)
                        }
                    }
                    XCTAssertEqual(availability.access, .allowed)
                    XCTAssertEqual(
                        availability.visibleActions,
                        expected,
                        "download=\(download) update=\(update) upload=\(upload)"
                    )
                }
            }
        }
    }

    func testLibraryAndExplicitDenialsHideEveryAction() {
        let allowedLibrary = BookActionAvailability(
            user: Self.user(
                accessAllLibraries: false,
                accessibleLibraryIDs: [LibraryID(rawValue: "library")]
            ),
            detail: Self.detail()
        )
        let deniedLibrary = BookActionAvailability(
            user: Self.user(
                accessAllLibraries: false,
                accessibleLibraryIDs: [LibraryID(rawValue: "other")]
            ),
            detail: Self.detail()
        )
        let deniedExplicit = BookActionAvailability(
            user: Self.user(accessExplicitContent: false),
            detail: Self.detail(isExplicit: true)
        )

        XCTAssertEqual(allowedLibrary.access, .allowed)
        XCTAssertEqual(deniedLibrary.access, .inaccessibleLibrary)
        XCTAssertTrue(deniedLibrary.visibleActions.isEmpty)
        XCTAssertEqual(deniedExplicit.access, .explicitContentDenied)
        XCTAssertTrue(deniedExplicit.visibleActions.isEmpty)
    }

    func testTagAllowListRequiresAtLeastOneSelectedTag() {
        let user = Self.user(
            accessAllTags: false,
            selectedTagsNotAccessible: false,
            selectedItemTags: ["allowed", "also-allowed"]
        )

        XCTAssertEqual(
            BookActionAvailability(
                user: user,
                detail: Self.detail(tags: ["other", "allowed"])
            ).access,
            .allowed
        )
        for tags in [[], ["other"]] {
            let availability = BookActionAvailability(
                user: user,
                detail: Self.detail(tags: tags)
            )
            XCTAssertEqual(availability.access, .inaccessibleTags)
            XCTAssertTrue(availability.visibleActions.isEmpty)
        }
    }

    func testTagDenyListAllowsUntaggedAndRejectsAnySelectedTag() {
        let user = Self.user(
            accessAllTags: false,
            selectedTagsNotAccessible: true,
            selectedItemTags: ["blocked"]
        )

        for tags in [[], ["other"]] {
            XCTAssertEqual(
                BookActionAvailability(
                    user: user,
                    detail: Self.detail(tags: tags)
                ).access,
                .allowed
            )
        }
        let denied = BookActionAvailability(
            user: user,
            detail: Self.detail(tags: ["other", "blocked"])
        )
        XCTAssertEqual(denied.access, .inaccessibleTags)
        XCTAssertTrue(denied.visibleActions.isEmpty)
    }

    func testAccessAllTagsIgnoresSelectedTagMode() {
        for denySelected in [false, true] {
            let availability = BookActionAvailability(
                user: Self.user(
                    accessAllTags: true,
                    selectedTagsNotAccessible: denySelected,
                    selectedItemTags: ["blocked"]
                ),
                detail: Self.detail(tags: ["blocked"])
            )
            XCTAssertEqual(availability.access, .allowed)
        }
    }

    private static func user(
        download: Bool = true,
        update: Bool = true,
        upload: Bool = true,
        accessAllLibraries: Bool = true,
        accessibleLibraryIDs: [LibraryID] = [],
        accessAllTags: Bool = true,
        selectedTagsNotAccessible: Bool = false,
        selectedItemTags: [String] = [],
        accessExplicitContent: Bool = true
    ) -> AuthenticatedUser {
        AuthenticatedUser(
            id: UserID(rawValue: "user"),
            username: "reader",
            type: .user,
            permissions: UserPermissions(
                download: download,
                update: update,
                delete: true,
                upload: upload,
                createEReader: false,
                accessAllLibraries: accessAllLibraries,
                accessAllTags: accessAllTags,
                accessExplicitContent: accessExplicitContent,
                selectedTagsNotAccessible: selectedTagsNotAccessible
            ),
            accessibleLibraryIDs: accessibleLibraryIDs,
            selectedItemTags: selectedItemTags
        )
    }

    private static func detail(
        tags: [String] = [],
        isExplicit: Bool = false
    ) -> LibraryBookDetail {
        LibraryBookDetail(
            id: LibraryItemID(rawValue: "item"),
            libraryID: LibraryID(rawValue: "library"),
            bookID: BookID(rawValue: "book"),
            title: "Book",
            subtitle: nil,
            authors: [],
            narrators: [],
            series: [],
            genres: [],
            tags: tags,
            publishedYear: nil,
            publishedDate: nil,
            publisher: nil,
            descriptionPlain: nil,
            isbn: nil,
            asin: nil,
            language: nil,
            duration: 60,
            trackCount: 1,
            audioFileCount: 1,
            chapters: [],
            addedAtMilliseconds: 1,
            updatedAtMilliseconds: 2,
            isExplicit: isExplicit,
            isAbridged: false,
            progress: nil
        )
    }
}
