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

        func accounts()
            async throws(AppServiceError) -> [ServerAccount]
        {
            guard scenario == .signedIn else {
                return []
            }
            return [try account()]
        }

        func activeAccount()
            async throws(AppServiceError) -> ServerAccount?
        {
            guard scenario == .signedIn else {
                return nil
            }
            return try account()
        }

        func activateAccount(
            _ account: ServerAccount
        ) async throws(AppServiceError) {}

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

        func page(
            for account: ServerAccount,
            libraryID: LibraryID,
            page: Int
        ) async throws(AppServiceError) -> LibraryItemsPage {
            if page == 1 {
                return LibraryItemsPage(
                    items: [
                        Self.book(
                            id: "ui-book-2",
                            title: "The Second Audiobook",
                            libraryID: libraryID
                        )
                    ],
                    total: 2,
                    page: 1,
                    limit: 1
                )
            }
            return LibraryItemsPage(
                items: [
                    Self.book(
                        id: "ui-book",
                        title: "The Test Audiobook",
                        libraryID: libraryID
                    )
                ],
                total: 2,
                page: 0,
                limit: 1
            )
        }

        func homeShelves(
            for account: ServerAccount,
            libraryID: LibraryID
        ) async throws(AppServiceError) -> [LibraryBookShelf] {
            [
                LibraryBookShelf(
                    id: "continue-listening",
                    label: "Continue Listening",
                    labelLocalizationKey: nil,
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
                    total: 1
                )
            ]
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

        func openPlayback(
            for account: ServerAccount,
            itemID: LibraryItemID,
            deviceInfo: PlaybackDeviceInfo
        ) async throws(AppServiceError) -> AppPlaybackPreparation {
            throw .playbackSession(.requestFailed)
        }

        func closePlayback(
            for account: ServerAccount,
            sessionID: PlaybackSessionID
        ) async throws(AppServiceError) {}

        func syncPlayback(
            for account: ServerAccount,
            sessionID: PlaybackSessionID,
            currentTime: Double,
            duration: Double
        ) async throws(AppServiceError) {}

        func syncLocalPlaybackSessions(
            for account: ServerAccount,
            sessions: [LocalPlaybackSession],
            deviceInfo: PlaybackDeviceInfo
        ) async throws(AppServiceError) -> [LocalPlaybackSessionSyncResult] {
            []
        }

        func saveMetadata(
            for account: ServerAccount,
            baseline: LibraryBookDetail,
            draft: BookMetadataDraft,
            overwrite: Bool
        ) async throws(AppServiceError) -> AppMetadataSaveOutcome {
            .saved(baseline)
        }

        func downloadPlan(
            for account: ServerAccount,
            itemID: LibraryItemID
        ) async throws(AppServiceError) -> DownloadPlan {
            throw .downloadPlan(.invalidItemID)
        }

        func authorizedDownloadRequest(
            for account: ServerAccount,
            identity: DownloadTaskIdentity
        ) async throws(AppServiceError) -> URLRequest {
            throw .downloadAuthorization(.invalidAccountID)
        }

        func replacementDownloadRequest(
            for account: ServerAccount,
            identity: DownloadTaskIdentity,
            rejectedRequest: URLRequest
        ) async throws(AppServiceError) -> URLRequest {
            throw .downloadAuthorization(.invalidAccountID)
        }

        func replaceCover(
            for account: ServerAccount,
            detail: LibraryBookDetail,
            jpegData: Data
        ) async throws(AppServiceError) -> LibraryBookDetail {
            detail
        }

        func bookmarks(
            for account: ServerAccount,
            itemID: LibraryItemID
        ) async throws(AppServiceError) -> [AudioBookmark] {
            []
        }

        func createBookmark(
            for account: ServerAccount,
            itemID: LibraryItemID,
            time: Double,
            title: String
        ) async throws(AppServiceError) -> AudioBookmark {
            AudioBookmark(
                libraryItemID: itemID,
                time: time,
                title: title,
                createdAtMilliseconds: 1
            )
        }

        func renameBookmark(
            for account: ServerAccount,
            bookmark: AudioBookmark,
            title: String
        ) async throws(AppServiceError) -> AudioBookmark {
            AudioBookmark(
                libraryItemID: bookmark.libraryItemID,
                time: bookmark.time,
                title: title,
                createdAtMilliseconds: bookmark.createdAtMilliseconds
            )
        }

        func deleteBookmark(
            for account: ServerAccount,
            bookmark: AudioBookmark
        ) async throws(AppServiceError) {}

        func bookProgress(
            for account: ServerAccount,
            itemID: LibraryItemID
        ) async throws(AppServiceError) -> LibraryBookProgress? {
            nil
        }

        func updateBookProgress(
            for account: ServerAccount,
            itemID: LibraryItemID,
            update: BookProgressUpdate
        ) async throws(AppServiceError) {}

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

        private static func book(
            id: String,
            title: String,
            libraryID: LibraryID
        ) -> LibraryBookSummary {
            LibraryBookSummary(
                id: LibraryItemID(rawValue: id),
                libraryID: libraryID,
                title: title,
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
                                update: true,
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
