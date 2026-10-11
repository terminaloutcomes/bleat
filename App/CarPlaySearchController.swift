#if canImport(CarPlay) && !os(macOS)
    import BleatCore
    import CarPlay
    import Foundation

    /// Objective-C completions have no executor annotation. Ownership stays on
    /// the main actor, where each pending callback is removed before invocation.
    private struct CarPlaySearchCompletion: @unchecked Sendable {
        let callback: ([CPListItem]) -> Void
    }

    private struct CarPlaySearchSelectionCompletion: @unchecked Sendable {
        let callback: () -> Void
    }

    @MainActor
    final class CarPlaySearchController: NSObject, CPSearchTemplateDelegate {
        enum Action {
            case book(LibraryBookSummary)
            case author(LibrarySearchAuthorMatch)
            case retry
            case retryAuthor(LibrarySearchAuthorMatch)
        }

        let template = CPSearchTemplate()
        private let model: AppModel
        private let account: ServerAccount
        private let libraryID: LibraryID
        private let coordinator: LibrarySearchCoordinator
        private let isCurrent: @MainActor () -> Bool
        private let push: @MainActor (CPTemplate) -> Void
        private let play: @MainActor (LibraryBookSummary) async -> Void
        private let maximumItems: @MainActor () -> Int
        private var task: Task<Void, Never>?
        private var generation: UInt64 = 0
        private var pending: CarPlaySearchCompletion?
        private var selectionTasks: [UUID: Task<Void, Never>] = [:]
        private var selectionCompletions:
            [UUID: CarPlaySearchSelectionCompletion] = [:]
        private var actions: [ObjectIdentifier: Action] = [:]
        private var query = ""
        private var items: [CPListItem] = []
        private var resultsTemplate: CPListTemplate?
        private var authorTemplate: CPListTemplate?
        private var searchResult: LibraryRepositoryResult<LibrarySearchResults>?
        private var keyboardAvailable = true
        private var active = true
        private var renderedCapacity: Int?
        private var authorResult: LibraryRepositoryResult<LibraryItemsPage>?

        init(
            model: AppModel, account: ServerAccount, libraryID: LibraryID,
            coordinator: LibrarySearchCoordinator = LibrarySearchCoordinator(),
            isCurrent: @escaping @MainActor () -> Bool,
            maximumItems: @escaping @MainActor () -> Int,
            push: @escaping @MainActor (CPTemplate) -> Void,
            play: @escaping @MainActor (LibraryBookSummary) async -> Void
        ) {
            self.model = model
            self.account = account
            self.libraryID = libraryID
            self.coordinator = coordinator
            self.isCurrent = isCurrent
            self.maximumItems = maximumItems
            self.push = push
            self.play = play
            super.init()
            template.delegate = self
        }

        func invalidate() {
            active = false
            cancel()
            actions = [:]
            publish([])
            authorTemplate?.updateSections([])
            authorTemplate?.showsSpinnerWhileEmpty = false
        }

        func templateRemoved(_ identity: ObjectIdentifier) {
            if ObjectIdentifier(template) == identity {
                invalidate()
            } else if let resultsTemplate,
                ObjectIdentifier(resultsTemplate) == identity
            {
                self.resultsTemplate = nil
            } else if let authorTemplate,
                ObjectIdentifier(authorTemplate) == identity
            {
                self.authorTemplate = nil
            }
        }

        func updateLimits(keyboardAvailable: Bool) {
            guard self.keyboardAvailable != keyboardAvailable else {
                if renderedCapacity != maximumItems() {
                    if let searchResult { render(searchResult) }
                    if let authorResult, let authorTemplate {
                        renderAuthor(authorResult, into: authorTemplate)
                    }
                }
                return
            }
            self.keyboardAvailable = keyboardAvailable
            if !keyboardAvailable {
                cancel()
                actions = [:]
                searchResult = nil
                authorResult = nil
                authorTemplate?.updateSections([])
                authorTemplate?.showsSpinnerWhileEmpty = false
                publish([
                    message(
                        "Keyboard unavailable", "Browse Library or Downloads.")
                ])
            }
        }

        private var current: Bool { active && isCurrent() }

        private func cancel() {
            generation &+= 1
            task?.cancel()
            task = nil
            let completion = pending
            pending = nil
            completion?.callback([])
            let selections = selectionCompletions.values
            selectionCompletions = [:]
            for task in selectionTasks.values { task.cancel() }
            selectionTasks = [:]
            for completion in selections { completion.callback() }
        }

        nonisolated func searchTemplate(
            _ searchTemplate: CPSearchTemplate,
            updatedSearchText searchText: String,
            completionHandler: @escaping ([CPListItem]) -> Void
        ) {
            let identity = ObjectIdentifier(searchTemplate)
            let completion = CarPlaySearchCompletion(
                callback: completionHandler)
            Task { @MainActor [weak self] in
                guard let self, ObjectIdentifier(self.template) == identity
                else {
                    completion.callback([])
                    return
                }
                self.search(searchText, completion: completion)
            }
        }

        private func search(
            _ text: String, completion: CarPlaySearchCompletion? = nil
        ) {
            cancel()
            actions = [:]
            authorTemplate?.updateSections([])
            authorTemplate?.showsSpinnerWhileEmpty = false
            authorResult = nil
            searchResult = nil
            query = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard current, keyboardAvailable else {
                completion?.callback([])
                return
            }
            guard !query.isEmpty else {
                publish([])
                completion?.callback([])
                return
            }
            let request: LibrarySearchRequest
            do { request = try LibrarySearchRequest(query: query) } catch {
                let failure = AppFailure(
                    operation: .search, serviceError: .searchRequest(error))
                publish([message(failure.title, failure.message)])
                completion?.callback(items)
                return
            }
            pending = completion
            publish([message("Searching…")])
            let revision = generation
            task = Task {
                @MainActor [weak self, model, account, libraryID, coordinator]
                in
                do throws(LibrarySearchCoordinatorError) {
                    let result = try await coordinator.search(
                        context: LibrarySearchContext(
                            accountID: account.id, libraryID: libraryID),
                        request: request,
                        operation: {
                            (_, request) async throws(LibraryRepositoryError) in
                            try await model.carPlaySearch(
                                account: account, libraryID: libraryID,
                                request: request)
                        })
                    guard let self, self.current, self.generation == revision
                    else { return }
                    self.searchResult = result
                    self.render(result)
                    self.finish()
                } catch {
                    guard let self, self.current, self.generation == revision
                    else { return }
                    switch error {
                    case .cancelled, .superseded:
                        self.publish([])
                    case .repository(let cause):
                        let failure = AppFailure(
                            operation: .search,
                            serviceError: .libraryRepository(cause))
                        let item = self.message(failure.title, failure.message)
                        if failure.allowsRetry {
                            self.register(item, action: .retry)
                            item.isEnabled = true
                        }
                        self.publish([item])
                    }
                    self.finish()
                }
            }
        }

        private func finish() {
            let completion = pending
            pending = nil
            task = nil
            completion?.callback(items)
        }

        private func render(
            _ result: LibraryRepositoryResult<LibrarySearchResults>
        ) {
            let capacity = max(0, maximumItems())
            renderedCapacity = maximumItems()
            actions = [:]
            let total = result.value.books.count + result.value.authors.count
            let capped =
                result.value.books.count >= 50
                || result.value.authors.count >= 50
                || result.value.series.count >= 50
                || total > max(0, capacity - (result.source == .cache ? 1 : 0))
            var rows: [CPListItem] = []
            if result.source == .cache || capped {
                rows.append(
                    message(
                        result.source == .cache
                            ? "Cached query results" : "Limited results",
                        capped
                            ? "Use a more specific title or author."
                            : "Saved matches only; not an offline library index."
                    ))
            }
            // Interleave title and author matches so either destination remains
            // reachable when the keyboard list is short.
            for index
                in 0..<max(result.value.books.count, result.value.authors.count)
            {
                if rows.count < capacity, index < result.value.books.count {
                    let book = result.value.books[index]
                    let item = CPListItem(
                        text: book.title, detailText: book.authorName)
                    register(item, action: .book(book))
                    rows.append(item)
                }
                if rows.count < capacity, index < result.value.authors.count {
                    let author = result.value.authors[index]
                    let item = CPListItem(
                        text: author.name, detailText: "Author — Browse books")
                    register(item, action: .author(author))
                    rows.append(item)
                }
                if rows.count == capacity { break }
            }
            if total == 0 {
                rows.append(
                    message(
                        result.source == .cache
                            ? "No saved matches" : "No title or author matches")
                )
            }
            publish(Array(rows.prefix(capacity)))
        }

        private func message(_ title: String, _ detail: String? = nil)
            -> CPListItem
        {
            let item = CPListItem(text: title, detailText: detail)
            item.isEnabled = false
            return item
        }

        private func publish(_ rows: [CPListItem]) {
            items = Array(rows.prefix(max(0, maximumItems())))
            resultsTemplate?.updateSections([CPListSection(items: items)])
        }

        private func register(_ item: CPListItem, action: Action) {
            actions[ObjectIdentifier(item)] = action
            let revision = generation
            item.handler = { @Sendable [weak self] _, completion in
                let completed = CarPlaySearchSelectionCompletion(
                    callback: completion)
                Task { @MainActor [weak self] in
                    guard let self else {
                        completed.callback()
                        return
                    }
                    self.startSelection(
                        action, revision: revision, completion: completed)
                }
            }
        }

        nonisolated func searchTemplate(
            _ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem,
            completionHandler: @escaping () -> Void
        ) {
            let identity = ObjectIdentifier(searchTemplate)
            let itemID = ObjectIdentifier(item)
            let completed = CarPlaySearchSelectionCompletion(
                callback: completionHandler)
            Task { @MainActor [weak self] in
                guard let self, self.current,
                    ObjectIdentifier(self.template) == identity,
                    let action = self.actions[itemID]
                else {
                    completed.callback()
                    return
                }
                self.startSelection(
                    action, revision: self.generation, completion: completed)
            }
        }

        nonisolated func searchTemplateSearchButtonPressed(
            _ searchTemplate: CPSearchTemplate
        ) {
            let identity = ObjectIdentifier(searchTemplate)
            Task { @MainActor [weak self] in
                guard let self, self.current,
                    ObjectIdentifier(self.template) == identity
                else { return }
                self.showResults()
            }
        }

        private func showResults() {
            guard resultsTemplate == nil else { return }
            let list = CPListTemplate(
                title: "Search results", sections: [CPListSection(items: items)]
            )
            resultsTemplate = list
            push(list)
        }

        private func startSelection(
            _ action: Action, revision: UInt64,
            completion: CarPlaySearchSelectionCompletion
        ) {
            guard current, generation == revision else {
                completion.callback()
                return
            }
            let id = UUID()
            selectionCompletions[id] = completion
            selectionTasks[id] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.selectionTasks[id] = nil
                    let completed = self.selectionCompletions.removeValue(
                        forKey: id)
                    completed?.callback()
                }
                await self.perform(action, revision: revision)
            }
        }

        private func perform(_ action: Action, revision: UInt64) async {
            guard current, generation == revision else { return }
            switch action {
            case .book(let book):
                guard book.libraryID == libraryID else { return }
                await play(book)
            case .retry:
                search(query)
                if resultsTemplate == nil { showResults() }
            case .retryAuthor(let author):
                guard let authorTemplate else { return }
                await loadAuthor(
                    author, into: authorTemplate, revision: revision)
            case .author(let author):
                guard authorTemplate == nil else { return }
                let list = CPListTemplate(title: author.name, sections: [])
                list.showsSpinnerWhileEmpty = true
                authorTemplate = list
                push(list)
                await loadAuthor(author, into: list, revision: revision)
            }
        }

        private func renderAuthor(
            _ result: LibraryRepositoryResult<LibraryItemsPage>,
            into list: CPListTemplate
        ) {
            let capacity = max(0, maximumItems())
            var rows: [CPListItem] = []
            if result.source == .cache || result.value.hasNextPage
                || result.value.items.count > capacity
            {
                rows.append(
                    message(
                        result.source == .cache
                            ? "Cached author books"
                            : "Limited author books",
                        "Browse Library for more books."))
            }
            for book in result.value.items.prefix(
                max(0, capacity - rows.count))
            {
                let item = CPListItem(
                    text: book.title, detailText: book.authorName)
                register(item, action: .book(book))
                rows.append(item)
            }
            list.showsSpinnerWhileEmpty = false
            list.emptyViewTitleVariants = ["No author books"]
            list.updateSections(
                rows.isEmpty ? [] : [CPListSection(items: rows)])
        }

        private func loadAuthor(
            _ author: LibrarySearchAuthorMatch, into list: CPListTemplate,
            revision: UInt64
        ) async {
            do {
                let result = try await model.carPlayAuthorPage(
                    account: account, libraryID: libraryID, authorID: author.id)
                guard current, generation == revision, authorTemplate === list
                else { return }
                authorResult = result
                renderAuthor(result, into: list)
            } catch {
                guard current, generation == revision, authorTemplate === list
                else { return }
                let failure = AppFailure(
                    operation: .loadLibraryPage, serviceError: error)
                let row = message(failure.title, failure.message)
                if failure.allowsRetry {
                    row.isEnabled = true
                    register(row, action: .retryAuthor(author))
                }
                list.showsSpinnerWhileEmpty = false
                list.updateSections([
                    CPListSection(
                        items: Array([row].prefix(max(0, maximumItems()))))
                ])
            }
        }
    }
#endif
