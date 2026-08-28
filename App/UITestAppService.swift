#if DEBUG || BLEAT_UI_TESTING
    import BleatCore
    import Foundation

    private enum UITestScenario: String, Sendable {
        case signedOut = "--ui-testing-signed-out"
        case openID = "--ui-testing-openid"
        case signedIn = "--ui-testing-signed-in"
        case refresh = "--ui-testing-refresh"
        case emptyLibraryRefreshFailure =
            "--ui-testing-empty-library-refresh-failure"
        case limitedPermissions = "--ui-testing-limited-permissions"
        case rejectLogin = "--ui-testing-reject-login"
        case submissionProgress = "--ui-testing-submission-progress"
        case playback = "--ui-testing-playback"
        case launching = "--ui-testing-launching"
        case unavailableStartup = "--ui-testing-unavailable-startup"
        case largeLibrary = "--ui-testing-large-library"
    }

    private enum UITestScenarioStorage {
        static let persistedScenarioKey = "Bleat.UITest.persistedScenario"
        static let persistArgument = "--ui-testing-persist-scenario"
        static let clearArgument = "--ui-testing-clear-persisted-scenario"
        static let clearDeepLinkReceiptArgument =
            "--ui-testing-clear-deep-link-receipt"
        static let resetRemoteTelemetryConsentArgument =
            "--ui-testing-reset-telemetry-consent"
        static let enableRemoteTelemetryConsentArgument =
            "--ui-testing-enable-telemetry-consent"
        static let persistLocalDataResetArgument =
            "--ui-testing-persist-local-data-reset"
        static let clearLocalDataResetArgument =
            "--ui-testing-clear-local-data-reset"
        static let localDataResetCompletedKey =
            "Bleat.UITest.localDataResetCompleted"
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

        static var bootstrapError: AppBootstrapError? {
            ProcessInfo.processInfo.arguments.contains(
                UITestScenario.unavailableStartup.rawValue
            ) ? .persistenceUnavailable : nil
        }

        private let scenario: UITestScenario
        private let accountResult: Result<ServerAccount, AppServiceError>
        private var firstPageRequests = 0
        private var homeShelfRequests = 0
        private var libraryRequests = 0

        static func current() -> UITestAppService? {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains(
                UITestScenarioStorage.clearDeepLinkReceiptArgument
            ) {
                UITestDeepLinkReceipt.clear()
            }
            if arguments.contains(
                UITestScenarioStorage.resetRemoteTelemetryConsentArgument
            ) {
                UserDefaults.standard.removeObject(
                    forKey: RemoteTelemetryConsentStore.enabledKey
                )
            }
            if arguments.contains(
                UITestScenarioStorage.enableRemoteTelemetryConsentArgument
            ) {
                UserDefaults.standard.set(
                    true,
                    forKey: RemoteTelemetryConsentStore.enabledKey
                )
                UserDefaults.standard.removeObject(
                    forKey: RemoteTelemetryConsentStore.generationKey
                )
            }
            if arguments.contains(
                UITestScenarioStorage.clearLocalDataResetArgument
            ) {
                UserDefaults.standard.removeObject(
                    forKey: UITestScenarioStorage.localDataResetCompletedKey
                )
            }
            if arguments.contains(UITestScenarioStorage.clearArgument) {
                UserDefaults.standard.removeObject(
                    forKey: UITestScenarioStorage.persistedScenarioKey
                )
                return UITestAppService(scenario: .signedOut)
            }
            if let scenario =
                arguments
                .compactMap(UITestScenario.init(rawValue:))
                .first
            {
                if arguments.contains(
                    UITestScenarioStorage.persistLocalDataResetArgument
                ), UserDefaults.standard.bool(
                    forKey: UITestScenarioStorage.localDataResetCompletedKey
                ) {
                    return UITestAppService(scenario: .signedOut)
                }
                if arguments.contains(UITestScenarioStorage.persistArgument) {
                    UserDefaults.standard.set(
                        scenario.rawValue,
                        forKey: UITestScenarioStorage.persistedScenarioKey
                    )
                }
                return UITestAppService(scenario: scenario)
            }
            guard
                let rawScenario = UserDefaults.standard.string(
                    forKey: UITestScenarioStorage.persistedScenarioKey
                ), let scenario = UITestScenario(rawValue: rawScenario)
            else {
                return nil
            }
            return UITestAppService(scenario: scenario)
        }

        private init(scenario: UITestScenario) {
            self.scenario = scenario
            accountResult = Self.makeAccount(
                hasManagementPermissions: scenario != .limitedPermissions,
                deniesPlayback: ProcessInfo.processInfo.arguments.contains(
                    "--ui-testing-playback-denied"
                )
            )
        }

        func accounts()
            async throws(AppServiceError) -> [ServerAccount]
        {
            guard
                [
                    .signedIn,
                    .refresh,
                    .emptyLibraryRefreshFailure,
                    .limitedPermissions,
                    .playback,
                    .largeLibrary,
                ]
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
                [
                    .signedIn,
                    .refresh,
                    .emptyLibraryRefreshFailure,
                    .limitedPermissions,
                    .playback,
                    .largeLibrary,
                ]
                .contains(scenario)
            else {
                return nil
            }
            return try account()
        }

        func activateAccount(
            _ account: ServerAccount
        ) async throws(AppServiceError) {}

        func discoverServer(
            serverAddress: String
        ) async throws(AppServiceError) -> DiscoveredServer {
            let account = try account()
            guard
                let version = AudiobookshelfServerVersion(
                    account.serverVersion
                )
            else {
                throw .accountStore(.persistenceFailed)
            }
            return DiscoveredServer(
                baseURL: account.server,
                version: version,
                language: "en-us",
                authenticationMethods: scenario == .openID
                    ? [.local, .openID]
                    : account.authenticationMethods,
                authenticationFormData: nil
            )
        }

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

        func loginWithOpenID(
            serverAddress: String,
            progress: @escaping AccountSubmissionProgress
        ) async throws(AppServiceError) -> ServerAccount {
            throw .onboarding(.openIDAuthenticationUnavailable)
        }

        func reauthenticate(
            _ account: ServerAccount,
            password: String
        ) async throws(AppServiceError) -> ServerAccount {
            try self.account()
        }

        func reauthenticateWithOpenID(
            _ account: ServerAccount,
            progress: @escaping AccountSubmissionProgress
        ) async throws(AppServiceError) -> ServerAccount {
            throw .onboarding(.openIDAuthenticationUnavailable)
        }

        func libraries(
            for account: ServerAccount
        ) async throws(AppServiceError) -> [LibrarySummary] {
            libraryRequests += 1
            if scenario == .emptyLibraryRefreshFailure {
                guard libraryRequests == 1 else {
                    throw .libraryRepository(.remote(.unexpectedStatus(503)))
                }
                return []
            }
            return [
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
            if scenario == .largeLibrary {
                return Self.largeLibraryPage(
                    libraryID: libraryID,
                    request: request
                )
            }
            let ids = try Self.fixtureIDs()
            if request.filter == nil, request.page == 0 {
                firstPageRequests += 1
                if scenario == .refresh, firstPageRequests >= 3 {
                    try? await Task.sleep(for: .seconds(2))
                }
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
                || request.filter
                    == LibraryItemFilter(authorID: ids.secondaryAuthor)
            {
                return LibraryItemsPage(
                    items: [primaryBook],
                    total: 1,
                    page: 0,
                    limit: 1
                )
            }
            if request.filter == LibraryItemFilter(seriesID: ids.primarySeries)
            {
                return LibraryItemsPage(
                    items: primarySeriesBooks,
                    total: primarySeriesBooks.count,
                    page: 0,
                    limit: primarySeriesBooks.count
                )
            }
            if request.filter
                == LibraryItemFilter(seriesID: ids.secondarySeries)
            {
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
            if scenario == .refresh, homeShelfRequests >= 2 {
                try? await Task.sleep(for: .seconds(2))
            }
            let title =
                scenario == .refresh && homeShelfRequests >= 2
                ? "The Refreshed Home Audiobook"
                : "The Test Audiobook"
            let collapsedSeries = LibraryCollapsedSeries(
                id: ids.primarySeries,
                name: "Test Series",
                libraryItemIDs: [
                    LibraryItemID(rawValue: "ui-home-series"),
                    LibraryItemID(rawValue: "ui-home-series-two"),
                ],
                numBooks: 2,
                sequenceList: ["1", "2"]
            )
            var items = [
                Self.book(
                    id: "ui-book",
                    title: title,
                    libraryID: libraryID,
                    ids: ids
                )
            ]
            if scenario == .playback {
                items.append(
                    Self.book(
                        id: "ui-book-two",
                        title: "The Other Audiobook",
                        libraryID: libraryID,
                        ids: ids
                    )
                )
            }
            items.append(
                Self.book(
                    id: "ui-home-series",
                    title: "Test Series",
                    libraryID: libraryID,
                    ids: ids,
                    collapsedSeries: collapsedSeries
                )
            )
            return [
                LibraryBookShelf(
                    id: "continue-listening",
                    label: "Continue Listening",
                    labelLocalizationKey: nil,
                    items: items,
                    total: items.count
                )
            ]
        }

        func search(
            for account: ServerAccount,
            libraryID: LibraryID,
            query: String
        ) async throws(AppServiceError) -> LibrarySearchResults {
            if scenario == .largeLibrary {
                let trimmed = query.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !trimmed.isEmpty else {
                    return LibrarySearchResults(books: [])
                }
                let matchCount = min(20, Self.largeLibraryCount)
                let request: LibraryItemsPageRequest
                do {
                    request = try LibraryItemsPageRequest(
                        page: 0,
                        limit: matchCount
                    )
                } catch let error {
                    throw AppServiceError.pageRequest(error)
                }
                let page = Self.largeLibraryPage(
                    libraryID: libraryID,
                    request: request
                )
                return LibrarySearchResults(books: page.items)
            }
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
            if ProcessInfo.processInfo.arguments.contains(
                "--ui-testing-slow-context-download"
            ) {
                try? await Task.sleep(for: .seconds(8))
            }
            if itemID.rawValue == "ui-search-book",
                ProcessInfo.processInfo.arguments.contains(
                    "--ui-testing-context-download-failure"
                )
            {
                throw .bookDetail(
                    .remote(.authentication(.requestTransportFailed))
                )
            }
            let ids = try Self.fixtureIDs()
            return LibraryBookDetail(
                id: itemID,
                libraryID: libraryID,
                bookID: BookID(rawValue: "ui-book"),
                title: Self.title(for: itemID),
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
                genres: ["Fiction", "Adventure"],
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

        func refreshedBookDetail(
            for account: ServerAccount,
            libraryID: LibraryID,
            itemID: LibraryItemID
        ) async throws(AppServiceError) -> LibraryBookDetail {
            try await bookDetail(
                for: account,
                libraryID: libraryID,
                itemID: itemID
            )
        }

        func cachedChapterTranscripts(
            accountID: AccountID,
            itemID: LibraryItemID
        ) async throws(AppServiceError) -> [CachedChapterTranscript] {
            guard
                ProcessInfo.processInfo.arguments.contains(
                    "--ui-testing-transcription-cache"
                )
            else {
                return []
            }
            return [
                CachedChapterTranscript(
                    chapterID: 0,
                    chapterTitle: "Chapter One",
                    chapterStartMilliseconds: 0,
                    chapterEndMilliseconds: 1_800_000,
                    localeIdentifier: "en-AU",
                    segments: [
                        CachedTranscriptSegment(
                            startMilliseconds: 10_000,
                            endMilliseconds: 12_000,
                            text: "The Doomsday Scenario begins"
                        )
                    ]
                ),
                CachedChapterTranscript(
                    chapterID: 1,
                    chapterTitle: "Chapter Two",
                    chapterStartMilliseconds: 1_800_000,
                    chapterEndMilliseconds: 3_600_000,
                    localeIdentifier: "en-AU",
                    segments: [
                        CachedTranscriptSegment(
                            startMilliseconds: 1_810_000,
                            endMilliseconds: 1_812_000,
                            text: "Another DOOMSDAY mention"
                        )
                    ]
                ),
            ]
        }

        func saveCachedChapterTranscript(
            _ transcript: CachedChapterTranscript,
            accountID: AccountID,
            itemID: LibraryItemID
        ) async throws(AppServiceError) {}

        func cachedChapterTranscriptionTaskState(
            accountID: AccountID,
            itemID: LibraryItemID
        ) async throws(AppServiceError)
            -> CachedChapterTranscriptionTaskState?
        {
            guard
                ProcessInfo.processInfo.arguments.contains(
                    "--ui-testing-transcription-cache"
                )
            else {
                return nil
            }
            let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
            return CachedChapterTranscriptionTaskState(
                taskID: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000001"
                ) ?? UUID(),
                selectedChapterIDs: [0, 1],
                completedChapterIDs: [0, 1],
                currentChapterID: nil,
                outcome: .succeeded,
                failure: nil,
                startedAt: startedAt,
                finishedAt: startedAt.addingTimeInterval(125),
                durationMilliseconds: 125_000
            )
        }

        func saveCachedChapterTranscriptionTaskState(
            _ state: CachedChapterTranscriptionTaskState,
            accountID: AccountID,
            itemID: LibraryItemID
        ) async throws(AppServiceError) {}

        func openPlayback(
            for account: ServerAccount,
            itemID: LibraryItemID,
            preference: PlaybackPreference,
            deviceInfo: PlaybackDeviceInfo
        ) async throws(AppServiceError) -> AppPlaybackPreparation {
            guard scenario == .playback else {
                throw .playbackSession(.requestFailed)
            }
            if ProcessInfo.processInfo.arguments.contains(
                "--ui-testing-slow-playback"
            ) {
                try? await Task.sleep(for: .seconds(3))
            }
            if ProcessInfo.processInfo.arguments.contains(
                "--ui-testing-playback-failure"
            ) {
                throw .playbackSession(.requestFailed)
            }
            let title = Self.title(for: itemID)
            let usesLongChapterList = ProcessInfo.processInfo.arguments
                .contains("--ui-testing-long-chapter-list")
            let chapters =
                usesLongChapterList
                ? (0..<24).map { index in
                    PlaybackChapter(
                        id: index % 3,
                        start: Double(index * 150),
                        end: Double((index + 1) * 150),
                        title: "Chapter \(index + 1)"
                    )
                }
                : [
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
                ]
            return AppPlaybackPreparation(
                sessionID: nil,
                itemID: itemID,
                title: title,
                duration: 3_600,
                currentTime: usesLongChapterList ? 2_710 : 0,
                chapters: chapters,
                source: .direct([
                    AppPlaybackTrack(
                        url: URL(
                            fileURLWithPath: "/tmp/bleat-ui-test-audio.m4b"
                        ),
                        startOffset: 0,
                        duration: 3_600,
                        title: title
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
            DownloadPlan(
                itemID: itemID,
                tracks: [
                    DownloadTrackPlan(
                        index: 0,
                        inode: "ui-download",
                        expectedByteLength: 1,
                        mimeType: "audio/mp4",
                        safeExtension: .m4b,
                        destinationEntry: "00000.m4b",
                        startOffset: 0,
                        duration: 3_600
                    )
                ]
            )
        }

        func authorizedDownloadRequest(
            for account: ServerAccount,
            identity: DownloadTaskIdentity
        ) async throws(AppServiceError) -> URLRequest {
            URLRequest(
                url: account.server.url
                    .appending(path: "ui-download")
                    .appending(path: identity.itemID.rawValue)
            )
        }

        func replacementDownloadRequest(
            for account: ServerAccount,
            identity: DownloadTaskIdentity,
            rejectedRequest: URLRequest
        ) async throws(AppServiceError) -> URLRequest {
            rejectedRequest
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

        func allBookProgress(
            for account: ServerAccount
        ) async throws(AppServiceError) -> [LibraryBookProgress] {
            [
                LibraryBookProgress(
                    id: "ui-progress",
                    userID: account.user.id,
                    libraryItemID: LibraryItemID(rawValue: "ui-book"),
                    bookID: BookID(rawValue: "ui-book"),
                    duration: 3_600,
                    progress: 1,
                    currentTime: 3_600,
                    isFinished: true,
                    hideFromContinueListening: false,
                    lastUpdateMilliseconds: 1,
                    startedAtMilliseconds: 1,
                    finishedAtMilliseconds: 1
                )
            ]
        }

        func updateBookProgress(
            for account: ServerAccount,
            itemID: LibraryItemID,
            update: BookProgressUpdate
        ) async throws(AppServiceError) {}

        func removeAccount(
            _ account: ServerAccount
        ) async throws(AppServiceError) {}

        func resetLocalData() async throws(AppServiceError) {
            guard ProcessInfo.processInfo.arguments.contains(
                UITestScenarioStorage.persistLocalDataResetArgument
            ) else {
                return
            }
            UserDefaults.standard.set(
                true,
                forKey: UITestScenarioStorage.localDataResetCompletedKey
            )
        }

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

        private static func largeLibraryPage(
            libraryID: LibraryID,
            request: LibraryItemsPageRequest
        ) -> LibraryItemsPage {
            let total = largeLibraryCount
            let limit = request.limit
            let start = request.page * limit
            let end = min(start + limit, total)
            let items: [LibraryBookSummary] = (start..<end).map { index in
                let authorName = "Author \(index % 8)"
                let authorID = AuthorID(rawValue: "author-\(index % 8)")
                let years = ["1950", "1970", "1990", "2010", "2020"]
                let baseMillis =
                    Int64(1_700_000_000_000)
                    + Int64(index) * 3_600_000
                return LibraryBookSummary(
                    id: LibraryItemID(rawValue: "book-\(index)"),
                    libraryID: libraryID,
                    title: "Book Title \(index)",
                    subtitle: nil,
                    authorName: authorName,
                    narratorName: nil,
                    seriesName: nil,
                    authors: authorID.map {
                        [LibraryBookContributor(id: $0, name: authorName)]
                    } ?? [],
                    series: [],
                    collapsedSeries: nil,
                    genres: ["Fiction"],
                    tags: [],
                    publisher: nil,
                    publishedYear: years[index % years.count],
                    duration: Double(45 + (index % 436)),
                    trackCount: (index % 20) + 1,
                    chapterCount: (index % 150) + 1,
                    addedAtMilliseconds: baseMillis,
                    updatedAtMilliseconds: baseMillis
                        + Int64((index % 24) * 3_600_000),
                    isExplicit: index % 10 == 0,
                    isAbridged: index % 25 == 0
                )
            }
            return LibraryItemsPage(
                items: items,
                total: total,
                page: request.page,
                limit: limit
            )
        }

        private static var largeLibraryCount: Int {
            if let raw = ProcessInfo.processInfo.environment[
                "BLEAT_PERF_SEED_COUNT"],
                let value = Int(raw), value > 0
            {
                return value
            }
            return 10_000
        }

        private static func makeAccount(
            hasManagementPermissions: Bool,
            deniesPlayback: Bool
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
                                accessAllLibraries: !deniesPlayback,
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

        private static func title(for itemID: LibraryItemID) -> String {
            switch itemID.rawValue {
            case "ui-search-book": "The Search Result"
            case "ui-book-two": "The Other Audiobook"
            default: "The Test Audiobook"
            }
        }
    }
#endif
