import BleatCore
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
            .navigationTitle("Bleat")
        }
    }

    private func submit() {
        let submittedServerAddress = serverAddress
        let submittedUsername = username
        let submittedPassword = password
        password = ""

        Task {
            await model.login(
                serverAddress: submittedServerAddress,
                username: submittedUsername,
                password: submittedPassword
            )
        }
    }
}

private struct SignedInView: View {
    @Bindable var model: AppModel

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
                PendingFeatureView(
                    title: "Downloads",
                    systemImage: "arrow.down.circle"
                )
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView(model: model)
            }
        }
        .accessibilityIdentifier("app.signedIn")
    }
}

private struct HomeView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            BookListContent(model: model)
                .navigationTitle("Home")
        }
    }
}

private struct LibraryView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                libraryPicker
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
                List(page.items, id: \.id.rawValue) { book in
                    BookSummaryRow(book: book)
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
                    BookSummaryRow(book: book)
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

    var body: some View {
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

private struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                if let account = model.account {
                    Section("Account") {
                        LabeledContent("Username", value: account.user.username)
                        LabeledContent(
                            "Server",
                            value: account.server.url.host
                                ?? account.server.url
                                .absoluteString
                        )
                    }
                }

                if case .failed(let failure) = model.accountActionStatus {
                    Section {
                        Text(failure.message)
                            .foregroundStyle(.red)
                    }
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
        }
    }
}

private struct PendingFeatureView: View {
    let title: String
    let systemImage: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: systemImage)
                .navigationTitle(title)
        }
    }
}
