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
        case selectLibrary(LibrarySummary)
        case loadMore
        case retryHome
        case retryLibrary
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
    final class CarPlayCoordinator: NSObject {
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
            let homeShelves: ResourceState<[LibraryBookShelf]>
            let books: ResourceState<LibraryItemsPage>
            let libraryPaginationState: LibraryPaginationState
            let downloads: [DownloadPresentation]
            let playback: PlaybackPresentation
        }

        private enum RootContext: Equatable {
            case signedIn(AccountID)
            case signedOut
            case unavailable
        }

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

        init(
            model: AppModel,
            coverLoader: BookCoverImageLoader = .shared
        ) {
            self.model = model
            self.coverLoader = coverLoader
            super.init()
            artworkCache.countLimit = 256
        }

        func connect(_ presenter: any CarPlayPresenting) {
            disconnect()
            self.presenter = presenter
            presentationGeneration &+= 1
            configureNowPlayingTemplate()
            refreshTemplates()
            observeModel()
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                await model.start()
                refreshTemplates()
            }
        }

        func disconnect() {
            presentationGeneration &+= 1
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
            if homeTemplate == nil {
                homeTemplate = makeTabTemplate(
                    title: "Home",
                    systemImage: "house"
                )
                libraryTemplate = makeTabTemplate(
                    title: "Library",
                    systemImage: "books.vertical"
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
            configureLibraryHeaderButtons(libraryTemplate)
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
            systemImage: String
        ) -> CPListTemplate {
            let template = CPListTemplate(title: title, sections: [])
            template.tabTitle = title
            template.tabImage = UIImage(systemName: systemImage)
            return template
        }

        private func configureLibraryHeaderButtons(
            _ library: CPListTemplate
        ) {
            guard let librariesImage = UIImage(systemName: "books.vertical")
            else {
                library.headerGridButtons = nil
                return
            }
            let librariesButton = CPGridButton(
                titleVariants: ["Libraries"],
                image: librariesImage
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.showLibraryPicker()
                }
            }
            library.headerGridButtons = [librariesButton]
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
                template.updateSections([
                    failureSection(
                        failure,
                        retry:
                            failure.allowsRetry ? .retryLibrary : nil
                    )
                ])
            case .loaded(let page):
                template.showsSpinnerWhileEmpty = false
                template.emptyViewTitleVariants = []
                template.emptyViewSubtitleVariants = []
                let hasTrailingAction =
                    page.hasNextPage
                    || presentation.libraryPaginationState != .idle
                let maximum = max(
                    CPListTemplate.maximumItemCount
                        - (hasTrailingAction ? 1 : 0),
                    1
                )
                var items = page.items.prefix(maximum).map {
                    makeBookItem(
                        book: $0,
                        account: presentation.account,
                        playback: presentation.playback
                    )
                }
                if case .failed(let failure) =
                    presentation.libraryPaginationState
                {
                    let retry = CPListItem(
                        text: "Load More Failed",
                        detailText: failure.message
                    )
                    retry.handler = { [weak self] _, completion in
                        Task { @MainActor [weak self] in
                            await self?.perform(.loadMore)
                            completion()
                        }
                    }
                    items.append(retry)
                } else if page.hasNextPage {
                    let more = CPListItem(
                        text:
                            presentation.libraryPaginationState == .loading
                            ? "Loading More…" : "Load More",
                        detailText: nil
                    )
                    more.isEnabled =
                        presentation.libraryPaginationState != .loading
                    more.handler = { [weak self] _, completion in
                        Task { @MainActor [weak self] in
                            await self?.perform(.loadMore)
                            completion()
                        }
                    }
                    items.append(more)
                }
                template.updateSections([
                    CPListSection(
                        items: Array(items),
                        header: nil,
                        sectionIndexTitle: nil
                    )
                ])
            }
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
        ) -> CarPlayContentState<LibraryItemsPage> {
            switch presentation.books {
            case .idle, .loading:
                return .loading
            case .loaded(let page):
                return page.items.isEmpty ? .empty : .loaded(page)
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
            let account = model.account.map {
                AccountPresentation(id: $0.id, server: $0.server)
            }
            return TemplatePresentation(
                phase: model.phase,
                account: account,
                selectedLibraryID: model.selectedLibrary?.id,
                homeShelves: model.homeShelves,
                books: model.books,
                libraryPaginationState: model.libraryPaginationState,
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
            item.handler = { [weak self] _, completion in
                Task { @MainActor [weak self] in
                    await self?.perform(.playBook(book))
                    completion()
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
            item.handler = { [weak self] _, completion in
                Task { @MainActor [weak self] in
                    await self?.perform(
                        .playDownload(download.downloadID)
                    )
                    completion()
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
            retry: CarPlayAction?
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
                retryItem.handler = { [weak self] _, completion in
                    Task { @MainActor [weak self] in
                        await self?.perform(retry)
                        completion()
                    }
                }
                items.append(retryItem)
            }
            return CPListSection(
                items: items,
                header: nil,
                sectionIndexTitle: nil
            )
        }

        private func showLibraryPicker() {
            guard case .loaded(let libraries) = model.libraries else {
                return
            }
            let items = libraries.map { library in
                let selected = model.selectedLibrary?.id == library.id
                let item = CPListItem(
                    text: library.name,
                    detailText: selected ? "Selected" : nil
                )
                item.handler = { [weak self] _, completion in
                    Task { @MainActor [weak self] in
                        await self?.perform(.selectLibrary(library))
                        completion()
                    }
                }
                return item
            }
            let template = CPListTemplate(
                title: "Libraries",
                sections: [
                    CPListSection(
                        items: items,
                        header: nil,
                        sectionIndexTitle: nil
                    )
                ]
            )
            presenter?.push(template)
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
            case .selectLibrary(let library):
                await model.selectLibrary(library)
                presenter?.pop()
            case .loadMore:
                await model.loadNextBooksPage()
            case .retryHome:
                guard let library = model.selectedLibrary else {
                    return
                }
                await model.selectLibrary(library)
            case .retryLibrary:
                await model.reloadBooks()
            }
        }

        private func play(_ book: LibraryBookSummary) async {
            guard let account = model.account else {
                showFailure(
                    AppFailure(.openPlayback, .authenticationRequired)
                )
                return
            }
            let outcome = await model.startPlayback(
                book: book,
                account: account
            )
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
            ) { [weak self] _ in
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
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    _ = self?.model.playback
                        .stepFeaturedPlaybackRate(.decrease)
                }
            }
            let increaseButton = CPNowPlayingImageButton(
                image: increaseImage
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    _ = self?.model.playback
                        .stepFeaturedPlaybackRate(.increase)
                }
            }
            let rate = model.playback.rate
            decreaseButton.isEnabled = playbackAvailable
                && rate > minimumRate + 0.001
            increaseButton.isEnabled = playbackAvailable
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
            withObservationTracking {
                _ = model.phase
                _ = model.account?.id
                _ = model.selectedLibrary?.id
                _ = model.libraries
                _ = model.homeShelves
                _ = model.books
                _ = model.libraryPaginationState
                _ = model.downloads.records
                _ = model.playback.itemID
                _ = model.playback.accountID
                _ = model.playback.state
                _ = model.playback.rate
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, presenter != nil else {
                        return
                    }
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
