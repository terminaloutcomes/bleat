#if DEBUG
    import BleatCore
    import Foundation

    private enum UITestScenario: String, Sendable {
        case signedOut = "--ui-testing-signed-out"
        case signedIn = "--ui-testing-signed-in"
        case rejectLogin = "--ui-testing-reject-login"
    }

    actor UITestAppService: AppServicing {
        private let scenario: UITestScenario
        private let accountResult: Result<ServerAccount, AppServiceError>

        static func current() -> UITestAppService? {
            guard
                let scenario = ProcessInfo.processInfo.arguments
                    .compactMap(UITestScenario.init(rawValue:))
                    .first
            else {
                return nil
            }
            return UITestAppService(scenario: scenario)
        }

        private init(scenario: UITestScenario) {
            self.scenario = scenario
            accountResult = Self.makeAccount()
        }

        func activeAccount()
            async throws(AppServiceError) -> ServerAccount?
        {
            guard scenario == .signedIn else {
                return nil
            }
            return try account()
        }

        func login(
            serverAddress: String,
            username: String,
            password: String
        ) async throws(AppServiceError) -> ServerAccount {
            guard scenario != .rejectLogin,
                serverAddress == "https://books.example",
                username == "reader",
                password == "native-password"
            else {
                throw .onboarding(
                    .authenticationFailed(.invalidCredentials)
                )
            }
            return try account()
        }

        func libraries(
            for account: ServerAccount
        ) async throws(AppServiceError) -> [LibrarySummary] {
            [
                LibrarySummary(
                    id: LibraryID(rawValue: "ui-library"),
                    name: "Audiobooks",
                    mediaType: .book
                )
            ]
        }

        func firstPage(
            for account: ServerAccount,
            libraryID: LibraryID
        ) async throws(AppServiceError) -> LibraryItemsPage {
            LibraryItemsPage(
                items: [
                    LibraryBookSummary(
                        id: LibraryItemID(rawValue: "ui-book"),
                        libraryID: libraryID,
                        title: "The Test Audiobook",
                        subtitle: nil,
                        authorName: "Test Author",
                        narratorName: "Test Narrator",
                        seriesName: nil,
                        genres: ["Fiction"],
                        publisher: nil,
                        publishedYear: "2026",
                        duration: 3_600,
                        trackCount: 1,
                        chapterCount: 1,
                        addedAtMilliseconds: 1,
                        updatedAtMilliseconds: 1,
                        isExplicit: false,
                        isAbridged: false
                    )
                ],
                total: 1,
                page: 0,
                limit: 50
            )
        }

        func search(
            for account: ServerAccount,
            libraryID: LibraryID,
            query: String
        ) async throws(AppServiceError) -> [LibraryBookSummary] {
            guard query == "Test" else {
                return []
            }
            return firstPageItem(libraryID: libraryID)
        }

        func bookDetail(
            for account: ServerAccount,
            libraryID: LibraryID,
            itemID: LibraryItemID
        ) async throws(AppServiceError) -> LibraryBookDetail {
            LibraryBookDetail(
                id: itemID,
                libraryID: libraryID,
                bookID: BookID(rawValue: "ui-book"),
                title: itemID.rawValue == "ui-search-book"
                    ? "The Search Result"
                    : "The Test Audiobook",
                subtitle: "A complete test story",
                authors: [
                    LibraryBookContributor(
                        id: "author-1",
                        name: "Test Author"
                    )
                ],
                narrators: ["Test Narrator"],
                series: [],
                genres: ["Fiction"],
                tags: [],
                publishedYear: "2026",
                publishedDate: nil,
                publisher: "Test Press",
                descriptionPlain:
                    "An expanded audiobook loaded from the server.",
                isbn: nil,
                asin: nil,
                language: "English",
                duration: 3_600,
                trackCount: 1,
                audioFileCount: 1,
                chapters: [],
                addedAtMilliseconds: 1,
                updatedAtMilliseconds: 1,
                isExplicit: false,
                isAbridged: false,
                progress: nil
            )
        }

        func removeAccount(
            _ account: ServerAccount
        ) async throws(AppServiceError) {}

        private func account() throws(AppServiceError) -> ServerAccount {
            switch accountResult {
            case .success(let account):
                account
            case .failure(let error):
                throw error
            }
        }

        private static func makeAccount()
            -> Result<ServerAccount, AppServiceError>
        {
            do {
                return .success(
                    try ServerAccount(
                        id: AccountID(rawValue: "ui-account"),
                        server: NormalizedServerURL(
                            "https://books.example"
                        ),
                        serverVersion: "2.36.0",
                        authenticationMethods: [.local],
                        user: AuthenticatedUser(
                            id: UserID(rawValue: "ui-user"),
                            username: "reader",
                            type: .user,
                            permissions: UserPermissions(
                                download: true,
                                update: false,
                                delete: false,
                                upload: false,
                                createEReader: false,
                                accessAllLibraries: true,
                                accessAllTags: true,
                                accessExplicitContent: true,
                                selectedTagsNotAccessible: false
                            ),
                            accessibleLibraryIDs: [],
                            selectedItemTags: []
                        )
                    )
                )
            } catch {
                return .failure(
                    .accountStore(.persistenceFailed)
                )
            }
        }
    }

    private func firstPageItem(
        libraryID: LibraryID
    ) -> [LibraryBookSummary] {
        [
            LibraryBookSummary(
                id: LibraryItemID(rawValue: "ui-search-book"),
                libraryID: libraryID,
                title: "The Search Result",
                subtitle: nil,
                authorName: "Test Author",
                narratorName: "Test Narrator",
                seriesName: nil,
                genres: ["Fiction"],
                publisher: nil,
                publishedYear: "2026",
                duration: 3_600,
                trackCount: 1,
                chapterCount: 1,
                addedAtMilliseconds: 1,
                updatedAtMilliseconds: 1,
                isExplicit: false,
                isAbridged: false
            )
        ]
    }
#endif
