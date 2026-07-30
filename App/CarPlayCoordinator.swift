#if canImport(CarPlay) && !targetEnvironment(macCatalyst)
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
    final class CarPlayCoordinator: NSObject, CPSearchTemplateDelegate {
        private enum RootContext: Equatable {
            case signedIn(AccountID)
            case signedOut
            case unavailable
        }

        private let model: AppModel
        private let session: URLSession
        private var presenter: (any CarPlayPresenting)?
        private var rootContext: RootContext?
        private var homeTemplate: CPListTemplate?
        private var libraryTemplate: CPListTemplate?
        private var downloadsTemplate: CPListTemplate?
        private var tabTemplate: CPTabBarTemplate?
        private var searchTemplate: CPSearchTemplate?
        private var searchResultsByItem:
            [ObjectIdentifier: LibraryBookSummary] = [:]
        private var artworkCache: [URL: UIImage] = [:]
        private var artworkTasks: [Task<Void, Never>] = []
        private var presentationGeneration: UInt64 = 0
        private var selectionGeneration: UInt64 = 0
        private var searchGeneration: UInt64 = 0
        private var searchTask: Task<Void, Never>?

        init(
            model: AppModel,
            session: URLSession = .shared
        ) {
            self.model = model
            self.session = session
            super.init()
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
            selectionGeneration &+= 1
            searchGeneration &+= 1
            searchTask?.cancel()
            searchTask = nil
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
            searchTemplate = nil
            searchResultsByItem = [:]
        }

        func refreshTemplates() {
            guard presenter != nil else {
                return
            }
            switch model.phase {
            case .launching:
                showUnavailableRoot(
                    title: "Loading Bleat",
                    detail: nil,
                    activity: true,
                    context: .unavailable
                )
            case .signedIn:
                guard let account = model.account else {
                    showUnavailableRoot(
                        title: "Account unavailable",
                        detail: "Open Bleat on iPhone.",
                        activity: false,
                        context: .unavailable
                    )
                    return
                }
                showSignedInRoot(accountID: account.id)
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

        func searchTemplate(
            _ searchTemplate: CPSearchTemplate,
            updatedSearchText searchText: String,
            completionHandler:
                @escaping ([CPListItem]) -> Void
        ) {
            searchGeneration &+= 1
            let generation = searchGeneration
            searchTask?.cancel()
            searchResultsByItem = [:]
            let normalized = searchText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !normalized.isEmpty else {
                completionHandler([])
                return
            }
            let accountID = model.account?.id
            let libraryID = model.selectedLibrary?.id
            searchTask = Task { @MainActor [weak self] in
                guard let self else {
                    completionHandler([])
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled,
                    generation == searchGeneration
                else {
                    completionHandler([])
                    return
                }
                await model.search(query: normalized)
                guard !Task.isCancelled,
                    generation == searchGeneration,
                    model.account?.id == accountID,
                    model.selectedLibrary?.id == libraryID,
                    case .loaded(let books) = model.searchResults
                else {
                    completionHandler([])
                    return
                }
                let items = books.map {
                    makeSearchResultItem(book: $0)
                }
                completionHandler(items)
            }
        }

        func searchTemplate(
            _ searchTemplate: CPSearchTemplate,
            selectedResult item: CPListItem,
            completionHandler: @escaping () -> Void
        ) {
            guard
                let book =
                    searchResultsByItem[ObjectIdentifier(item)]
            else {
                completionHandler()
                return
            }
            Task { @MainActor [weak self] in
                await self?.perform(.playBook(book))
                completionHandler()
            }
        }

        private func showSignedInRoot(accountID: AccountID) {
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
            configureNavigationButtons(
                home: homeTemplate,
                library: libraryTemplate
            )
            updateHomeTemplate(homeTemplate)
            updateLibraryTemplate(libraryTemplate)
            updateDownloadsTemplate(
                downloadsTemplate,
                accountID: accountID
            )

            let context = RootContext.signedIn(accountID)
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
            updateDownloadsTemplate(template, accountID: nil)
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

        private func configureNavigationButtons(
            home: CPListTemplate,
            library: CPListTemplate
        ) {
            home.trailingNavigationBarButtons = [makeLibrariesButton()]
            let searchButton = CPBarButton(title: "Search") {
                [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.showSearch()
                }
            }
            library.leadingNavigationBarButtons = [makeLibrariesButton()]
            library.trailingNavigationBarButtons = [searchButton]
        }

        private func makeLibrariesButton() -> CPBarButton {
            CPBarButton(title: "Libraries") { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.showLibraryPicker()
                }
            }
        }

        private func updateHomeTemplate(_ template: CPListTemplate) {
            switch homeState {
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
                            makeBookItem(book: $0)
                        },
                        header: shelf.label,
                        sectionIndexTitle: nil
                    )
                }
                let downloads = availableDownloads(
                    accountID: model.account?.id
                )
                if !downloads.isEmpty {
                    sections.append(
                        CPListSection(
                            items: downloads.map(makeDownloadItem),
                            header: "Downloaded",
                            sectionIndexTitle: nil
                        )
                    )
                }
                template.updateSections(limit(sections: sections))
            }
        }

        private func updateLibraryTemplate(_ template: CPListTemplate) {
            switch libraryState {
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
                    || model.libraryPaginationState != .idle
                let maximum = max(
                    CPListTemplate.maximumItemCount
                        - (hasTrailingAction ? 1 : 0),
                    1
                )
                var items = page.items.prefix(maximum).map {
                    makeBookItem(book: $0)
                }
                if case .failed(let failure) = model.libraryPaginationState {
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
                            model.libraryPaginationState == .loading
                            ? "Loading More…" : "Load More",
                        detailText: nil
                    )
                    more.isEnabled =
                        model.libraryPaginationState != .loading
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
            accountID: AccountID?
        ) {
            let downloads = availableDownloads(accountID: accountID)
            template.showsSpinnerWhileEmpty = false
            if downloads.isEmpty {
                template.updateSections([])
                template.emptyViewTitleVariants = ["No downloads"]
                template.emptyViewSubtitleVariants =
                    model.phase == .signedOut
                    ? ["Open Bleat on iPhone to sign in."]
                    : []
            } else {
                template.emptyViewTitleVariants = []
                template.emptyViewSubtitleVariants = []
                template.updateSections([
                    CPListSection(
                        items: downloads.map(makeDownloadItem),
                        header: nil,
                        sectionIndexTitle: nil
                    )
                ])
            }
        }

        private var homeState: CarPlayContentState<[LibraryBookShelf]> {
            switch model.homeShelves {
            case .idle, .loading:
                let downloads = availableDownloads(
                    accountID: model.account?.id
                )
                return downloads.isEmpty
                    ? .loading
                    : .loaded([])
            case .loaded(let shelves):
                let hasDownloads = !availableDownloads(
                    accountID: model.account?.id
                ).isEmpty
                return shelves.isEmpty && !hasDownloads
                    ? .empty
                    : .loaded(shelves)
            case .failed(let failure):
                let downloads = availableDownloads(
                    accountID: model.account?.id
                )
                return downloads.isEmpty
                    ? .failed(failure)
                    : .loaded([])
            }
        }

        private var libraryState: CarPlayContentState<LibraryItemsPage> {
            switch model.books {
            case .idle, .loading:
                return .loading
            case .loaded(let page):
                return page.items.isEmpty ? .empty : .loaded(page)
            case .failed(let failure):
                return .failed(failure)
            }
        }

        private func availableDownloads(
            accountID: AccountID?
        ) -> [DownloadedBookRecord] {
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
        }

        private func makeBookItem(
            book: LibraryBookSummary
        ) -> CPListItem {
            let item = CPListItem(
                text: book.title,
                detailText: book.authorName,
                image: UIImage(systemName: "book.closed.fill")
            )
            item.isPlaying =
                model.playback.itemID == book.id
                && model.playback.accountID == model.account?.id
            item.handler = { [weak self] _, completion in
                Task { @MainActor [weak self] in
                    await self?.perform(.playBook(book))
                    completion()
                }
            }
            loadArtwork(
                for: item,
                url: BookCoverURL.make(
                    server: model.account?.server,
                    itemID: book.id,
                    updatedAtMilliseconds: book.updatedAtMilliseconds,
                    width: 240,
                    height: 240
                )
            )
            return item
        }

        private func makeDownloadItem(
            _ record: DownloadedBookRecord
        ) -> CPListItem {
            let author = record.detail.authors
                .map(\.name)
                .joined(separator: ", ")
            let item = CPListItem(
                text: record.detail.title,
                detailText: author.isEmpty ? "Downloaded" : author,
                image: UIImage(systemName: "book.closed.fill")
            )
            item.isPlaying =
                model.playback.itemID == record.detail.id
                && model.playback.accountID
                    == record.manifest.accountID
            item.handler = { [weak self] _, completion in
                Task { @MainActor [weak self] in
                    await self?.perform(
                        .playDownload(record.manifest.downloadID)
                    )
                    completion()
                }
            }
            let server = model.accounts.first {
                $0.id == record.manifest.accountID
            }?.server
            loadArtwork(
                for: item,
                url: BookCoverURL.make(
                    server: server,
                    itemID: record.detail.id,
                    updatedAtMilliseconds:
                        record.detail.updatedAtMilliseconds,
                    width: 240,
                    height: 240
                )
            )
            return item
        }

        private func makeSearchResultItem(
            book: LibraryBookSummary
        ) -> CPListItem {
            let item = CPListItem(
                text: book.title,
                detailText: book.authorName,
                image: UIImage(systemName: "book.closed.fill")
            )
            searchResultsByItem[ObjectIdentifier(item)] = book
            loadArtwork(
                for: item,
                url: BookCoverURL.make(
                    server: model.account?.server,
                    itemID: book.id,
                    updatedAtMilliseconds: book.updatedAtMilliseconds,
                    width: 240,
                    height: 240
                )
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

        private func showSearch() {
            let template = CPSearchTemplate()
            template.delegate = self
            searchTemplate = template
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
            selectionGeneration &+= 1
            let generation = selectionGeneration
            await model.loadBookDetail(book)
            guard generation == selectionGeneration,
                model.account?.id == account.id,
                model.selectedBookID == book.id
            else {
                return
            }
            guard case .loaded(let detail) = model.bookDetail else {
                if case .failed(let failure) = model.bookDetail {
                    showFailure(failure)
                }
                return
            }
            let availability = BookActionAvailability(
                user: account.user,
                detail: detail
            )
            guard availability.visibleActions.contains(.play) else {
                showFailure(.playbackDenied)
                return
            }
            if let record = model.downloads.record(
                accountID: account.id,
                itemID: detail.id
            ), model.downloads.isFullBookAvailable(record) {
                await model.playDownloaded(record)
            } else {
                await model.playback.start(
                    detail: detail,
                    account: account
                )
            }
            presentNowPlayingIfReady(
                itemID: detail.id,
                accountID: account.id
            )
        }

        private func play(_ record: DownloadedBookRecord) async {
            selectionGeneration &+= 1
            let generation = selectionGeneration
            await model.playDownloaded(record)
            guard generation == selectionGeneration else {
                return
            }
            presentNowPlayingIfReady(
                itemID: record.detail.id,
                accountID: record.manifest.accountID
            )
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
            let rateButton = CPNowPlayingPlaybackRateButton {
                [weak self] _ in
                Task { @MainActor [weak self] in
                    _ = self?.model.playback
                        .cycleFeaturedPlaybackRate()
                }
            }
            rateButton.isEnabled = model.playback.hasActiveBook
            CPNowPlayingTemplate.shared.updateNowPlayingButtons([
                rateButton
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
                _ = model.searchResults
                _ = model.downloads.records
                _ = model.playback.itemID
                _ = model.playback.accountID
                _ = model.playback.state
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
            url: URL?
        ) {
            guard let url else {
                return
            }
            if let image = artworkCache[url] {
                item.setImage(image)
                return
            }
            let generation = presentationGeneration
            let task = Task { @MainActor [weak self, weak item] in
                guard let self,
                    let item,
                    let image = await artwork(from: url),
                    !Task.isCancelled,
                    generation == presentationGeneration,
                    presenter != nil
                else {
                    return
                }
                artworkCache[url] = image
                item.setImage(image)
            }
            artworkTasks.append(task)
        }

        private func artwork(from url: URL) async -> UIImage? {
            do {
                let (data, response) = try await session.data(from: url)
                guard
                    let response = response as? HTTPURLResponse,
                    (200...299).contains(response.statusCode),
                    data.count <= 5 * 1_024 * 1_024
                else {
                    return nil
                }
                return UIImage(data: data)
            } catch {
                return nil
            }
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
            guard
                let appDelegate =
                    UIApplication.shared.delegate as? BleatAppDelegate
            else {
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
            guard
                let appDelegate =
                    UIApplication.shared.delegate as? BleatAppDelegate
            else {
                return
            }
            appDelegate.carPlayCoordinator.disconnect()
        }
    }
#else
    import Foundation

    @MainActor
    final class CarPlayCoordinator {
        init(model: AppModel, session: URLSession = .shared) {}
    }
#endif
