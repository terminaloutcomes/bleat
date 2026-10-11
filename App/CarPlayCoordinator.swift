#if canImport(CarPlay) && !os(macOS)
    import BleatCore
    import CarPlay
    import Foundation
    import Observation
    import UIKit

    enum CarPlayContentState<Value: Equatable & Sendable>:
        Equatable, Sendable
    {
        case loading
        case loaded(Value)
        case empty
        case failed(AppFailure)
    }

    enum CarPlayAction: Equatable, Sendable {
        case playBook(LibraryBookSummary)
        case playDownload(DownloadID)
        case openLibraryFolder(CarPlayLibraryBrowser.Folder, depth: Int)
        case retryHome
        case retryLibrary
        case retryLibraryDiscovery
    }

    /// Transfers CarPlay's unannotated Objective-C completion block to the UI
    /// task. Each selection creates one box, owned by one task, and invokes the
    /// block exactly once after processing; the box never carries app state.
    private struct CarPlaySelectionCompletion: @unchecked Sendable {
        let callback: () -> Void

        init(_ callback: @escaping () -> Void) { self.callback = callback }
        func callAsFunction() { callback() }
    }

    @MainActor
    protocol CarPlayPresenting: AnyObject {
        func setRoot(_ template: CPTemplate)
        func push(_ template: CPTemplate)
        func pop()
        func present(_ template: CPTemplate)
        func dismiss()
    }

    @MainActor
    final class CarPlayInterfacePresenter: CarPlayPresenting {
        private let interfaceController: CPInterfaceController

        init(interfaceController: CPInterfaceController) {
            self.interfaceController = interfaceController
        }

        func observeTemplates(_ delegate: any CPInterfaceControllerDelegate) {
            interfaceController.delegate = delegate
        }

        func contains(_ identity: ObjectIdentifier) -> Bool {
            interfaceController.templates.contains {
                ObjectIdentifier($0) == identity
            }
        }

        func setRoot(_ template: CPTemplate) {
            interfaceController.setRootTemplate(
                template,
                animated: true
            ) { _, _ in }
        }

        func push(_ template: CPTemplate) {
            interfaceController.pushTemplate(
                template,
                animated: true
            ) { _, _ in }
        }

        func pop() {
            interfaceController.popTemplate(animated: true) { _, _ in }
        }

        func present(_ template: CPTemplate) {
            interfaceController.presentTemplate(
                template,
                animated: true
            ) { _, _ in }
        }

        func dismiss() {
            interfaceController.dismissTemplate(animated: true) {
                _, _ in
            }
        }
    }

    @MainActor
    final class CarPlayCoordinator: NSObject, CPSessionConfigurationDelegate,
        CPInterfaceControllerDelegate
    {
        private struct AccountPresentation: Equatable, Sendable {
            let id: AccountID
            let server: NormalizedServerURL
        }

        private struct PlaybackPresentation: Equatable, Sendable {
            let itemID: LibraryItemID?
            let accountID: AccountID?
        }

        private struct DownloadPresentation: Equatable, Sendable {
            let downloadID: DownloadID
            let accountID: AccountID
            let itemID: LibraryItemID
            let title: String
            let author: String
            let updatedAtMilliseconds: Int64
            let server: NormalizedServerURL?
        }

        private struct TemplatePresentation: Equatable, Sendable {
            let phase: AppPhase
            let account: AccountPresentation?
            let selectedLibraryID: LibraryID?
            let libraries: ResourceState<[LibrarySummary]>
            let homeShelves: ResourceState<[LibraryBookShelf]>
            let books: ResourceState<[LibraryBookSummary]>
            let libraryFailure: AppFailure?
            let libraryGeneration: UInt64
            let maximumItems: Int
            let maximumSections: Int
            let downloads: [DownloadPresentation]
            let playback: PlaybackPresentation
        }

        private enum RootContext: Equatable {
            case signedIn(AccountID)
            case signedOut
            case unavailable
        }

        private var searchController: CarPlaySearchController?
        private var sessionConfiguration: CPSessionConfiguration?
        private var keyboardAvailable = true
        private let searchEnabled: @MainActor () -> Bool
        private let model: AppModel
        private let coverLoader: BookCoverImageLoader
        private var presenter: (any CarPlayPresenting)?
        private var rootContext: RootContext?
        private var homeTemplate: CPListTemplate?
        private var libraryTemplate: CPListTemplate?
        private var downloadsTemplate: CPListTemplate?
        private var tabTemplate: CPTabBarTemplate?
        private let artworkCache = NSCache<NSString, UIImage>()
        private var artworkTasks: [Task<Void, Never>] = []
        private var renderedPresentation: TemplatePresentation?
        private var presentationGeneration: UInt64 = 0
        private var libraryPage: ResourceState<[LibraryBookSummary]> = .idle
        private var libraryFailure: AppFailure?
        private struct CatalogSnapshot: Equatable {
            let total: Int
            let limit: Int
        }
        private var librarySnapshot: CatalogSnapshot?
        private var catalogGeneration: UInt64 = 0
        private var nextLibraryPage = 0
        private struct FolderPresentation {
            let template: CPListTemplate
            let folder: CarPlayLibraryBrowser.Folder
            let depth: Int
        }
        private var folderTemplates: [FolderPresentation] = []
        private var browserFailure: CarPlayLibraryBrowser.Failure?
        private var libraryLoading = false
        private(set) var libraryTask: Task<Void, Never>?
        private struct LibraryContext: Equatable {
            let accountID: AccountID?
            let libraryID: LibraryID?
            let generation: UInt64
        }
        private var libraryContext: LibraryContext?
        private var limitObservationTask: Task<Void, Never>?
        private let contentLimits: @MainActor () -> (items: Int, sections: Int)
        #if DEBUG
            private(set) var observationCallbackCountForTesting = 0
            private(set) var observationRefreshCountForTesting = 0
        #endif

        init(
            model: AppModel,
            coverLoader: BookCoverImageLoader = .shared,
            searchEnabled: @escaping @MainActor () -> Bool = {
                guard #available(iOS 27.0, *) else { return false }
                return Bundle.main.object(
                    forInfoDictionaryKey: "BleatCarPlayMode") as? String
                    == "enabled"
            },
            contentLimits:
                @escaping @MainActor () -> (items: Int, sections: Int) = {
                    (
                        CPListTemplate.maximumItemCount,
                        CPListTemplate.maximumSectionCount
                    )
                }
        ) {
            self.model = model
            self.coverLoader = coverLoader
            self.contentLimits = contentLimits
            self.searchEnabled = searchEnabled
            super.init()
            artworkCache.countLimit = 256
        }

        func connect(_ presenter: any CarPlayPresenting) {
            disconnect()
            self.presenter = presenter
            (presenter as? CarPlayInterfacePresenter)?.observeTemplates(self)
            let configuration = CPSessionConfiguration(delegate: self)
            sessionConfiguration = configuration
            keyboardAvailable = !configuration.limitedUserInterfaces.contains(
                .keyboard)
            presentationGeneration &+= 1
            configureNowPlayingTemplate()
            refreshTemplates()
            observeModel()
            let connection = presentationGeneration
            limitObservationTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch {
                        return
                    }
                    guard let self, self.presentationGeneration == connection
                    else { return }
                    self.refreshTemplates()
                }
            }
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                await model.start()
                refreshTemplates()
            }
        }

        func waitForLibraryLoad() async {
            await libraryTask?.value
        }

        func disconnect() {
            searchController?.invalidate()
            searchController = nil
            sessionConfiguration?.delegate = nil
            sessionConfiguration = nil
            presentationGeneration &+= 1
            libraryTask?.cancel()
            limitObservationTask?.cancel()
            limitObservationTask = nil
            libraryTask = nil
            libraryContext = nil
            libraryPage = .idle
            libraryFailure = nil
            nextLibraryPage = 0
            librarySnapshot = nil
            folderTemplates = []
            browserFailure = nil
            libraryLoading = false
            for task in artworkTasks {
                task.cancel()
            }
            artworkTasks = []
            presenter = nil
            rootContext = nil
            homeTemplate = nil
            libraryTemplate = nil
            downloadsTemplate = nil
            tabTemplate = nil
            renderedPresentation = nil
        }

        func refreshTemplates() {
            guard presenter != nil else {
                return
            }
            let context = LibraryContext(
                accountID: model.account?.id,
                libraryID: model.selectedLibrary?.id,
                generation: model.libraryPageGeneration)
            if libraryContext != context {
                searchController?.invalidate()
                searchController = nil
                libraryContext = context
                libraryTask?.cancel()
                libraryPage = .idle
                libraryFailure = nil
                nextLibraryPage = 0
                librarySnapshot = nil
                folderTemplates = []
                browserFailure = nil
                rootContext = nil
                libraryLoading = false
                if model.account != nil, model.selectedLibrary != nil {
                    libraryPage = .loading
                    let connection = presentationGeneration
                    let context = model.libraryPageGeneration
                    libraryTask = Task { @MainActor [weak self] in
                        await self?.loadLibraryPage(
                            connection: connection, context: context)
                    }
                }
            }
            searchController?.updateLimits(keyboardAvailable: keyboardAvailable)
            let presentation = makeTemplatePresentation()
            guard renderedPresentation != presentation else {
                return
            }
            renderedPresentation = presentation
            for task in artworkTasks {
                task.cancel()
            }
            artworkTasks = []
            switch presentation.phase {
            case .launching:
                showUnavailableRoot(
                    title: "Loading Bleat",
                    detail: nil,
                    activity: true,
                    context: .unavailable
                )
            case .signedIn:
                guard presentation.account != nil else {
                    showUnavailableRoot(
                        title: "Account unavailable",
                        detail: "Open Bleat on iPhone.",
                        activity: false,
                        context: .unavailable
                    )
                    return
                }
                showSignedInRoot(presentation)
            case .signedOut:
                showSignedOutRoot()
            case .unavailable(let failure):
                showUnavailableRoot(
                    title: "Bleat unavailable",
                    detail: failure.message,
                    activity: false,
                    context: .unavailable
                )
            }
        }

        private func showSignedInRoot(
            _ presentation: TemplatePresentation
        ) {
            guard let account = presentation.account else {
                return
            }
            if homeTemplate == nil || rootContext != .signedIn(account.id) {
                homeTemplate = makeTabTemplate(
                    title: "Home",
                    systemImage: "house"
                )
                libraryTemplate = makeTabTemplate(
                    title: "Library",
                    systemImage: "books.vertical", showsTitle: false
                )
                downloadsTemplate = makeTabTemplate(
                    title: "Downloads",
                    systemImage: "arrow.down.circle"
                )
            }
            guard let homeTemplate,
                let libraryTemplate,
                let downloadsTemplate
            else {
                return
            }
            updateHomeTemplate(homeTemplate, presentation: presentation)
            updateLibraryTemplate(libraryTemplate, presentation: presentation)
            for folder in folderTemplates {
                updateBrowserTemplate(
                    folder.template, books: folder.folder.books,
                    depth: folder.depth, presentation: presentation)
            }
            updateDownloadsTemplate(
                downloadsTemplate,
                downloads: presentation.downloads,
                playback: presentation.playback,
                signedOut: false
            )

            let context = RootContext.signedIn(account.id)
            guard rootContext != context || tabTemplate == nil else {
                return
            }
            let tabs = CPTabBarTemplate(
                templates: [
                    homeTemplate,
                    libraryTemplate,
                    downloadsTemplate,
                ]
            )
            tabTemplate = tabs
            rootContext = context
            presenter?.setRoot(tabs)
        }

        private func showSignedOutRoot() {
            let template =
                downloadsTemplate
                ?? makeTabTemplate(
                    title: "Downloads",
                    systemImage: "arrow.down.circle"
                )
            downloadsTemplate = template
            let presentation = makeTemplatePresentation(accountID: nil)
            updateDownloadsTemplate(
                template,
                downloads: presentation.downloads,
                playback: presentation.playback,
                signedOut: true
            )
            guard rootContext != .signedOut else {
                return
            }
            rootContext = .signedOut
            presenter?.setRoot(template)
        }

        private func showUnavailableRoot(
            title: String,
            detail: String?,
            activity: Bool,
            context: RootContext
        ) {
            let template = CPListTemplate(title: "Bleat", sections: [])
            template.emptyViewTitleVariants = [title]
            template.emptyViewSubtitleVariants = detail.map { [$0] } ?? []
            template.showsSpinnerWhileEmpty = activity
            rootContext = context
            presenter?.setRoot(template)
        }

        private func makeTabTemplate(
            title: String,
            systemImage: String, showsTitle: Bool = true
        ) -> CPListTemplate {
            let template = CPListTemplate(
                title: showsTitle ? title : nil, sections: [])
            template.tabTitle = title
            template.tabImage = UIImage(systemName: systemImage)
            return template
        }

        private func updateHomeTemplate(
            _ template: CPListTemplate,
            presentation: TemplatePresentation
        ) {
            switch homeState(for: presentation) {
            case .loading:
                template.updateSections([])
                template.emptyViewTitleVariants = ["Loading Home"]
                template.emptyViewSubtitleVariants = []
                template.showsSpinnerWhileEmpty = true
            case .empty:
                template.updateSections([])
                template.emptyViewTitleVariants = ["Nothing to play"]
                template.emptyViewSubtitleVariants = []
                template.showsSpinnerWhileEmpty = false
            case .failed(let failure):
                template.showsSpinnerWhileEmpty = false
                template.emptyViewTitleVariants = []
                template.emptyViewSubtitleVariants = []
                template.updateSections([
                    failureSection(
                        failure,
                        retry: failure.allowsRetry ? .retryHome : nil
                    )
                ])
            case .loaded(let shelves):
                template.showsSpinnerWhileEmpty = false
                template.emptyViewTitleVariants = []
                template.emptyViewSubtitleVariants = []
                var sections = shelves.map { shelf in
                    CPListSection(
                        items: shelf.items.map {
                            makeBookItem(
                                book: $0,
                                account: presentation.account,
                                playback: presentation.playback
                            )
                        },
                        header: shelf.label,
                        sectionIndexTitle: nil
                    )
                }
                if !presentation.downloads.isEmpty {
                    sections.append(
                        CPListSection(
                            items: presentation.downloads.map {
                                makeDownloadItem(
                                    $0,
                                    playback: presentation.playback
                                )
                            },
                            header: "Downloaded",
                            sectionIndexTitle: nil
                        )
                    )
                }
                template.updateSections(limit(sections: sections))
            }
        }

        private func updateLibraryTemplate(
            _ template: CPListTemplate,
            presentation: TemplatePresentation
        ) {
            template.trailingNavigationBarButtons = []
            updateSearchButton(template)
            switch libraryState(for: presentation) {
            case .loading:
                template.updateSections([])
                template.emptyViewTitleVariants = ["Loading Library"]
                template.emptyViewSubtitleVariants = []
                template.showsSpinnerWhileEmpty = true
            case .empty:
                template.updateSections([])
                template.emptyViewTitleVariants = ["No audiobooks"]
                template.emptyViewSubtitleVariants = []
                template.showsSpinnerWhileEmpty = false
            case .failed(let failure):
                template.showsSpinnerWhileEmpty = false
                template.emptyViewTitleVariants = []
                template.emptyViewSubtitleVariants = []
                template.updateSections(
                    presentation.maximumSections > 0
                        ? [
                            failureSection(
                                failure,
                                retry:
                                    failure.allowsRetry
                                    ? (failure.operation == .loadLibraries
                                        ? .retryLibraryDiscovery
                                        : .retryLibrary) : nil,
                                maximumItems: presentation.maximumItems
                            )
                        ] : [])
            case .loaded(let books):
                updateBrowserTemplate(
                    template, books: books, depth: 0, presentation: presentation
                )
            }
        }

        private func updateSearchButton(_ template: CPListTemplate) {
            guard searchEnabled(), #available(iOS 27.0, *),
                model.account != nil, model.selectedLibrary != nil,
                CPListTemplate.maximumHeaderGridButtonCount > 0,
                let image = UIImage(systemName: "magnifyingglass")
            else {
                template.headerGridButtons = []
                return
            }
            let connection = presentationGeneration
            let context = libraryContext
            let button = CPGridButton(titleVariants: ["Search"], image: image) {
                @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.presentationGeneration == connection,
                        self.libraryContext == context
                    else { return }
                    self.openSearch()
                }
            }
            button.isEnabled = keyboardAvailable
            template.headerGridButtons = [button]
        }

        func openSearch() {
            guard #available(iOS 27.0, *), searchEnabled(), keyboardAvailable,
                presenter != nil, searchController == nil,
                let account = model.account,
                let library = model.selectedLibrary
            else { return }
            searchController?.invalidate()
            let connection = presentationGeneration
            let context = libraryContext
            let controller = CarPlaySearchController(
                model: model, account: account, libraryID: library.id,
                isCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.presenter != nil
                        && self.presentationGeneration == connection
                        && self.libraryContext == context
                        && self.model.account?.id == account.id
                        && self.model.selectedLibrary?.id == library.id
                },
                maximumItems: { [weak self] in
                    guard let self, self.contentLimits().sections > 0 else {
                        return 0
                    }
                    // Keep keyboard results compact within the vehicle's list limits.
                    return min(5, self.contentLimits().items)
                },
                push: { [weak self] in self?.presenter?.push($0) },
                play: { [weak self] book in await self?.play(book) })
            searchController = controller
            presenter?.push(controller.template)
        }

        nonisolated func sessionConfiguration(
            _ sessionConfiguration: CPSessionConfiguration,
            limitedUserInterfacesChanged limitedUserInterfaces:
                CPLimitableUserInterface
        ) {
            let identity = ObjectIdentifier(sessionConfiguration)
            let available = !limitedUserInterfaces.contains(.keyboard)
            Task { @MainActor [weak self] in
                guard let self, self.presenter != nil,
                    let configuration = self.sessionConfiguration,
                    ObjectIdentifier(configuration) == identity
                else { return }
                self.keyboardAvailable = available
                if let template = self.libraryTemplate {
                    self.updateSearchButton(template)
                }
                self.searchController?.updateLimits(
                    keyboardAvailable: available)
                self.refreshTemplates()
            }
        }

        nonisolated func templateDidDisappear(
            _ aTemplate: CPTemplate, animated: Bool
        ) {
            let identity = ObjectIdentifier(aTemplate)
            Task { @MainActor [weak self] in
                guard let self,
                    let presenter = self.presenter
                        as? CarPlayInterfacePresenter,
                    !presenter.contains(identity)
                else { return }
                if let search = self.searchController,
                    ObjectIdentifier(search.template) == identity
                {
                    search.invalidate()
                    self.searchController = nil
                } else {
                    self.searchController?.templateRemoved(identity)
                }
            }
        }

        private func updateBrowserTemplate(
            _ template: CPListTemplate, books: [LibraryBookSummary], depth: Int,
            presentation: TemplatePresentation
        ) {
            template.showsSpinnerWhileEmpty = false
            template.emptyViewTitleVariants = []
            template.emptyViewSubtitleVariants = []
            let failure = depth == 0 ? presentation.libraryFailure : nil
            let reserved = failure == nil ? 0 : 1
            let browser = CarPlayLibraryBrowser(
                books: books,
                maximumItems: presentation.maximumItems - reserved,
                maximumSections: presentation.maximumSections, depth: depth)
            switch browser.contents {
            case .failure(let cause):
                template.updateSections([])
                switch cause {
                case .itemLimit:
                    template.emptyViewTitleVariants = [
                        "Car display list limit too small"
                    ]
                case .sectionLimit:
                    template.emptyViewTitleVariants = [
                        "Car display lists unavailable"
                    ]
                case .depthLimit:
                    template.emptyViewTitleVariants = [
                        "Library exceeds car browsing limits"
                    ]
                }
                template.emptyViewSubtitleVariants = [
                    "Browse Library on iPhone."
                ]
                if browserFailure != cause {
                    browserFailure = cause
                    Task { @MainActor [model] in
                        await model.recordCarPlayBrowserFailure(cause)
                    }
                }
            case .success(let entries):
                var items: [CPListItem] = []
                if let failure {
                    let item = libraryActionItem(
                        title: failure.title, detail: failure.message,
                        action: .retryLibrary,
                        libraryGeneration: presentation.libraryGeneration)
                    item.isEnabled = failure.allowsRetry && !libraryLoading
                    items.append(item)
                }
                items += entries.map { entry in
                    switch entry {
                    case .book(let book):
                        return makeBookItem(
                            book: book, account: presentation.account,
                            playback: presentation.playback)
                    case .folder(let folder):
                        return libraryActionItem(
                            title: folder.title, detail: nil,
                            action: .openLibraryFolder(
                                folder, depth: depth + 1),
                            libraryGeneration: presentation.libraryGeneration)
                    }
                }
                template.updateSections([
                    CPListSection(
                        items: items, header: nil, sectionIndexTitle: nil)
                ])
            }
        }

        private func loadLibraryPage(connection: UInt64, context: UInt64) async
        {
            guard !libraryLoading, presenter != nil,
                connection == presentationGeneration,
                context == model.libraryPageGeneration
            else { return }
            libraryLoading = true
            libraryFailure = nil
            refreshTemplates()
            var books: [LibraryBookSummary]
            if nextLibraryPage > 0, case .loaded(let retained) = libraryPage {
                books = retained
            } else {
                books = []
            }
            var ids = Set(books.map(\.id))
            do throws(AppServiceError) {
                while true {
                    let result = try await model.carPlayLibraryPage(
                        nextLibraryPage)
                    guard !Task.isCancelled, presenter != nil,
                        connection == presentationGeneration,
                        context == model.libraryPageGeneration
                    else { return }
                    let page = result.value
                    let snapshot = CatalogSnapshot(
                        total: page.total, limit: page.limit)
                    if let previous = librarySnapshot, previous != snapshot {
                        await model.recordCarPlayCatalogValidationFailure(
                            changed: true)
                        throw .libraryCatalogChanged
                    }
                    guard page.page == nextLibraryPage, page.limit > 0,
                        page.total >= 0,
                        books.count + page.items.count <= page.total,
                        page.hasNextPage
                            ? page.items.count == page.limit
                            : books.count + page.items.count == page.total,
                        page.items.allSatisfy({ ids.insert($0.id).inserted })
                    else {
                        await model.recordCarPlayCatalogValidationFailure()
                        throw .libraryRepository(.remote(.invalidPage))
                    }
                    librarySnapshot = snapshot
                    books += page.items
                    nextLibraryPage += 1
                    if !page.hasNextPage { break }
                }
                libraryPage = .loaded(books)
            } catch let error {
                guard !Task.isCancelled, presenter != nil,
                    connection == presentationGeneration,
                    context == model.libraryPageGeneration
                else { return }
                let failure = AppFailure(
                    operation: .loadLibraryPage, serviceError: error)
                if books.isEmpty, case .loaded(let retained) = libraryPage,
                    !retained.isEmpty
                {
                    libraryFailure = failure
                } else if books.isEmpty {
                    libraryPage = .failed(failure)
                } else {
                    libraryPage = .loaded(books)
                    libraryFailure = failure
                }
            }
            libraryLoading = false
            refreshTemplates()
        }

        private func libraryActionItem(
            title: String, detail: String?, action: CarPlayAction,
            libraryGeneration: UInt64
        ) -> CPListItem {
            let item = CPListItem(text: title, detailText: detail)
            let connection = presentationGeneration
            let catalog = catalogGeneration
            item.handler = { @Sendable [weak self] _, completion in
                let completed = CarPlaySelectionCompletion(completion)
                Task { @MainActor [weak self] in
                    defer { completed() }
                    guard let self, self.presentationGeneration == connection,
                        self.model.libraryPageGeneration == libraryGeneration,
                        self.catalogGeneration == catalog
                    else { return }
                    await self.perform(action)
                }
            }
            return item
        }

        private func updateDownloadsTemplate(
            _ template: CPListTemplate,
            downloads: [DownloadPresentation],
            playback: PlaybackPresentation,
            signedOut: Bool
        ) {
            template.showsSpinnerWhileEmpty = false
            if downloads.isEmpty {
                template.updateSections([])
                template.emptyViewTitleVariants = ["No downloads"]
                template.emptyViewSubtitleVariants =
                    signedOut
                    ? ["Open Bleat on iPhone to sign in."]
                    : []
            } else {
                template.emptyViewTitleVariants = []
                template.emptyViewSubtitleVariants = []
                template.updateSections([
                    CPListSection(
                        items: downloads.map {
                            makeDownloadItem($0, playback: playback)
                        },
                        header: nil,
                        sectionIndexTitle: nil
                    )
                ])
            }
        }

        private func homeState(
            for presentation: TemplatePresentation
        ) -> CarPlayContentState<[LibraryBookShelf]> {
            switch presentation.homeShelves {
            case .idle, .loading:
                return presentation.downloads.isEmpty
                    ? .loading
                    : .loaded([])
            case .loaded(let shelves):
                let hasDownloads = !presentation.downloads.isEmpty
                return shelves.isEmpty && !hasDownloads
                    ? .empty
                    : .loaded(shelves)
            case .failed(let failure):
                return presentation.downloads.isEmpty
                    ? .failed(failure)
                    : .loaded([])
            }
        }

        private func libraryState(
            for presentation: TemplatePresentation
        ) -> CarPlayContentState<[LibraryBookSummary]> {
            switch presentation.books {
            case .idle:
                guard presentation.selectedLibraryID == nil else {
                    return .loading
                }
                switch presentation.libraries {
                case .idle, .loading: return .loading
                case .loaded: return .empty
                case .failed(let failure): return .failed(failure)
                }
            case .loading:
                return .loading
            case .loaded(let page):
                return page.isEmpty ? .empty : .loaded(page)
            case .failed(let failure):
                return .failed(failure)
            }
        }

        private func makeTemplatePresentation() -> TemplatePresentation {
            makeTemplatePresentation(accountID: model.account?.id)
        }

        private func makeTemplatePresentation(
            accountID: AccountID?
        ) -> TemplatePresentation {
            let limits = contentLimits()
            let account = model.account.map {
                AccountPresentation(id: $0.id, server: $0.server)
            }
            return TemplatePresentation(
                phase: model.phase,
                account: account,
                selectedLibraryID: model.selectedLibrary?.id,
                libraries: model.libraries,
                homeShelves: model.homeShelves,
                books: libraryPage,
                libraryFailure: libraryFailure,
                libraryGeneration: model.libraryPageGeneration,
                maximumItems: limits.items, maximumSections: limits.sections,
                downloads: availableDownloadPresentations(
                    accountID: accountID
                ),
                playback: PlaybackPresentation(
                    itemID: model.playback.itemID,
                    accountID: model.playback.accountID
                )
            )
        }

        private func availableDownloadPresentations(
            accountID: AccountID?
        ) -> [DownloadPresentation] {
            model.downloads.records
                .filter { record in
                    (accountID == nil
                        || record.manifest.accountID == accountID)
                        && model.downloads.isFullBookAvailable(record)
                }
                .sorted {
                    $0.detail.title.localizedStandardCompare(
                        $1.detail.title
                    ) == .orderedAscending
                }
                .map { record in
                    let author = record.detail.authors
                        .map(\.name)
                        .joined(separator: ", ")
                    let server = model.accounts.first {
                        $0.id == record.manifest.accountID
                    }?.server
                    return DownloadPresentation(
                        downloadID: record.manifest.downloadID,
                        accountID: record.manifest.accountID,
                        itemID: record.detail.id,
                        title: record.detail.title,
                        author: author,
                        updatedAtMilliseconds:
                            record.detail.updatedAtMilliseconds,
                        server: server
                    )
                }
        }

        private func makeBookItem(
            book: LibraryBookSummary,
            account: AccountPresentation?,
            playback: PlaybackPresentation
        ) -> CPListItem {
            let coverURL = BookCoverURL.make(
                server: account?.server,
                itemID: book.id,
                updatedAtMilliseconds: book.updatedAtMilliseconds,
                width: 240,
                height: 240
            )
            let item = CPListItem(
                text: book.title,
                detailText: book.authorName,
                image: initialArtwork(
                    accountID: account?.id,
                    url: coverURL
                )
            )
            item.isPlaying =
                playback.itemID == book.id
                && playback.accountID == account?.id
            item.handler = { @Sendable [weak self] _, completion in
                let completed = CarPlaySelectionCompletion(completion)
                Task { @MainActor [weak self] in
                    await self?.perform(.playBook(book))
                    completed()
                }
            }
            loadArtwork(
                for: item,
                accountID: account?.id,
                url: coverURL
            )
            return item
        }

        private func makeDownloadItem(
            _ download: DownloadPresentation,
            playback: PlaybackPresentation
        ) -> CPListItem {
            let coverURL = BookCoverURL.make(
                server: download.server,
                itemID: download.itemID,
                updatedAtMilliseconds: download.updatedAtMilliseconds,
                width: 240,
                height: 240
            )
            let item = CPListItem(
                text: download.title,
                detailText:
                    download.author.isEmpty
                    ? "Downloaded" : download.author,
                image: initialArtwork(
                    accountID: download.accountID,
                    url: coverURL
                )
            )
            item.isPlaying =
                playback.itemID == download.itemID
                && playback.accountID == download.accountID
            item.handler = { @Sendable [weak self] _, completion in
                let completed = CarPlaySelectionCompletion(completion)
                Task { @MainActor [weak self] in
                    await self?.perform(
                        .playDownload(download.downloadID)
                    )
                    completed()
                }
            }
            loadArtwork(
                for: item,
                accountID: download.accountID,
                url: coverURL
            )
            return item
        }

        private func failureSection(
            _ failure: AppFailure,
            retry: CarPlayAction?,
            maximumItems: Int = CPListTemplate.maximumItemCount
        ) -> CPListSection {
            var items: [CPListItem] = []
            let message = CPListItem(
                text: "Unavailable",
                detailText: failure.message
            )
            message.isEnabled = false
            items.append(message)
            if let retry {
                let retryItem = CPListItem(
                    text: "Try Again",
                    detailText: nil
                )
                retryItem.handler = { @Sendable [weak self] _, completion in
                    let completed = CarPlaySelectionCompletion(completion)
                    Task { @MainActor [weak self] in
                        await self?.perform(retry)
                        completed()
                    }
                }
                items.append(retryItem)
            }
            return CPListSection(
                items: Array(items.suffix(max(0, maximumItems))),
                header: nil,
                sectionIndexTitle: nil
            )
        }

        private func perform(_ action: CarPlayAction) async {
            switch action {
            case .playBook(let book):
                await play(book)
            case .playDownload(let downloadID):
                guard
                    let record = model.downloads.records.first(where: {
                        $0.manifest.downloadID == downloadID
                    }),
                    model.downloads.isFullBookAvailable(record)
                else {
                    showFailure(.mediaUnavailable)
                    return
                }
                await play(record)
            case .openLibraryFolder(let folder, let depth):
                guard depth <= 3, !folder.books.isEmpty else { return }
                let template = CPListTemplate(title: folder.title, sections: [])
                updateBrowserTemplate(
                    template, books: folder.books, depth: depth,
                    presentation: makeTemplatePresentation())
                folderTemplates.removeAll { $0.depth >= depth }
                folderTemplates.append(
                    FolderPresentation(
                        template: template, folder: folder, depth: depth))
                presenter?.push(template)
            case .retryHome:
                guard let library = model.selectedLibrary else {
                    return
                }
                await model.selectLibrary(library)
            case .retryLibraryDiscovery:
                await model.loadLibraries()
            case .retryLibrary:
                let failure: AppFailure?
                if case .failed(let initialFailure) = libraryPage {
                    failure = initialFailure
                } else {
                    failure = libraryFailure
                }
                guard failure?.allowsRetry == true else { return }
                if failure?.cause == .libraryCatalogChanged {
                    nextLibraryPage = 0
                    librarySnapshot = nil
                    catalogGeneration &+= 1
                    folderTemplates.removeAll()
                    rootContext = nil
                }
                await loadLibraryPage(
                    connection: presentationGeneration,
                    context: model.libraryPageGeneration)
            }
        }

        private func play(_ book: LibraryBookSummary) async {
            guard let account = model.account else {
                showFailure(
                    AppFailure(.openPlayback, .authenticationRequired)
                )
                return
            }
            let connection = presentationGeneration
            let libraryID = model.selectedLibrary?.id
            let outcome = await model.startPlayback(
                book: book,
                account: account,
                cancellationPolicy: .cancelPlayback
            )
            guard !Task.isCancelled, presenter != nil,
                presentationGeneration == connection,
                model.account?.id == account.id,
                model.selectedLibrary?.id == libraryID
            else { return }
            switch outcome {
            case .started:
                presentNowPlayingIfReady(
                    itemID: book.id,
                    accountID: account.id
                )
            case .failed(let failure):
                showFailure(failure)
            case .superseded:
                break
            }
        }

        private func play(_ record: DownloadedBookRecord) async {
            guard let account = model.account else {
                showFailure(
                    AppFailure(.openPlayback, .accountUnavailable)
                )
                return
            }
            let outcome = await model.startPlayback(
                download: record,
                account: account
            )
            switch outcome {
            case .started:
                presentNowPlayingIfReady(
                    itemID: record.detail.id,
                    accountID: record.manifest.accountID
                )
            case .failed(let failure):
                showFailure(failure)
            case .superseded:
                break
            }
        }

        private func presentNowPlayingIfReady(
            itemID: LibraryItemID,
            accountID: AccountID
        ) {
            guard model.playback.itemID == itemID,
                model.playback.accountID == accountID
            else {
                if case .failed(let failure) = model.playback.state {
                    showFailure(failure)
                } else {
                    showFailure(.mediaUnavailable)
                }
                return
            }
            switch model.playback.state {
            case .ready, .buffering, .playing, .paused:
                presenter?.push(CPNowPlayingTemplate.shared)
            case .idle, .preparing, .ended:
                showFailure(.mediaUnavailable)
            case .failed(let failure):
                showFailure(failure)
            }
        }

        private func showFailure(_ failure: AppFailure) {
            let ok = CPAlertAction(
                title: "OK",
                style: .cancel
            ) { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.presenter?.dismiss()
                }
            }
            presenter?.present(
                CPAlertTemplate(
                    titleVariants: [failure.message],
                    actions: [ok]
                )
            )
        }

        private func configureNowPlayingTemplate() {
            let rateButton = CPNowPlayingPlaybackRateButton(handler: nil)
            let playbackAvailable = model.playback.hasActiveBook
            rateButton.isEnabled = playbackAvailable
            guard let decreaseImage = UIImage(systemName: "minus"),
                let increaseImage = UIImage(systemName: "plus"),
                let minimumRate = PlaybackPreferencesStore.featuredRates.first,
                let maximumRate = PlaybackPreferencesStore.featuredRates.last
            else {
                CPNowPlayingTemplate.shared.updateNowPlayingButtons([
                    rateButton
                ])
                return
            }
            let decreaseButton = CPNowPlayingImageButton(
                image: decreaseImage
            ) { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    _ = self?.model.playback
                        .stepFeaturedPlaybackRate(.decrease)
                }
            }
            let increaseButton = CPNowPlayingImageButton(
                image: increaseImage
            ) { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    _ = self?.model.playback
                        .stepFeaturedPlaybackRate(.increase)
                }
            }
            let rate = model.playback.rate
            decreaseButton.isEnabled =
                playbackAvailable
                && rate > minimumRate + 0.001
            increaseButton.isEnabled =
                playbackAvailable
                && rate < maximumRate - 0.001
            CPNowPlayingTemplate.shared.updateNowPlayingButtons([
                decreaseButton,
                rateButton,
                increaseButton,
            ])
        }

        private func observeModel() {
            guard presenter != nil else {
                return
            }
            let generation = presentationGeneration
            withObservationTracking {
                _ = model.phase
                _ = model.account?.id
                _ = model.selectedLibrary?.id
                _ = model.libraries
                _ = model.homeShelves
                _ = model.books
                _ = model.libraryPaginationState
                _ = model.libraryPageGeneration
                _ = model.librarySort
                _ = model.showsLibraryCategories
                _ = model.downloads.records
                _ = model.playback.itemID
                _ = model.playback.accountID
                _ = model.playback.state
                _ = model.playback.rate
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    #if DEBUG
                        observationCallbackCountForTesting += 1
                    #endif
                    guard presenter != nil,
                        generation == presentationGeneration
                    else {
                        return
                    }
                    #if DEBUG
                        observationRefreshCountForTesting += 1
                    #endif
                    refreshTemplates()
                    configureNowPlayingTemplate()
                    observeModel()
                }
            }
        }

        private func limit(
            sections: [CPListSection]
        ) -> [CPListSection] {
            var remainingItems = CPListTemplate.maximumItemCount
            var result: [CPListSection] = []
            for section in sections.prefix(
                CPListTemplate.maximumSectionCount
            ) {
                guard remainingItems > 0 else {
                    break
                }
                let items = Array(section.items.prefix(remainingItems))
                guard !items.isEmpty else {
                    continue
                }
                result.append(
                    CPListSection(
                        items: items,
                        header: section.header,
                        sectionIndexTitle: nil
                    )
                )
                remainingItems -= items.count
            }
            return result
        }

        private func loadArtwork(
            for item: CPListItem,
            accountID: AccountID?,
            url: URL?
        ) {
            guard let url else {
                return
            }
            let cacheKey = artworkCacheKey(
                accountID: accountID,
                url: url
            )
            if let image = artworkCache.object(forKey: cacheKey) {
                item.setImage(image)
                return
            }
            let generation = presentationGeneration
            let task = Task { @MainActor [weak self, weak item] in
                guard let self,
                    let item,
                    let image = await coverLoader.image(
                        for: url,
                        accountID: accountID
                    ),
                    !Task.isCancelled,
                    generation == presentationGeneration,
                    presenter != nil
                else {
                    return
                }
                artworkCache.setObject(image, forKey: cacheKey)
                item.setImage(image)
            }
            artworkTasks.append(task)
        }

        private func initialArtwork(
            accountID: AccountID?,
            url: URL?
        ) -> UIImage? {
            guard let url else {
                return UIImage(systemName: "book.closed.fill")
            }
            let cacheKey = artworkCacheKey(
                accountID: accountID,
                url: url
            )
            return artworkCache.object(forKey: cacheKey)
                ?? UIImage(systemName: "book.closed.fill")
        }

        private func artworkCacheKey(
            accountID: AccountID?,
            url: URL
        ) -> NSString {
            let account = accountID?.rawValue ?? "anonymous"
            return "\(account)\u{0}\(url.absoluteString)" as NSString
        }
    }

    @MainActor
    final class CarPlaySceneDelegate:
        UIResponder, CPTemplateApplicationSceneDelegate
    {
        func sceneDidBecomeActive(_ scene: UIScene) {
            BleatAppDelegate.current?.carPlayCoordinator.refreshTemplates()
        }

        func templateApplicationScene(
            _ templateApplicationScene: CPTemplateApplicationScene,
            didConnect interfaceController: CPInterfaceController
        ) {
            let presenter = CarPlayInterfacePresenter(
                interfaceController: interfaceController
            )
            guard let appDelegate = BleatAppDelegate.current else {
                let template = CPListTemplate(
                    title: "Bleat",
                    sections: []
                )
                template.emptyViewTitleVariants = ["Bleat unavailable"]
                presenter.setRoot(template)
                return
            }
            appDelegate.carPlayCoordinator.connect(presenter)
        }

        func templateApplicationScene(
            _ templateApplicationScene: CPTemplateApplicationScene,
            didDisconnectInterfaceController interfaceController:
                CPInterfaceController
        ) {
            guard let appDelegate = BleatAppDelegate.current else {
                return
            }
            appDelegate.carPlayCoordinator.disconnect()
        }
    }
#else
    import Foundation

    @MainActor
    final class CarPlayCoordinator {
        init(
            model: AppModel,
            coverLoader: BookCoverImageLoader = .shared
        ) {}
    }
#endif
