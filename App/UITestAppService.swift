#if DEBUG
    import BleatCore
    import Foundation

    private enum UITestScenario: String, Sendable {
        case signedOut = "--ui-testing-signed-out"
        case signedIn = "--ui-testing-signed-in"
        case refresh = "--ui-testing-refresh"
        case limitedPermissions = "--ui-testing-limited-permissions"
        case rejectLogin = "--ui-testing-reject-login"
        case submissionProgress = "--ui-testing-submission-progress"
        case playback = "--ui-testing-playback"
        case launching = "--ui-testing-launching"
    }

    private enum UITestScenarioStorage {
        static let persistedScenarioKey = "Bleat.UITest.persistedScenario"
        static let persistArgument = "--ui-testing-persist-scenario"
        static let clearArgument = "--ui-testing-clear-persisted-scenario"
        static let clearDeepLinkReceiptArgument =
            "--ui-testing-clear-deep-link-receipt"
    }

    private struct FixtureIDs: Sendable {
        let primaryAuthor: AuthorID
        let secondaryAuthor: AuthorID
        let primarySeries: SeriesID
        let secondarySeries: SeriesID
    }

    actor UITestAppService: AppServicing {
        static var opensSettingsAtLaunch: Bool {
            ProcessInfo.processInfo.arguments.contains(
                "--ui-testing-open-settings"
            )
        }

        private let scenario: UITestScenario
        private let accountResult: Result<ServerAccount, AppServiceError>
        private var firstPageRequests = 0
        private var homeShelfRequests = 0

        static func current() -> UITestAppService? {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains(
                UITestScenarioStorage.clearDeepLinkReceiptArgument
            ) {
                UITestDeepLinkReceipt.clear()
            }
            if arguments.contains(UITestScenarioStorage.clearArgument) {
                UserDefaults.standard.removeObject(
                    forKey: UITestScenarioStorage.persistedScenarioKey
                )
                return UITestAppService(scenario: .signedOut)
            }
            if let scenario = arguments
                .compactMap(UITestScenario.init(rawValue:))
                .first
            {
                if arguments.contains(UITestScenarioStorage.persistArgument) {
                    UserDefaults.standard.set(
                        scenario.rawValue,
                        forKey: UITestScenarioStorage.persistedScenarioKey
                    )
                }
                return UITestAppService(scenario: scenario)
            }
            guard let rawScenario = UserDefaults.standard.string(
                forKey: UITestScenarioStorage.persistedScenarioKey
            ), let scenario = UITestScenario(rawValue: rawScenario) else {
                return nil
            }
            return UITestAppService(scenario: scenario)
        }

        private init(scenario: UITestScenario) {
            self.scenario = scenario
            accountResult = Self.makeAccount(
                hasManagementPermissions: scenario != .limitedPermissions
            )
        }

        func accounts()
            async throws(AppServiceError) -> [ServerAccount]
        {
            guard
                [.signedIn, .refresh, .limitedPermissions, .playback]
                    .contains(scenario)
            else {
                return []
            }
            return [try account()]
        }

        func activeAccount()
            async throws(AppServiceError) -> ServerAccount?
        {
            if scenario == .launching {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            guard
                [.signedIn, .refresh, .limitedPermissions, .playback]
                    .contains(scenario)
            else {
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
            password: String,
            progress: @escaping AccountSubmissionProgress
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
            if scenario == .submissionProgress {
                await progress(.checkingServer)
                try? await Task.sleep(for: .seconds(2))
            }
            return try account()
        }

        func reauthenticate(
            _ account: ServerAccount,
            password: String
        ) async throws(AppServiceError) -> ServerAccount {
            try self.account()
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
            request: LibraryItemsPageRequest
        ) async throws(AppServiceError) -> LibraryItemsPage {
            let ids = try Self.fixtureIDs()
            if request.filter == nil, request.page == 0 {
                firstPageRequests += 1
            }
            let primaryBook = Self.book(
                id: "ui-book",
                title: libraryTitle,
                libraryID: libraryID,
                ids: ids
            )
            let primarySeriesBooks = [
                Self.book(
                    id: "ui-series-one",
                    title: "Test Series Volume One",
                    libraryID: libraryID,
                    ids: ids,
                    series: [
                        LibraryBookSeries(
                            id: ids.primarySeries,
                            name: "Test Series",
                            sequence: "1"
                        )
                    ]
                ),
                Self.book(
                    id: "ui-series-two",
                    title: "Test Series Volume Two",
                    libraryID: libraryID,
                    ids: ids,
                    series: [
                        LibraryBookSeries(
                            id: ids.primarySeries,
                            name: "Test Series",
                            sequence: "2"
                        )
                    ]
                ),
            ]
            let secondarySeriesBooks = [
                Self.book(
                    id: "ui-companion-one",
                    title: "Companion Series Volume One",
                    libraryID: libraryID,
                    ids: ids,
                    series: [
                        LibraryBookSeries(
                            id: ids.secondarySeries,
                            name: "Companion Series",
                            sequence: "1"
                        )
                    ]
                ),
                Self.book(
                    id: "ui-companion-two",
                    title: "Companion Series Volume Two",
                    libraryID: libraryID,
                    ids: ids,
                    series: [
                        LibraryBookSeries(
                            id: ids.secondarySeries,
                            name: "Companion Series",
                            sequence: "2"
                        )
                    ]
                ),
            ]

            if request.filter == LibraryItemFilter(authorID: ids.primaryAuthor)
                || request.filter == LibraryItemFilter(authorID: ids.secondaryAuthor)
            {
                return LibraryItemsPage(
                    items: [primaryBook],
                    total: 1,
                    page: 0,
                    limit: 1
                )
            }
            if request.filter == LibraryItemFilter(seriesID: ids.primarySeries) {
                return LibraryItemsPage(
                    items: primarySeriesBooks,
                    total: primarySeriesBooks.count,
                    page: 0,
                    limit: primarySeriesBooks.count
                )
            }
            if request.filter == LibraryItemFilter(seriesID: ids.secondarySeries) {
                return LibraryItemsPage(
                    items: secondarySeriesBooks,
                    total: secondarySeriesBooks.count,
                    page: 0,
                    limit: secondarySeriesBooks.count
                )
            }
            if request.page == 1 {
                let collapsedSeries = LibraryCollapsedSeries(
                    id: ids.primarySeries,
                    name: "Test Series",
                    libraryItemIDs: primarySeriesBooks.map(\.id),
                    numBooks: primarySeriesBooks.count,
                    sequenceList: ["1", "2"]
                )
                return LibraryItemsPage(
                    items: [
                        Self.book(
                            id: "ui-book-2",
                            title: "The Second Audiobook",
                            libraryID: libraryID,
                            ids: ids,
                            collapsedSeries: collapsedSeries
                        )
                    ],
                    total: 2,
                    page: 1,
                    limit: 1
                )
            }
            return LibraryItemsPage(
                items: [primaryBook],
                total: 2,
                page: 0,
                limit: 1
            )
        }

        func homeShelves(
            for account: ServerAccount,
            libraryID: LibraryID
        ) async throws(AppServiceError) -> [LibraryBookShelf] {
            let ids = try Self.fixtureIDs()
            homeShelfRequests += 1
            let title =
                scenario == .refresh && homeShelfRequests >= 2
                ? "The Refreshed Home Audiobook"
                : "The Test Audiobook"
            return [
                LibraryBookShelf(
                    id: "continue-listening",
                    label: "Continue Listening",
                    labelLocalizationKey: nil,
                    items: [
                        Self.book(
                            id: "ui-book",
                            title: title,
                            libraryID: libraryID,
                            ids: ids
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
        ) async throws(AppServiceError) -> LibrarySearchResults {
            guard query == "Test" else {
                return LibrarySearchResults(books: [])
            }
            let ids = try Self.fixtureIDs()
            return LibrarySearchResults(
                books: try Self.firstPageItem(libraryID: libraryID),
                authors: [
                    LibrarySearchAuthorMatch(
                        id: ids.primaryAuthor,
                        name: "Test Author"
                    ),
                    LibrarySearchAuthorMatch(
                        id: ids.secondaryAuthor,
                        name: "Test Coauthor"
                    ),
                ],
                series: [
                    LibrarySearchSeriesMatch(
                        id: ids.primarySeries,
                        name: "Test Series"
                    ),
                    LibrarySearchSeriesMatch(
                        id: ids.secondarySeries,
                        name: "Companion Series"
                    ),
                ]
            )
        }

        func bookDetail(
            for account: ServerAccount,
            libraryID: LibraryID,
            itemID: LibraryItemID
        ) async throws(AppServiceError) -> LibraryBookDetail {
            let ids = try Self.fixtureIDs()
            return LibraryBookDetail(
                id: itemID,
                libraryID: libraryID,
                bookID: BookID(rawValue: "ui-book"),
                title: itemID.rawValue == "ui-search-book"
                    ? "The Search Result"
                    : "The Test Audiobook",
                subtitle: "A complete test story",
                authors: [
                    LibraryBookContributor(
                        id: ids.primaryAuthor,
                        name: "Test Author"
                    ),
                    LibraryBookContributor(
                        id: ids.secondaryAuthor,
                        name: "Test Coauthor"
                    ),
                ],
                narrators: ["Test Narrator"],
                series: [
                    LibraryBookSeries(
                        id: ids.primarySeries,
                        name: "Test Series",
                        sequence: "1"
                    ),
                    LibraryBookSeries(
                        id: ids.secondarySeries,
                        name: "Companion Series",
                        sequence: "1"
                    ),
                ],
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
                chapters: [
                    PlaybackChapter(
                        id: 0,
                        start: 0,
                        end: 1_800,
                        title: "Chapter One"
                    ),
                    PlaybackChapter(
                        id: 1,
                        start: 1_800,
                        end: 3_600,
                        title: "Chapter Two"
                    ),
                ],
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
            preference: PlaybackPreference,
            deviceInfo: PlaybackDeviceInfo
        ) async throws(AppServiceError) -> AppPlaybackPreparation {
            guard scenario == .playback else {
                throw .playbackSession(.requestFailed)
            }
            return AppPlaybackPreparation(
                sessionID: nil,
                itemID: itemID,
                title: "The Test Audiobook",
                duration: 3_600,
                currentTime: 0,
                chapters: [
                    PlaybackChapter(
                        id: 0,
                        start: 0,
                        end: 1_800,
                        title: "Chapter One"
                    ),
                    PlaybackChapter(
                        id: 1,
                        start: 1_800,
                        end: 3_600,
                        title: "Chapter Two"
                    ),
                ],
                source: .direct([
                    AppPlaybackTrack(
                        url: URL(
                            fileURLWithPath: "/tmp/bleat-ui-test-audio.m4b"
                        ),
                        startOffset: 0,
                        duration: 3_600,
                        title: "The Test Audiobook"
                    )
                ])
            )
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

        func deleteBook(
            for account: ServerAccount,
            detail: LibraryBookDetail,
            mode: BookDeletionMode
        ) async throws(AppServiceError) -> AppBookDeletionOutcome {
            .deleted
        }

        func bookmarks(
            for account: ServerAccount,
            itemID: LibraryItemID
        ) async throws(AppServiceError) -> [AudioBookmark] {
            [
                AudioBookmark(
                    libraryItemID: itemID,
                    time: 600,
                    title: "A useful moment",
                    createdAtMilliseconds: 1
                )
            ]
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

        private var libraryTitle: String {
            scenario == .refresh && firstPageRequests >= 3
                ? "The Refreshed Library Audiobook"
                : "The Test Audiobook"
        }

        private static func fixtureIDs() throws(AppServiceError) -> FixtureIDs {
            guard let primaryAuthor = AuthorID(rawValue: "author-1"),
                  let secondaryAuthor = AuthorID(rawValue: "author-2"),
                  let primarySeries = SeriesID(rawValue: "series-1"),
                  let secondarySeries = SeriesID(rawValue: "series-2")
            else {
                throw .pageRequest(.invalidFilter)
            }
            return FixtureIDs(
                primaryAuthor: primaryAuthor,
                secondaryAuthor: secondaryAuthor,
                primarySeries: primarySeries,
                secondarySeries: secondarySeries
            )
        }

        private static func book(
            id: String,
            title: String,
            libraryID: LibraryID,
            ids: FixtureIDs,
            series: [LibraryBookSeries]? = nil,
            collapsedSeries: LibraryCollapsedSeries? = nil
        ) -> LibraryBookSummary {
            LibraryBookSummary(
                id: LibraryItemID(rawValue: id),
                libraryID: libraryID,
                title: title,
                subtitle: nil,
                authorName: "Test Author",
                narratorName: "Test Narrator",
                seriesName: series?.first?.name,
                authors: [
                    LibraryBookContributor(
                        id: ids.primaryAuthor,
                        name: "Test Author"
                    ),
                    LibraryBookContributor(
                        id: ids.secondaryAuthor,
                        name: "Test Coauthor"
                    ),
                ],
                series: series ?? [
                    LibraryBookSeries(
                        id: ids.primarySeries,
                        name: "Test Series",
                        sequence: "1"
                    ),
                    LibraryBookSeries(
                        id: ids.secondarySeries,
                        name: "Companion Series",
                        sequence: "1"
                    ),
                ],
                collapsedSeries: collapsedSeries,
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

        private static func firstPageItem(
            libraryID: LibraryID
        ) throws(AppServiceError) -> [LibraryBookSummary] {
            let ids = try fixtureIDs()
            return [
                LibraryBookSummary(
                    id: LibraryItemID(rawValue: "ui-search-book"),
                    libraryID: libraryID,
                    title: "The Search Result",
                    subtitle: nil,
                    authorName: "Test Author",
                    narratorName: "Test Narrator",
                    seriesName: "Test Series",
                    authors: [
                        LibraryBookContributor(
                            id: ids.primaryAuthor,
                            name: "Test Author"
                        ),
                        LibraryBookContributor(
                            id: ids.secondaryAuthor,
                            name: "Test Coauthor"
                        ),
                    ],
                    series: [
                        LibraryBookSeries(
                            id: ids.primarySeries,
                            name: "Test Series",
                            sequence: "1"
                        ),
                        LibraryBookSeries(
                            id: ids.secondarySeries,
                            name: "Companion Series",
                            sequence: "1"
                        ),
                    ],
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

        private static func makeAccount(
            hasManagementPermissions: Bool
        )
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
                                download: hasManagementPermissions,
                                update: hasManagementPermissions,
                                delete: hasManagementPermissions,
                                upload: hasManagementPermissions,
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

#endif
