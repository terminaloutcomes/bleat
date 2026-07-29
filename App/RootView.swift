import BleatCore
import Foundation
import PhotosUI
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .launching:
                ProgressView()
                    .accessibilityIdentifier("app.launching")
            case .signedOut:
                NativeLoginView(model: model)
            case .signedIn:
                SignedInView(model: model)
            case .unavailable(let failure):
                ContentUnavailableView(
                    "Bleat is unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(failure.message)
                )
                .accessibilityIdentifier("app.unavailable")
            }
        }
        .task {
            await model.start()
        }
    }
}

private struct NativeLoginView: View {
    @Bindable var model: AppModel
    var navigationTitle = "Bleat"
    var onSignedIn: () -> Void = {}
    var onCancel: (() -> Void)?
    @State private var serverAddress = ""
    @State private var username = ""
    @State private var password = ""

    private var isSubmitting: Bool {
        model.loginStatus == .submitting
    }

    private var canSubmit: Bool {
        !serverAddress.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
            && !username.isEmpty
            && !password.isEmpty
            && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField(
                        "https://audiobooks.example",
                        text: $serverAddress
                    )
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("login.server")
                }

                Section("Account") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("login.username")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("login.password")
                }

                if case .failed(let failure) = model.loginStatus {
                    Section {
                        Text(failure.message)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("login.error")
                    }
                }

                Section {
                    Button {
                        submit()
                    } label: {
                        if isSubmitting {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Sign In")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("login.submit")
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                if let onCancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                }
            }
        }
    }

    private func submit() {
        let submittedServerAddress = serverAddress
        let submittedUsername = username
        let submittedPassword = password
        password = ""

        Task {
            let signedIn = await model.login(
                serverAddress: submittedServerAddress,
                username: submittedUsername,
                password: submittedPassword
            )
            if signedIn {
                onSignedIn()
            }
        }
    }
}

private struct SignedInView: View {
    @Bindable var model: AppModel
    @State private var showPlayer = false

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                HomeView(model: model)
            }
            Tab("Library", systemImage: "books.vertical") {
                LibraryView(model: model)
            }
            Tab("Search", systemImage: "magnifyingglass") {
                SearchView(model: model)
            }
            Tab("Downloads", systemImage: "arrow.down.circle") {
                DownloadsView(model: model)
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView(model: model)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.playback.hasActiveBook {
                MiniPlayerView(playback: model.playback) {
                    showPlayer = true
                }
            }
        }
        .sheet(isPresented: $showPlayer) {
            PlayerView(playback: model.playback)
        }
        .alert(
            "Allow Cellular Download?",
            isPresented: Binding(
                get: {
                    model.downloads.pendingCellularDownload != nil
                },
                set: { _ in }
            )
        ) {
            Button("Cancel", role: .cancel) {
                model.downloads.cancelCellularDownload()
            }
            Button("Download") {
                Task {
                    await model.downloads.confirmCellularDownload()
                }
            }
        } message: {
            if let pending = model.downloads.pendingCellularDownload {
                Text(
                    "\(pending.detail.title) is \(ByteCountFormatter.string(fromByteCount: pending.expectedBytes, countStyle: .file)). It may use cellular data."
                )
            }
        }
        .accessibilityIdentifier("app.signedIn")
    }
}

private struct HomeView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            HomeContent(model: model)
                .navigationTitle("Home")
                .navigationDestination(for: LibraryBookSummary.self) { book in
                    BookDetailView(model: model, book: book)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Reload", systemImage: "arrow.clockwise") {
                            guard let library = model.selectedLibrary else {
                                return
                            }
                            Task {
                                await model.selectLibrary(library)
                            }
                        }
                        .accessibilityIdentifier("home.reload")
                    }
                }
        }
    }
}

private struct HomeContent: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.homeShelves {
            case .idle, .loading:
                ProgressView()
                    .accessibilityIdentifier("home.loading")
            case .failed(let failure):
                ContentUnavailableView(
                    "Home unavailable",
                    systemImage: "wifi.exclamationmark",
                    description: Text(failure.message)
                )
                .accessibilityIdentifier("home.error")
            case .loaded(let shelves):
                if shelves.isEmpty {
                    ContentUnavailableView(
                        "No personalized shelves",
                        systemImage: "books.vertical"
                    )
                    .accessibilityIdentifier("home.empty")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(shelves, id: \.id) { shelf in
                                shelfContent(shelf)
                            }
                        }
                        .padding(.vertical)
                    }
                    .accessibilityIdentifier("home.shelves")
                }
            }
        }
    }

    private func shelfContent(_ shelf: LibraryBookShelf) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(shelf.label)
                .font(.title2.bold())
                .padding(.horizontal)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(shelf.items, id: \.id.rawValue) { book in
                        NavigationLink(value: book) {
                            VStack(alignment: .leading, spacing: 4) {
                                BookCoverView(
                                    server: model.account?.server,
                                    itemID: book.id,
                                    updatedAtMilliseconds:
                                        book.updatedAtMilliseconds,
                                    width: 360,
                                    height: 360,
                                    cornerRadius: 10
                                )
                                .frame(width: 180, height: 180)
                                Text(book.title)
                                    .font(.headline)
                                    .lineLimit(2)
                                if let author = book.authorName {
                                    Text(author)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(width: 180, alignment: .leading)
                            .padding()
                            .background(
                                .quaternary,
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct LibraryView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                libraryPicker
                libraryControls
                BookListContent(model: model)
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reload", systemImage: "arrow.clockwise") {
                        Task {
                            await model.loadLibraries()
                        }
                    }
                    .accessibilityIdentifier("library.reload")
                }
            }
        }
    }

    @ViewBuilder
    private var libraryControls: some View {
        if model.selectedLibrary != nil {
            HStack {
                Menu {
                    ForEach(
                        [
                            LibraryItemSort.title,
                            .author,
                            .addedAt,
                            .updatedAt,
                            .duration,
                        ],
                        id: \.self
                    ) { sort in
                        Button {
                            Task {
                                await model.setLibrarySort(sort)
                            }
                        } label: {
                            if model.librarySort == sort {
                                Label(
                                    sort.label,
                                    systemImage: "checkmark"
                                )
                            } else {
                                Text(sort.label)
                            }
                        }
                    }
                } label: {
                    Label(
                        model.librarySort.label,
                        systemImage: "arrow.up.arrow.down"
                    )
                }
                .accessibilityIdentifier("library.sort")

                Button {
                    Task {
                        await model.setLibrarySortDescending(
                            !model.librarySortDescending
                        )
                    }
                } label: {
                    Image(
                        systemName: model.librarySortDescending
                            ? "arrow.down" : "arrow.up"
                    )
                }
                .accessibilityLabel(
                    model.librarySortDescending
                        ? "Descending" : "Ascending"
                )
                .accessibilityIdentifier("library.sortDirection")

                Spacer()

                Menu {
                    Button {
                        Task {
                            await model.setLibraryProgressFilter(nil)
                        }
                    } label: {
                        if model.libraryProgressFilter == nil {
                            Label("All Books", systemImage: "checkmark")
                        } else {
                            Text("All Books")
                        }
                    }
                    Divider()
                    ForEach(LibraryProgressFilter.allCases, id: \.self) {
                        filter in
                        Button {
                            Task {
                                await model.setLibraryProgressFilter(
                                    filter
                                )
                            }
                        } label: {
                            if model.libraryProgressFilter == filter {
                                Label(
                                    filter.label,
                                    systemImage: "checkmark"
                                )
                            } else {
                                Text(filter.label)
                            }
                        }
                    }
                } label: {
                    Label(
                        model.libraryProgressFilter?.label ?? "All Books",
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                }
                .accessibilityIdentifier("library.filter")
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var libraryPicker: some View {
        if case .loaded(let libraries) = model.libraries,
            libraries.count > 1
        {
            Picker(
                "Library",
                selection: Binding(
                    get: {
                        model.selectedLibrary?.id.rawValue ?? ""
                    },
                    set: { selectedID in
                        guard
                            let library = libraries.first(where: {
                                $0.id.rawValue == selectedID
                            })
                        else {
                            return
                        }
                        Task {
                            await model.selectLibrary(library)
                        }
                    }
                )
            ) {
                ForEach(libraries, id: \.id.rawValue) { library in
                    Text(library.name)
                        .tag(library.id.rawValue)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal)
            .accessibilityIdentifier("library.picker")
        }
    }
}

extension LibraryItemSort {
    fileprivate var label: String {
        switch self {
        case .title:
            "Title"
        case .author:
            "Author"
        case .addedAt:
            "Recently Added"
        case .updatedAt:
            "Recently Updated"
        case .duration:
            "Duration"
        }
    }
}

extension LibraryProgressFilter {
    fileprivate var label: String {
        switch self {
        case .finished:
            "Finished"
        case .inProgress:
            "In Progress"
        case .notStarted:
            "Not Started"
        case .notFinished:
            "Not Finished"
        }
    }
}

private struct BookListContent: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.libraries {
            case .idle, .loading:
                ProgressView()
                    .accessibilityIdentifier("library.loading")
            case .failed(let failure):
                failureView(failure)
            case .loaded(let libraries):
                if libraries.isEmpty {
                    ContentUnavailableView(
                        "No audiobook libraries",
                        systemImage: "books.vertical"
                    )
                } else {
                    booksContent
                }
            }
        }
        .navigationDestination(for: LibraryBookSummary.self) { book in
            BookDetailView(model: model, book: book)
        }
    }

    @ViewBuilder
    private var booksContent: some View {
        switch model.books {
        case .idle, .loading:
            ProgressView()
                .accessibilityIdentifier("books.loading")
        case .failed(let failure):
            failureView(failure)
        case .loaded(let page):
            if page.items.isEmpty {
                ContentUnavailableView(
                    "No audiobooks",
                    systemImage: "book.closed"
                )
            } else {
                List {
                    ForEach(page.items, id: \.id.rawValue) { book in
                        NavigationLink(value: book) {
                            BookSummaryRow(
                                book: book,
                                server: model.account?.server
                            )
                        }
                    }
                    if page.hasNextPage {
                        switch model.libraryPaginationState {
                        case .idle:
                            Button("Load More") {
                                Task {
                                    await model.loadNextBooksPage()
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("books.loadMore")
                        case .loading:
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .accessibilityIdentifier("books.loadingMore")
                        case .failed(let failure):
                            VStack(alignment: .leading, spacing: 8) {
                                Text(failure.message)
                                    .foregroundStyle(.secondary)
                                Button("Try Again") {
                                    Task {
                                        await model.loadNextBooksPage()
                                    }
                                }
                                .accessibilityIdentifier(
                                    "books.retryLoadMore"
                                )
                            }
                        }
                    }
                }
                .accessibilityIdentifier("books.list")
            }
        }
    }

    private func failureView(_ failure: AppFailure) -> some View {
        ContentUnavailableView(
            "Library unavailable",
            systemImage: "wifi.exclamationmark",
            description: Text(failure.message)
        )
    }
}

private struct SearchView: View {
    @Bindable var model: AppModel
    @State private var query = ""

    private var taskContext: SearchTaskContext {
        SearchTaskContext(
            query: query,
            libraryID: model.selectedLibrary?.id
        )
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Search")
                .navigationDestination(for: LibraryBookSummary.self) { book in
                    BookDetailView(model: model, book: book)
                }
        }
        .searchable(
            text: $query,
            prompt: "Books, authors, or series"
        )
        .task(id: taskContext) {
            await model.search(query: query)
        }
        .accessibilityIdentifier("search.screen")
    }

    @ViewBuilder
    private var content: some View {
        switch model.searchResults {
        case .idle:
            ContentUnavailableView(
                "Search audiobooks",
                systemImage: "magnifyingglass"
            )
        case .loading:
            ProgressView()
                .accessibilityIdentifier("search.loading")
        case .failed(let failure):
            ContentUnavailableView(
                "Search unavailable",
                systemImage: "wifi.exclamationmark",
                description: Text(failure.message)
            )
            .accessibilityIdentifier("search.error")
        case .loaded(let results):
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
                    .accessibilityIdentifier("search.empty")
            } else {
                List(results, id: \.id.rawValue) { book in
                    NavigationLink(value: book) {
                        BookSummaryRow(
                            book: book,
                            server: model.account?.server
                        )
                    }
                }
                .accessibilityIdentifier("search.results")
            }
        }
    }
}

private struct SearchTaskContext: Hashable {
    let query: String
    let libraryID: LibraryID?
}

private struct BookSummaryRow: View {
    let book: LibraryBookSummary
    let server: NormalizedServerURL?

    var body: some View {
        HStack(spacing: 12) {
            BookCoverView(
                server: server,
                itemID: book.id,
                updatedAtMilliseconds: book.updatedAtMilliseconds,
                width: 128,
                height: 128
            )
            .frame(width: 64, height: 64)
            VStack(alignment: .leading) {
                Text(book.title)
                if let author = book.authorName {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct BookDetailView: View {
    @Bindable var model: AppModel
    let book: LibraryBookSummary
    @State private var showMetadataEditor = false
    @State private var selectedCoverItem: PhotosPickerItem?
    @State private var isUploadingCover = false
    @State private var coverError: String?

    var body: some View {
        Group {
            if model.selectedBookID != book.id {
                ProgressView()
                    .accessibilityIdentifier("book.detail.loading")
            } else {
                switch model.bookDetail {
                case .idle, .loading:
                    ProgressView()
                        .accessibilityIdentifier("book.detail.loading")
                case .failed(let failure):
                    ContentUnavailableView(
                        "Audiobook unavailable",
                        systemImage: "wifi.exclamationmark",
                        description: Text(failure.message)
                    )
                    .accessibilityIdentifier("book.detail.error")
                case .loaded(let detail):
                    detailContent(detail)
                }
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: book.id.rawValue) {
            await model.loadBookDetail(book)
        }
        .toolbar {
            if let detail = loadedDetail {
                if canEditMetadata(detail) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") {
                            showMetadataEditor = true
                        }
                        .accessibilityIdentifier("book.detail.edit")
                    }
                }
                if canEditCover(detail) {
                    ToolbarItem(placement: .topBarTrailing) {
                        PhotosPicker(
                            selection: $selectedCoverItem,
                            matching: .images
                        ) {
                            Text("Cover")
                        }
                        .disabled(isUploadingCover)
                        .accessibilityIdentifier("book.detail.cover")
                    }
                }
            }
        }
        .sheet(isPresented: $showMetadataEditor) {
            if let detail = loadedDetail {
                MetadataEditorView(model: model, detail: detail)
            }
        }
        .onChange(of: selectedCoverItem) { _, item in
            guard let item else {
                return
            }
            Task {
                await uploadCover(item)
            }
        }
    }

    private var loadedDetail: LibraryBookDetail? {
        guard model.selectedBookID == book.id,
            case .loaded(let detail) = model.bookDetail
        else {
            return nil
        }
        return detail
    }

    private func canEditMetadata(_ detail: LibraryBookDetail) -> Bool {
        guard let user = model.account?.user else {
            return false
        }
        return BookActionAvailability(
            user: user,
            detail: detail
        ).visibleActions.contains(.editMetadata)
    }

    private func canEditCover(_ detail: LibraryBookDetail) -> Bool {
        guard let user = model.account?.user else {
            return false
        }
        return BookActionAvailability(
            user: user,
            detail: detail
        ).visibleActions.contains(.editCover)
    }

    private func uploadCover(_ item: PhotosPickerItem) async {
        guard let detail = loadedDetail else {
            return
        }
        isUploadingCover = true
        coverError = nil
        defer {
            isUploadingCover = false
            selectedCoverItem = nil
        }
        do {
            guard
                let sourceData = try await item.loadTransferable(
                    type: Data.self
                )
            else {
                throw CoverImageProcessingError.invalidImage
            }
            let jpegData = try await Task.detached {
                try CoverImageProcessor.jpegData(from: sourceData)
            }.value
            guard
                await model.replaceCover(
                    jpegData: jpegData,
                    detail: detail
                )
            else {
                coverError = "Bleat could not upload that cover."
                return
            }
        } catch {
            coverError = "Choose a valid image and try again."
        }
    }

    private func detailContent(_ detail: LibraryBookDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                BookCoverView(
                    server: model.account?.server,
                    itemID: detail.id,
                    updatedAtMilliseconds: detail.updatedAtMilliseconds,
                    width: 600,
                    height: 600,
                    cornerRadius: 14
                )
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 300)
                .frame(maxWidth: .infinity)

                if let coverError {
                    Text(coverError)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("book.detail.coverError")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(detail.title)
                        .font(.title.bold())
                        .accessibilityIdentifier("book.detail.title")
                    if let subtitle = detail.subtitle {
                        Text(subtitle)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    if !detail.authors.isEmpty {
                        Text(detail.authors.map(\.name).joined(separator: ", "))
                            .font(.headline)
                    }
                    if !detail.narrators.isEmpty {
                        Text(
                            "Narrated by "
                                + detail.narrators.joined(separator: ", ")
                        )
                        .foregroundStyle(.secondary)
                    }
                }

                if let progress = detail.progress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress.progress)
                        Text(
                            progress.isFinished
                                ? "Finished"
                                : "\(Int(progress.progress * 100))% complete"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Button(
                    detail.progress?.isFinished == true
                        ? "Mark Unfinished" : "Mark Finished"
                ) {
                    Task {
                        await model.setFinished(
                            detail.progress?.isFinished != true,
                            detail: detail
                        )
                    }
                }
                .disabled(model.bookProgressUpdateState == .saving)
                .accessibilityIdentifier("book.detail.finished")
                if case .failed(let failure) =
                    model.bookProgressUpdateState
                {
                    Text(failure.message)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(
                            "book.detail.progressError"
                        )
                }

                if let description = detail.descriptionPlain,
                    !description.isEmpty
                {
                    Text(description)
                        .accessibilityIdentifier("book.detail.description")
                }

                detailsGrid(detail)

                if !detail.chapters.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Chapters")
                            .font(.headline)
                        ForEach(
                            Array(detail.chapters.enumerated()),
                            id: \.offset
                        ) { _, chapter in
                            Text(chapter.title)
                        }
                    }
                }

                playbackAction(detail)
                downloadAction(detail)
            }
            .padding()
        }
        .accessibilityIdentifier("book.detail")
    }

    @ViewBuilder
    private func detailsGrid(_ detail: LibraryBookDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details")
                .font(.headline)
            LabeledContent("Duration", value: durationText(detail.duration))
            if let publishedYear = detail.publishedYear {
                LabeledContent("Published", value: publishedYear)
            }
            if let publisher = detail.publisher {
                LabeledContent("Publisher", value: publisher)
            }
            if let language = detail.language {
                LabeledContent("Language", value: language)
            }
            if !detail.genres.isEmpty {
                LabeledContent(
                    "Genres",
                    value: detail.genres.joined(separator: ", ")
                )
            }
        }
    }

    @ViewBuilder
    private func playbackAction(_ detail: LibraryBookDetail) -> some View {
        if let user = model.account?.user {
            let availability = BookActionAvailability(
                user: user,
                detail: detail
            )
            switch availability.access {
            case .allowed:
                if let account = model.account,
                    let downloaded = model.downloads.record(
                        accountID: account.id,
                        itemID: detail.id
                    ),
                    downloaded.manifest.state == .complete
                {
                    Button {
                        Task {
                            await model.playDownloaded(downloaded)
                        }
                    } label: {
                        Label(
                            "Play Offline",
                            systemImage: "iphone.and.arrow.forward"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("book.detail.play")
                } else if availability.visibleActions.contains(.play),
                    let account = model.account
                {
                    Button {
                        Task {
                            await model.playback.start(
                                detail: detail,
                                account: account
                            )
                        }
                    } label: {
                        Label(
                            model.playback.itemID == detail.id
                                ? "Play Again"
                                : "Play",
                            systemImage: "play.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.playback.state == .preparing
                            && model.playback.itemID == detail.id
                    )
                    .accessibilityIdentifier("book.detail.play")
                }
            case .inaccessibleLibrary:
                Text("This account cannot access the audiobook's library.")
                    .foregroundStyle(.secondary)
            case .inaccessibleTags:
                Text("This account cannot access the audiobook's tags.")
                    .foregroundStyle(.secondary)
            case .explicitContentDenied:
                Text("This account cannot access explicit audiobooks.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func downloadAction(_ detail: LibraryBookDetail) -> some View {
        if let account = model.account {
            let availability = BookActionAvailability(
                user: account.user,
                detail: detail
            )
            if availability.visibleActions.contains(.download) {
                if let record = model.downloads.record(
                    accountID: account.id,
                    itemID: detail.id
                ) {
                    LabeledContent(
                        "Offline",
                        value: record.manifest.state == .complete
                            ? "Downloaded"
                            : "Downloading"
                    )
                } else {
                    Button {
                        Task {
                            await model.downloads.download(
                                detail: detail,
                                account: account
                            )
                        }
                    } label: {
                        Label(
                            "Download",
                            systemImage: "arrow.down.circle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("book.detail.download")
                }
            }
        }
    }

    private func durationText(_ duration: Double) -> String {
        let totalMinutes = max(0, Int(duration) / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 {
            return "\(minutes) min"
        }
        return "\(hours) hr \(minutes) min"
    }
}

private struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var showAddAccount = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Accounts") {
                    ForEach(model.accounts, id: \.id) { account in
                        Button {
                            Task {
                                await model.switchAccount(to: account)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(account.user.username)
                                    Text(account.server.url.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if account.id == model.account?.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            account.id == model.account?.id
                                || model.accountActionStatus == .switching
                        )
                    }
                    Button("Add Account", systemImage: "plus") {
                        model.prepareAccountLogin()
                        showAddAccount = true
                    }
                    .accessibilityIdentifier("settings.addAccount")
                }

                if case .failed(let failure) = model.accountActionStatus {
                    Section {
                        Text(failure.message)
                            .foregroundStyle(.red)
                    }
                }

                Section("Downloads") {
                    Toggle(
                        "Wi-Fi Only",
                        isOn: Binding(
                            get: {
                                model.downloads.networkPolicy == .wifiOnly
                            },
                            set: { wifiOnly in
                                model.downloads.setNetworkPolicy(
                                    wifiOnly ? .wifiOnly : .allowCellular
                                )
                            }
                        )
                    )
                    .accessibilityIdentifier(
                        "settings.downloads.wifiOnly"
                    )
                }

                Section("Playback") {
                    Picker(
                        "Resume Rewind",
                        selection: Binding(
                            get: {
                                model.playback.resumeRewind
                            },
                            set: { value in
                                model.playback.setResumeRewind(value)
                            }
                        )
                    ) {
                        ForEach(ResumeRewind.allCases) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    .accessibilityIdentifier(
                        "settings.playback.resumeRewind"
                    )
                }

                Section {
                    Button("Remove Account", role: .destructive) {
                        Task {
                            await model.removeAccount()
                        }
                    }
                    .disabled(model.accountActionStatus == .removing)
                    .accessibilityIdentifier("settings.removeAccount")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showAddAccount) {
                NativeLoginView(
                    model: model,
                    navigationTitle: "Add Account"
                ) {
                    showAddAccount = false
                } onCancel: {
                    showAddAccount = false
                }
            }
        }
    }
}

private struct DownloadsView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            Group {
                if model.downloads.records.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle"
                    )
                } else {
                    List {
                        ForEach(accountGroups, id: \.accountID) { group in
                            Section {
                                ForEach(
                                    group.records,
                                    id: \.manifest.downloadID
                                ) { record in
                                    downloadRow(record)
                                }
                            } header: {
                                Text(accountLabel(group.accountID))
                            } footer: {
                                Text(
                                    "\(byteCount(group.storedBytes)) stored"
                                )
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if let failure = model.downloads.failure {
                    Label(
                        failure.message,
                        systemImage: "externaldrive.badge.exclamationmark"
                    )
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                    .accessibilityIdentifier("downloads.error")
                }
            }
            .navigationTitle("Downloads")
        }
    }

    private var accountGroups: [DownloadAccountGroup] {
        Dictionary(
            grouping: model.downloads.records,
            by: \.manifest.accountID
        )
        .map {
            DownloadAccountGroup(
                accountID: $0.key,
                records: $0.value
            )
        }
        .sorted {
            accountLabel($0.accountID).localizedStandardCompare(
                accountLabel($1.accountID)
            ) == .orderedAscending
        }
    }

    @ViewBuilder
    private func downloadRow(_ record: DownloadedBookRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.detail.title)
                .font(.headline)
            ProgressView(
                value: model.downloads.progress[
                    record.manifest.downloadID
                ]
                    ?? (record.manifest.state == .complete ? 1 : 0)
            )
            HStack {
                Text(
                    model.downloads.pausedDownloadIDs.contains(
                        record.manifest.downloadID
                    )
                        ? "Paused"
                        : record.manifest.state.rawValue.capitalized
                )
                Spacer()
                Text(
                    "\(byteCount(record.manifest.storedByteLength)) of \(byteCount(record.manifest.expectedByteLength))"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if record.manifest.state == .complete {
                Button("Play Offline") {
                    Task {
                        await model.playDownloaded(record)
                    }
                }
                .buttonStyle(.borderedProminent)
            } else if [
                DownloadManifestState.failed,
                .partial,
            ].contains(record.manifest.state),
                let account = model.account,
                account.id == record.manifest.accountID
            {
                Button(
                    record.manifest.state == .partial
                        ? "Repair" : "Retry"
                ) {
                    Task {
                        await model.downloads.repair(
                            record,
                            account: account
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                HStack {
                    if model.downloads.pausedDownloadIDs.contains(
                        record.manifest.downloadID
                    ) {
                        Button("Resume") {
                            Task {
                                await model.downloads.resume(record)
                            }
                        }
                    } else {
                        Button("Pause") {
                            Task {
                                await model.downloads.pause(record)
                            }
                        }
                    }
                    Button("Cancel", role: .destructive) {
                        Task {
                            await model.downloads.cancel(record)
                        }
                    }
                }
            }
        }
        .swipeActions {
            Button("Delete", role: .destructive) {
                Task {
                    await model.downloads.remove(record)
                }
            }
        }
    }

    private func accountLabel(_ accountID: AccountID) -> String {
        guard
            let account = model.accounts.first(where: {
                $0.id == accountID
            })
        else {
            return "Saved account"
        }
        let host = account.server.url.host ?? account.server.url.absoluteString
        return "\(account.user.username) · \(host)"
    }

    private func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: max(value, 0),
            countStyle: .file
        )
    }
}

private struct DownloadAccountGroup {
    let accountID: AccountID
    let records: [DownloadedBookRecord]

    var storedBytes: Int64 {
        records.reduce(0) { total, record in
            let (sum, overflow) = total.addingReportingOverflow(
                record.manifest.storedByteLength
            )
            return overflow ? Int64.max : sum
        }
    }
}
