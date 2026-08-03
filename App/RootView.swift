import BleatCore
import Foundation
import SwiftUI

enum BookDetailPlaybackAction: Equatable {
    case play
    case playAgain
    case pause

    static func decide(
        itemID: LibraryItemID,
        currentItemID: LibraryItemID?,
        isPlaybackRequested: Bool
    ) -> BookDetailPlaybackAction {
        guard itemID == currentItemID else {
            return .play
        }
        return isPlaybackRequested ? .pause : .playAgain
    }

    var label: String {
        switch self {
        case .play:
            "Play"
        case .playAgain:
            "Play Again"
        case .pause:
            "Pause"
        }
    }

    var systemImage: String {
        switch self {
        case .play, .playAgain:
            "play.fill"
        case .pause:
            "pause.fill"
        }
    }
}

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @ColourSchemePreference private var colourScheme

    var body: some View {
        Group {
            switch model.phase {
            case .launching:
                LaunchingView(stage: model.launchStage)
                    .tint(colourScheme.color)
            case .signedOut:
                NativeLoginView(model: model).tint(colourScheme.color)
            case .signedIn:
                SignedInView(model: model).tint(colourScheme.color)
            case .unavailable(let failure):
                ContentUnavailableView {
                    Label(failure.title, systemImage: failure.systemImage)
                } description: {
                    Text(failure.message)
                } actions: {
                    Button("Try Again") {
                        Task {
                            await model.retryStart()
                        }
                    }
                    .accessibilityIdentifier("app.retry")
                }
                .accessibilityIdentifier("app.unavailable")
                .tint(colourScheme.color)
            }
        }
        .task {
            await model.start()
        }
        .onChange(of: scenePhase) { _, phase in
            model.setLiveUpdatesActive(phase == .active)
            if phase != .active {
                Task {
                    await model.synchronizePrivateCloud()
                }
            }
        }
    }
}

private struct LaunchingView: View {
    let stage: AppLaunchStage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLogoPulsing = false

    var body: some View {
        VStack(spacing: 16) {
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 21))
                .scaleEffect(isLogoPulsing ? 1.04 : 1)
                .opacity(isLogoPulsing ? 1 : 0.94)
                .accessibilityHidden(true)

            Text("Bleat")
                .font(.title.bold())

            ProgressView()

            Text(stage.message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Starting Bleat. \(stage.message)")
        .accessibilityIdentifier("app.launching")
        .onAppear {
            updateLogoAnimation()
        }
        .onChange(of: reduceMotion) {
            updateLogoAnimation()
        }
        .animation(
            reduceMotion
                ? nil
                : .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
            value: isLogoPulsing
        )
    }

    private func updateLogoAnimation() {
        isLogoPulsing = !reduceMotion
    }
}

private struct AccountSubmissionButton: View {
    let idleTitle: String
    let status: LoginStatus
    let isDisabled: Bool
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let stage = status.submissionStage {
                    ProgressView()
                    Text(stage.label)
                } else {
                    Text(idleTitle)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(isDisabled)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(status.submissionStage?.label ?? idleTitle)
    }
}

private struct NativeLoginView: View {
    @Bindable var model: AppModel
    var navigationTitle = "Bleat"
    var showsOfflineDownloads = true
    var onSignedIn: () -> Void = {}
    var onCancel: (() -> Void)?
    @State private var showOfflineDownloads = false
    @State private var serverAddress = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var invalidURLErrorMessage: String?

    private var isSubmitting: Bool {
        model.loginStatus.isSubmitting
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
                        "Server Url (e.g. https://bleat.example.com)",
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
                    if isPasswordVisible {
                        TextField("Password", text: $password)
                            .textContentType(.password)
                            .accessibilityIdentifier("login.password")
                    } else {
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .accessibilityIdentifier("login.password")
                    }
                    Button {
                        isPasswordVisible.toggle()
                    } label: {
                        Image(
                            systemName: isPasswordVisible
                                ? "eye.slash" : "eye"
                        )
                    }
                    .accessibilityLabel(
                        isPasswordVisible
                            ? "Hide password" : "Show password"
                    )
                }

                if case .failed(let failure) = model.loginStatus {
                    Section {
                        Text(failure.message)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("login.error")
                    }
                }

                Section {
                    AccountSubmissionButton(
                        idleTitle: "Sign In",
                        status: model.loginStatus,
                        isDisabled: !canSubmit,
                        accessibilityIdentifier: "login.submit",
                        action: submit
                    )
                }

                if showsOfflineDownloads,
                    !model.downloads.records.isEmpty
                {
                    Section {
                        Button(
                            "Offline Downloads",
                            systemImage: "arrow.down.circle"
                        ) {
                            showOfflineDownloads = true
                        }
                        .accessibilityIdentifier(
                            "login.offlineDownloads"
                        )
                    }
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
            .sheet(isPresented: $showOfflineDownloads) {
                OfflineDownloadsSheet(model: model)
            }
            .alert(
                "Invalid URL",
                isPresented: .constant(invalidURLErrorMessage != nil),
                actions: {
                    Button("OK") {
                        invalidURLErrorMessage = nil
                    }
                },
                message: {
                    if let message = invalidURLErrorMessage {
                        Text(message)
                    }
                }
            )
        }
    }

    private func submit() {
        let submittedServerAddress = serverAddress
        let submittedUsername = username
        let submittedPassword = password

        // Client-side URL validation: must start with https://
        guard let url = URL(string: submittedServerAddress),
            url.scheme?.lowercased() == "https",
            let host = url.host, !host.isEmpty
        else {
            invalidURLErrorMessage = "URL must start with https://"
            return
        }

        Task {
            let signedIn = await model.login(
                serverAddress: submittedServerAddress,
                username: submittedUsername,
                password: submittedPassword
            )
            if signedIn {
                onSignedIn()
                password = ""
            }
        }
    }
}

private struct OfflineDownloadsSheet: View {
    @Bindable var model: AppModel
    @State private var showPlayer = false

    var body: some View {
        GeometryReader { geometry in
            DownloadsView(model: model)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if model.playback.hasActiveBook {
                        MiniPlayerView(
                            playback: model.playback,
                            containerHeight: geometry.size.height
                        ) {
                            showPlayer = true
                        }
                    }
                }
        }
        .sheet(isPresented: $showPlayer) {
            NowPlaying(playback: model.playback)
        }
    }
}

private struct AccountEditorView: View {
    @Bindable var model: AppModel
    let account: ServerAccount
    let onSaved: () -> Void
    let onCancel: () -> Void
    @State private var serverAddress: String
    @State private var localServerAddress: String
    @State private var username: String
    @State private var password = ""
    @State private var localValidationFailure: AppFailure?
    @State private var showRemoveAccountConfirmation = false
    @State private var pendingRemovalScope: AccountRemovalScope?

    init(
        model: AppModel,
        account: ServerAccount,
        onSaved: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.model = model
        self.account = account
        self.onSaved = onSaved
        self.onCancel = onCancel
        _serverAddress = State(initialValue: account.server.url.absoluteString)
        _localServerAddress = State(
            initialValue: account.localServer?.url.absoluteString ?? ""
        )
        _username = State(initialValue: account.user.username)
    }

    private var isSubmitting: Bool {
        model.loginStatus.isSubmitting
    }

    private var canSubmit: Bool {
        !serverAddress.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
            && !username.isEmpty
            && (username == account.user.username || !password.isEmpty)
            && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Servers") {
                    TextField(
                        "Primary server URL",
                        text: $serverAddress
                    )
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("accountEditor.server")

                    TextField(
                        "Local server URL (optional)",
                        text: $localServerAddress
                    )
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("accountEditor.localServer")
                }

                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("accountEditor.username")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier(
                            "accountEditor.password"
                        )
                } header: {
                    Text("Credentials")
                } footer: {
                    Text(
                        "Leave password blank to keep the existing saved "
                            + "credentials."
                    )
                }

                if case .failed(let failure) = model.loginStatus {
                    Section {
                        Text(failure.message)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier(
                                "accountEditor.error"
                            )
                    }
                }

                Section {
                    AccountSubmissionButton(
                        idleTitle: "Save",
                        status: model.loginStatus,
                        isDisabled: !canSubmit,
                        accessibilityIdentifier: "accountEditor.save",
                        action: { submit() }
                    )
                }

                if model.account?.id != account.id {
                    Section {
                        Button("Use This Account") {
                            Task {
                                await model.switchAccount(to: account)
                                onSaved()
                            }
                        }
                        .disabled(model.accountActionStatus == .switching)
                        .accessibilityIdentifier("accountEditor.activate")
                    }
                }

                Section {
                    Button("Remove Account", role: .destructive) {
                        showRemoveAccountConfirmation = true
                    }
                    .disabled(model.accountActionStatus == .removing)
                    .accessibilityIdentifier("accountEditor.removeAccount")
                }

                if case .failed(let failure) = model.accountActionStatus {
                    Section {
                        Text(failure.message)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Account")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
            .confirmationDialog(
                "Local server could not be verified",
                isPresented: Binding(
                    get: { localValidationFailure != nil },
                    set: { isPresented in
                        if !isPresented {
                            localValidationFailure = nil
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button("Save Without Local Verification") {
                    localValidationFailure = nil
                    submit(allowUnvalidatedLocalServer: true)
                }
                Button("Cancel", role: .cancel) {
                    localValidationFailure = nil
                }
            } message: {
                if let localValidationFailure {
                    Text(
                        localValidationFailure.message
                            + " The primary details can still be saved. The "
                            + "local address will be kept but disabled until "
                            + "it can be verified."
                    )
                }
            }
            .confirmationDialog(
                "Remove Account?",
                isPresented: $showRemoveAccountConfirmation,
                titleVisibility: .visible
            ) {
                Button("Only on This Device", role: .destructive) {
                    pendingRemovalScope = .thisDevice
                }
                if model.privateCloudSyncEnabled {
                    Button("On All Devices", role: .destructive) {
                        pendingRemovalScope = .allDevices
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Choose where Bleat removes this saved account.")
            }
            .confirmationDialog(
                "Keep Listening History?",
                isPresented: Binding(
                    get: { pendingRemovalScope != nil },
                    set: { presented in
                        if !presented {
                            pendingRemovalScope = nil
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                removalDataButtons
                Button("Cancel", role: .cancel) {
                    pendingRemovalScope = nil
                }
            } message: {
                Text(removalDataMessage)
            }
        }
    }

    private func submit(allowUnvalidatedLocalServer: Bool = false) {
        let submittedPassword = password
        Task {
            let result = await model.updateAccount(
                account,
                serverAddress: serverAddress,
                localServerAddress: localServerAddress,
                username: username,
                password: submittedPassword,
                allowUnvalidatedLocalServer: allowUnvalidatedLocalServer
            )
            switch result {
            case .saved:
                password = ""
                onSaved()
            case .localServerValidationFailed(let failure):
                localValidationFailure = failure
            case .failed:
                break
            }
        }
    }

    @ViewBuilder
    private var removalDataButtons: some View {
        if accountDownloads.isEmpty {
            Button("Keep Listening History", role: .destructive) {
                removeAccount(downloads: .delete, statistics: .keep)
            }
            Button("Delete Listening History", role: .destructive) {
                removeAccount(downloads: .delete, statistics: .delete)
            }
        } else {
            Button("Keep History and Downloads", role: .destructive) {
                removeAccount(downloads: .keep, statistics: .keep)
            }
            Button("Keep History, Delete Downloads", role: .destructive) {
                removeAccount(downloads: .delete, statistics: .keep)
            }
            Button("Delete History, Keep Downloads", role: .destructive) {
                removeAccount(downloads: .keep, statistics: .delete)
            }
            Button("Delete History and Downloads", role: .destructive) {
                removeAccount(downloads: .delete, statistics: .delete)
            }
        }
    }

    private var removalDataMessage: String {
        guard !accountDownloads.isEmpty else {
            return "Choose whether to keep this account's listening history."
        }
        let count = accountDownloads.count
        let books = count == 1 ? "book" : "books"
        let bytes = ByteCountFormatter.string(
            fromByteCount: storedDownloadBytes(accountDownloads),
            countStyle: .file
        )
        return "\(count) downloaded \(books) use \(bytes). Choose what to keep."
    }

    private var accountDownloads: [DownloadedBookRecord] {
        model.downloads.records.filter {
            $0.manifest.accountID == account.id
        }
    }

    private func removeAccount(
        downloads disposition: AccountDownloadDisposition,
        statistics statisticsDisposition: AccountStatisticsDisposition
    ) {
        guard let scope = pendingRemovalScope else {
            return
        }
        pendingRemovalScope = nil
        Task {
            if await model.removeAccount(
                account,
                downloads: disposition,
                scope: scope,
                statistics: statisticsDisposition
            ) {
                onSaved()
            }
        }
    }
}

private struct DiagnosticsView: View {
    @Bindable var model: AppModel
    #if DEBUG
        @State private var recentLogExport: RecentLogExportModel?
    #endif

    init(model: AppModel) {
        self.model = model
        #if DEBUG
            _recentLogExport = State(
                initialValue: model.diagnosticLogStore.map(
                    RecentLogExportModel.init
                )
            )
        #endif
    }

    private var report: DiagnosticsReport {
        model.diagnosticsReport()
    }

    var body: some View {
        List {
            Section("App") {
                LabeledContent(
                    "Version",
                    value:
                        "\(report.environment.appVersion) (\(report.environment.appBuild))"
                )
                LabeledContent(
                    "Operating System",
                    value: report.environment.operatingSystem
                )
                LabeledContent("State", value: report.appState)
            }

            Section("Server") {
                LabeledContent(
                    "Version",
                    value: report.serverVersion ?? "Unavailable"
                )
                .accessibilityIdentifier(
                    "diagnostics.serverVersion"
                )
                LabeledContent(
                    "Connection",
                    value: report.connectionState ?? "No active account"
                )
                LabeledContent(
                    "Saved Accounts",
                    value: String(report.accountCount)
                )
                LabeledContent(
                    "Last Server Activity",
                    value:
                        report.lastServerConnection
                        ?? "Not recorded this launch"
                )
                .accessibilityIdentifier(
                    "diagnostics.lastServerConnection"
                )
                LabeledContent(
                    "Last Authentication",
                    value:
                        report.authenticationEndpoint
                        ?? "Not recorded this launch"
                )
                .accessibilityIdentifier(
                    "diagnostics.authenticationEndpoint"
                )
                LabeledContent(
                    "Last API Connection",
                    value:
                        report.apiEndpoint
                        ?? "Not recorded this launch"
                )
                .accessibilityIdentifier("diagnostics.apiEndpoint")
                LabeledContent(
                    "WebSocket",
                    value: report.webSocketEndpoint ?? "No active account"
                )
                .accessibilityIdentifier("diagnostics.webSocketEndpoint")
                LabeledContent(
                    "WebSocket State",
                    value: report.webSocketState
                )
                .accessibilityIdentifier("diagnostics.webSocketState")
            }

            Section("Activity") {
                LabeledContent("Libraries", value: report.libraryState)
                LabeledContent("Home", value: report.homeState)
                LabeledContent("Search", value: report.searchState)
                LabeledContent("Playback", value: report.playbackState)
                LabeledContent(
                    "Playback Sync",
                    value: report.playbackSyncState
                )
                LabeledContent(
                    "Downloads",
                    value: String(report.downloadCount)
                )
            }

            if !report.errorCodes.isEmpty {
                Section("Active Errors") {
                    ForEach(report.errorCodes, id: \.self) { code in
                        Text(code)
                    }
                }
            }

            #if DEBUG
                Section {
                    ShareLink(
                        item: report.text,
                        subject: Text("Bleat Diagnostics")
                    ) {
                        Label(
                            "Export Diagnostics",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .accessibilityIdentifier("diagnostics.export")

                    Button {
                        guard let recentLogExport else {
                            return
                        }
                        Task {
                            await recentLogExport.prepare(
                                environment: report.environment
                            )
                        }
                    } label: {
                        if recentLogExport?.state == .preparing {
                            Label(
                                "Preparing Recent Logs",
                                systemImage: "hourglass"
                            )
                        } else {
                            Label(
                                "Export Recent Logs",
                                systemImage: "doc.text"
                            )
                        }
                    }
                    .disabled(
                        recentLogExport == nil
                            || recentLogExport?.state == .preparing
                    )
                    .accessibilityIdentifier(
                        "diagnostics.exportRecentLogs"
                    )
                } footer: {
                    Text(
                        "The snapshot includes server hostnames and ports. Exports exclude account names, URL paths and queries, credentials, tokens, response bodies, media titles and URLs, remote identifiers, session IDs, listening positions, and local file paths."
                    )
                }
            #endif
        }
        .navigationTitle("Diagnostics")
        .task {
            await model.refreshEndpointDiagnostics()
        }
        #if DEBUG
            .sheet(
                isPresented: Binding(
                    get: {
                        recentLogExport?.sharingURL != nil
                    },
                    set: { isPresented in
                        if !isPresented {
                            recentLogExport?.finishSharing()
                        }
                    }
                )
            ) {
                if let url = recentLogExport?.sharingURL {
                    DiagnosticActivityView(fileURL: url) {
                        recentLogExport?.finishSharing()
                    }
                    .accessibilityIdentifier(
                        "diagnostics.activityView"
                    )
                }
            }
            .alert(
                "Unable to Export Logs",
                isPresented: Binding(
                    get: {
                        recentLogExport?.failure != nil
                    },
                    set: { isPresented in
                        if !isPresented {
                            recentLogExport?.dismissFailure()
                        }
                    }
                )
            ) {
                Button("OK") {
                    recentLogExport?.dismissFailure()
                }
            } message: {
                if let failure = recentLogExport?.failure {
                    Text(failure.message)
                }
            }
            .onDisappear {
                recentLogExport?.finishSharing()
            }
        #endif
    }
}

private struct SignedInView: View {
    @Bindable var model: AppModel
    @State private var showPlayer = false

    var body: some View {
        GeometryReader { geometry in
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
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.playback.hasActiveBook {
                    MiniPlayerView(
                        playback: model.playback,
                        containerHeight: geometry.size.height
                    ) {
                        showPlayer = true
                    }
                }
            }
        }
        .sheet(isPresented: $showPlayer) {
            NowPlaying(playback: model.playback)

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
                .safeAreaInset(edge: .top, spacing: 0) {
                    homeContext
                }
                .navigationDestination(for: LibraryBookSummary.self) { book in
                    BookDetailView(model: model, book: book)
                }
        }
    }

    @ViewBuilder
    private var homeContext: some View {
        if let account = model.account {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle")
                Text(account.user.username)
                    .lineLimit(1)
                Text("@")
                    .foregroundStyle(.tertiary)
                Text(
                    account.server.url.host
                        ?? account.server.url.absoluteString
                )
                .lineLimit(1)
                .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let library = model.selectedLibrary {
                    Text(library.name)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("home.account")
        }
    }
}

private struct HomeContent: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.homeShelves {
            case .idle, .loading:
                if downloadedRecords.isEmpty {
                    statusScroll {
                        ProgressView()
                            .accessibilityIdentifier("home.loading")
                    }
                } else {
                    homeScroll(shelves: []) {
                        ProgressView("Loading shelves")
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("home.loading")
                    }
                }
            case .failed(let failure):
                if downloadedRecords.isEmpty {
                    statusScroll {
                        ContentUnavailableView(
                            "Home unavailable",
                            systemImage: "wifi.exclamationmark",
                            description: Text(failure.message)
                        )
                        .accessibilityIdentifier("home.error")
                    }
                } else {
                    homeScroll(shelves: []) {
                        Label(
                            failure.message,
                            systemImage: "wifi.exclamationmark"
                        )
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .accessibilityIdentifier("home.error")
                    }
                }
            case .loaded(let shelves):
                if shelves.isEmpty && downloadedRecords.isEmpty {
                    statusScroll {
                        ContentUnavailableView(
                            "No personalized shelves",
                            systemImage: "books.vertical"
                        )
                        .accessibilityIdentifier("home.empty")
                    }
                } else {
                    homeScroll(shelves: shelves) {
                        if shelves.isEmpty {
                            Label(
                                "No personalized shelves",
                                systemImage: "books.vertical"
                            )
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .accessibilityIdentifier("home.empty")
                        }
                    }
                }
            }
        }
    }

    private var downloadedRecords: [DownloadedBookRecord] {
        guard let accountID = model.account?.id else {
            return []
        }
        return model.downloads.records
            .filter {
                $0.manifest.accountID == accountID
                    && model.downloads.isFullBookAvailable($0)
            }
            .sorted {
                $0.detail.title.localizedStandardCompare(
                    $1.detail.title
                ) == .orderedAscending
            }
    }

    private func homeScroll<Trailing: View>(
        shelves: [LibraryBookShelf],
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(shelves.prefix(2), id: \.id) { shelf in
                    shelfContent(shelf)
                }
                if !downloadedRecords.isEmpty {
                    downloadedShelf
                }
                ForEach(shelves.dropFirst(2), id: \.id) { shelf in
                    shelfContent(shelf)
                }
                trailing()
            }
            .padding(.vertical)
        }
        .accessibilityIdentifier("home.shelves")
        .refreshable {
            await refresh()
        }
    }

    private func statusScroll<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 80)
        }
        .accessibilityIdentifier("home.shelves")
        .refreshable {
            await refresh()
        }
    }

    private func refresh() async {
        guard let library = model.selectedLibrary else {
            return
        }
        await model.selectLibrary(library)
    }

    private var downloadedShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Downloaded")
                .font(.title2.bold())
                .padding(.horizontal)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(
                        downloadedRecords,
                        id: \.manifest.downloadID
                    ) { record in
                        Button {
                            Task {
                                await model.playDownloaded(record)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                ZStack(alignment: .bottomTrailing) {
                                    BookCoverView(
                                        accountID: model.account?.id,
                                        server: model.account?.server,
                                        itemID: record.detail.id,
                                        updatedAtMilliseconds:
                                            record.detail
                                            .updatedAtMilliseconds,
                                        width: 360,
                                        height: 360,
                                        cornerRadius: 10
                                    )
                                    .frame(width: 148, height: 148)
                                    Image(
                                        systemName:
                                            model.playback.itemID
                                            == record.detail.id
                                            && model.playback.accountID
                                                == record.manifest.accountID
                                            ? "speaker.wave.2.circle.fill"
                                            : "play.circle.fill"
                                    )
                                    .font(.title)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(
                                        .white, .black.opacity(0.7)
                                    )
                                    .padding(8)
                                }
                                Text(record.detail.title)
                                    .font(.headline)
                                    .lineLimit(2)
                                if !record.detail.authors.isEmpty {
                                    Text(
                                        record.detail.authors
                                            .map(\.name)
                                            .joined(separator: ", ")
                                    )
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                }
                            }
                            .frame(width: 148, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "Play \(record.detail.title) offline"
                        )
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("home.downloaded")
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
                                    accountID: model.account?.id,
                                    server: model.account?.server,
                                    itemID: book.id,
                                    updatedAtMilliseconds:
                                        book.updatedAtMilliseconds,
                                    width: 360,
                                    height: 360,
                                    cornerRadius: 10
                                )
                                .frame(width: 148, height: 148)
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
                            .frame(width: 148, alignment: .leading)
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
                statusScroll {
                    ProgressView()
                        .accessibilityIdentifier("library.loading")
                }
            case .failed(let failure):
                statusScroll {
                    failureView(failure)
                }
            case .loaded(let libraries):
                if libraries.isEmpty {
                    statusScroll {
                        ContentUnavailableView(
                            "No audiobook libraries",
                            systemImage: "books.vertical"
                        )
                    }
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
            statusScroll {
                ProgressView()
                    .accessibilityIdentifier("books.loading")
            }
        case .failed(let failure):
            statusScroll {
                failureView(failure)
            }
        case .loaded(let page):
            if page.items.isEmpty {
                statusScroll {
                    ContentUnavailableView(
                        "No audiobooks",
                        systemImage: "book.closed"
                    )
                }
            } else {
                List {
                    ForEach(page.items, id: \.id.rawValue) { book in
                        NavigationLink(value: book) {
                            BookSummaryRow(
                                book: book,
                                accountID: model.account?.id,
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
                .refreshable {
                    await model.loadLibraries()
                }
            }
        }
    }

    private func statusScroll<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 80)
        }
        .accessibilityIdentifier("books.list")
        .refreshable {
            await model.loadLibraries()
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
                            accountID: model.account?.id,
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
    let accountID: AccountID?
    let server: NormalizedServerURL?

    var body: some View {
        HStack(spacing: 12) {
            BookCoverView(
                accountID: accountID,
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
    @Environment(\.dismiss) private var dismiss
    @State private var showMetadataEditor = false
    @State private var showRemoveDownloadConfirmation = false

    @ColourSchemePreference private var colourScheme

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
                    bookDetailFailureView(failure)
                case .loaded(let detail):
                    detailContent(detail, colourScheme: colourScheme)
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
                if canOpenEditor(detail) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Edit", systemImage: "pencil") {
                                showMetadataEditor = true
                            }
                            .accessibilityIdentifier("book.detail.edit")

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
                            .buttonStyle(.bordered)
                            .disabled(model.bookProgressUpdateState == .saving)
                            .accessibilityIdentifier("book.detail.finished")

                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel("Book Actions")
                        .accessibilityIdentifier("book.detail.actions")
                    }
                }
            }
        }
        .sheet(isPresented: $showMetadataEditor) {
            if let detail = loadedDetail {
                MetadataEditorView(
                    model: model,
                    detail: detail
                ) {
                    showMetadataEditor = false
                    model.completeBookDeletion()
                    dismiss()
                }
            }
        }
        .confirmationDialog(
            "Remove Download?",
            isPresented: $showRemoveDownloadConfirmation,
            titleVisibility: .visible
        ) {
            if let record = downloadedRecord {
                Button("Remove Download", role: .destructive) {
                    Task {
                        await model.downloads.remove(record)
                    }
                }
                .disabled(isDownloadedRecordPlaying)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes the audiobook files stored on this device."
            )
        }
    }

    @ViewBuilder
    private func bookDetailFailureView(
        _ failure: AppFailure
    ) -> some View {
        if failure.operation == .loadBook {
            ContentUnavailableView {
                Label(
                    failure.title,
                    systemImage: failure.systemImage
                )
            } description: {
                Text(failure.message)
                    .accessibilityIdentifier("book.detail.error.reason")
            } actions: {
                if failure.allowsRetry {
                    Button("Try Again") {
                        Task {
                            await model.loadBookDetail(book)
                        }
                    }
                    .accessibilityIdentifier("book.detail.retry")
                }
            }
            .accessibilityIdentifier("book.detail.error")
        } else {
            ContentUnavailableView(
                "Audiobook unavailable",
                systemImage: "wifi.exclamationmark",
                description: Text(failure.message)
            )
            .accessibilityIdentifier("book.detail.error")
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

    private func canOpenEditor(_ detail: LibraryBookDetail) -> Bool {
        guard let user = model.account?.user else {
            return false
        }
        let actions = BookActionAvailability(
            user: user,
            detail: detail
        ).visibleActions
        return actions.contains(.editMetadata)
            || actions.contains(.editCover)
            || actions.contains(.deleteFromServer)
    }

    private func detailContent(
        _ detail: LibraryBookDetail, colourScheme: ColourScheme
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                BookCoverView(
                    accountID: model.account?.id,
                    server: model.account?.server,
                    itemID: detail.id,
                    updatedAtMilliseconds: detail.updatedAtMilliseconds,
                    width: 600,
                    height: 600,
                    cornerRadius: 14
                )
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 220)
                .frame(maxWidth: .infinity)

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
                    if !detail.series.isEmpty {
                        Text(seriesText(detail.series))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("book.detail.series")
                    }
                    if !detail.narrators.isEmpty {
                        Text(
                            "Narrated by "
                                + detail.narrators.joined(separator: ", ")
                        )
                        .foregroundStyle(.secondary)
                    }
                }

                if model.accounts.count > 1,
                    let account = model.account
                {
                    Label(
                        "\(account.user.username) · \(account.server.url.host ?? account.server.url.absoluteString)",
                        systemImage: "person.crop.circle"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("book.detail.account")
                }

                if let progress = detail.progress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress.progress).tint(
                            colourScheme.color)
                        Text(
                            progress.isFinished
                                ? "Finished"
                                : "\(Int(progress.progress * 100))% complete"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 12) {
                    playbackAction(detail)
                    downloadAction(detail)

                }
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

                bookmarksSection

                if !detail.chapters.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Chapters")
                            .font(.headline)
                        ForEach(
                            detail.chapters,
                            id: \.id
                        ) { chapter in
                            HStack(alignment: .firstTextBaseline) {
                                Text(chapter.title)
                                Spacer()
                                Text(chapterDurationText(chapter))
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier(
                                "book.detail.chapter.\(chapter.id)"
                            )
                        }
                    }
                }
            }
            .padding()
        }
        .accessibilityIdentifier("book.detail")
    }

    @ViewBuilder
    private var bookmarksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bookmarks")
                .font(.headline)
            switch model.bookBookmarks {
            case .idle, .loading:
                ProgressView()
                    .accessibilityIdentifier("book.detail.bookmarks.loading")
            case .loaded(let bookmarks):
                if bookmarks.isEmpty {
                    Text("No bookmarks")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            "book.detail.bookmarks.empty"
                        )
                } else {
                    ForEach(bookmarks) { bookmark in
                        HStack(alignment: .firstTextBaseline) {
                            Text(bookmark.title)
                            Spacer()
                            Text(durationText(bookmark.time))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(
                            "book.detail.bookmark"
                        )
                    }
                }
            case .failed(let failure):
                VStack(alignment: .leading, spacing: 8) {
                    Text(failure.message)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task {
                            await model.loadBookBookmarks()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .accessibilityIdentifier("book.detail.bookmarks.error")
            }
        }
    }

    @ViewBuilder
    private func detailsGrid(_ detail: LibraryBookDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details")
                .font(.headline)
            LabeledContent("Duration", value: durationText(detail.duration))
            LabeledContent(
                "Audio Files",
                value: String(detail.audioFileCount)
            )
            LabeledContent(
                "Chapters",
                value: String(detail.chapters.count)
            )
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
                let primaryAction = BookDetailPlaybackAction.decide(
                    itemID: detail.id,
                    currentItemID: model.playback.itemID,
                    isPlaybackRequested:
                        model.playback.isPlaybackRequested
                )
                if let account = model.account,
                    let downloaded = model.downloads.record(
                        accountID: account.id,
                        itemID: detail.id
                    ),
                    model.downloads.isFullBookAvailable(downloaded)
                {
                    Button {
                        switch primaryAction {
                        case .pause:
                            model.playback.pause()
                        case .play, .playAgain:
                            Task {
                                await model.playDownloaded(downloaded)
                            }
                        }
                    } label: {
                        Label(
                            primaryAction.label,
                            systemImage: primaryAction.systemImage
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("book.detail.play")
                } else if availability.visibleActions.contains(.play),
                    let account = model.account
                {
                    Button {
                        switch primaryAction {
                        case .pause:
                            model.playback.pause()
                        case .play, .playAgain:
                            Task {
                                await model.playback.start(
                                    detail: detail,
                                    account: account
                                )
                            }
                        }
                    } label: {
                        Label(
                            primaryAction.label,
                            systemImage: primaryAction.systemImage
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
                    if record.manifest.purpose == .automaticCache
                        || !model.downloads.isFullBookAvailable(record)
                    {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(
                                    downloadStatus(record),
                                    systemImage: downloadStatusIcon(record)
                                )
                                .accessibilityIdentifier(
                                    "book.detail.downloadStatus"
                                )
                                Spacer()
                                Text(downloadBytes(record))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)

                            if record.manifest.purpose == .automaticCache
                                || !model.downloads.isFullBookAvailable(record)
                            {
                                ProgressView(
                                    value: model.downloads.progress[
                                        record.manifest.downloadID
                                    ] ?? 0
                                )
                            }

                            HStack {
                                downloadControls(record, account: account)
                                Spacer()
                                if downloadIsActive(record) {
                                    Button(
                                        "Cancel",
                                        systemImage: "xmark",
                                        role: .destructive
                                    ) {
                                        Task {
                                            await model.downloads.cancel(record)
                                        }
                                    }
                                } else {
                                    Button(
                                        "Remove",
                                        systemImage: "trash",
                                        role: .destructive
                                    ) {
                                        showRemoveDownloadConfirmation = true
                                    }
                                    .disabled(
                                        record.manifest.state == .deleting
                                            || isDownloadedRecordPlaying
                                    ).accessibilityLabel("Remove")
                                }
                            }
                        }
                        .padding()
                        .background(
                            .quaternary,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }
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

    @ViewBuilder
    private func downloadControls(
        _ record: DownloadedBookRecord,
        account: ServerAccount
    ) -> some View {
        if record.manifest.purpose == .automaticCache,
            record.manifest.state != .deleting
        {
            Button {
                Task {
                    await model.downloads.downloadFullBook(
                        record,
                        account: account
                    )
                }
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Download Full Book")
            .accessibilityIdentifier(
                "book.detail.download.fullBook"
            )
            if model.downloads.automaticCacheState(for: record) == .failed {
                Button("Retry") {
                    Task {
                        await model.downloads.repair(
                            record,
                            account: account
                        )
                    }
                }
            } else if downloadIsActive(record) {
                automaticPauseControl(record)
            }
        } else if [
            DownloadManifestState.complete,
            .deleting,
        ].contains(record.manifest.state) {
            EmptyView()
        } else if [
            DownloadManifestState.failed,
            .partial,
        ].contains(record.manifest.state) {
            Button(
                record.manifest.state == .partial ? "Repair" : "Retry"
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
            automaticPauseControl(record)
        }
    }

    @ViewBuilder
    private func automaticPauseControl(
        _ record: DownloadedBookRecord
    ) -> some View {
        @ColourSchemePreference var colourScheme
        if record.manifest.state == .deleting {
            EmptyView()
        } else if model.downloads.pausedDownloadIDs.contains(
            record.manifest.downloadID
        ) {
            Button("Resume", systemImage: "play.fill") {
                Task {
                    await model.downloads.resume(record)
                }
            }.tint(colourScheme.color)
        } else {
            Button("Pause", systemImage: "pause.fill") {
                Task {
                    await model.downloads.pause(record)
                }
            }.tint(colourScheme.color)
        }
    }

    private func downloadIsActive(
        _ record: DownloadedBookRecord
    ) -> Bool {
        if record.manifest.purpose == .automaticCache {
            guard
                let state = model.downloads.automaticCacheState(
                    for: record
                )
            else {
                return false
            }
            return [
                AutomaticCacheState.queued,
                .downloading,
            ].contains(state)
        }
        return [
            DownloadManifestState.queued,
            .downloading,
        ].contains(record.manifest.state)
    }

    private var downloadedRecord: DownloadedBookRecord? {
        guard let account = model.account else {
            return nil
        }
        return model.downloads.record(
            accountID: account.id,
            itemID: book.id
        )
    }

    private var isDownloadedRecordPlaying: Bool {
        guard let record = downloadedRecord else {
            return false
        }
        return model.playback.accountID == record.manifest.accountID
            && model.playback.itemID == record.manifest.itemID
    }

    private func downloadStatus(
        _ record: DownloadedBookRecord
    ) -> String {
        if model.downloads.pausedDownloadIDs.contains(
            record.manifest.downloadID
        ) {
            return "Paused"
        }
        if record.manifest.state == .deleting {
            return "Removing"
        }
        if let cacheState = model.downloads.automaticCacheState(
            for: record
        ) {
            switch cacheState {
            case .queued, .downloading:
                return "Caching"
            case .cached:
                return "Cached"
            case .failed:
                return "Cache failed"
            }
        }
        switch record.manifest.state {
        case .queued:
            return "Queued"
        case .downloading:
            return "Downloading"
        case .partial:
            return "Repair needed"
        case .complete:
            return "Downloaded"
        case .failed:
            return "Download failed"
        case .deleting:
            return "Removing"
        }
    }

    private func downloadStatusIcon(
        _ record: DownloadedBookRecord
    ) -> String {
        if model.downloads.pausedDownloadIDs.contains(
            record.manifest.downloadID
        ) {
            return "pause.circle"
        }
        if record.manifest.state == .deleting {
            return "trash"
        }
        if let cacheState = model.downloads.automaticCacheState(
            for: record
        ) {
            switch cacheState {
            case .queued:
                return "clock"
            case .downloading:
                return "arrow.down.circle"
            case .cached:
                return "checkmark.circle.fill"
            case .failed:
                return "exclamationmark.circle"
            }
        }
        switch record.manifest.state {
        case .queued:
            return "clock"
        case .downloading:
            return "arrow.down.circle"
        case .partial, .failed:
            return "exclamationmark.circle"
        case .complete:
            return "checkmark.circle.fill"
        case .deleting:
            return "trash"
        }
    }

    private func downloadBytes(
        _ record: DownloadedBookRecord
    ) -> String {
        let stored = ByteCountFormatter.string(
            fromByteCount: model.downloads.downloadedByteLength(
                for: record
            ),
            countStyle: .file
        )
        let expected = ByteCountFormatter.string(
            fromByteCount: max(
                model.downloads.expectedByteLength(for: record),
                0
            ),
            countStyle: .file
        )
        return "\(stored) of \(expected)"
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

    private func chapterDurationText(
        _ chapter: PlaybackChapter
    ) -> String {
        let seconds = max(
            0,
            Int((chapter.end - chapter.start).rounded())
        )
        if seconds < 60 {
            return "\(seconds) sec"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes) min"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 {
            return "\(hours) hr"
        }
        return "\(hours) hr \(remainingMinutes) min"
    }

    private func seriesText(
        _ series: [LibraryBookSeries]
    ) -> String {
        series.map {
            guard let sequence = $0.sequence, !sequence.isEmpty else {
                return $0.name
            }
            return "\($0.name) #\(sequence)"
        }
        .joined(separator: ", ")
    }
}

private struct StatisticsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.statistics {
            case .idle, .loading:
                ProgressView()
            case .failed(let failure):
                ContentUnavailableView(
                    failure.title,
                    systemImage: failure.systemImage,
                    description: Text(failure.message)
                )
            case .loaded(let summary):
                List {
                    Section("") {
                        LabeledContent(
                            "Time Listening",
                            value: duration(summary.realSeconds)
                        )
                        LabeledContent(
                            "Audiobook Time",
                            value: duration(summary.audiobookSeconds)
                        )
                        if let speed = summary.effectiveAverageSpeed {
                            LabeledContent(
                                "Average Speed",
                                value: speed.formatted(
                                    .number.precision(
                                        .fractionLength(2)
                                    )
                                ) + "×"
                            )
                        }
                    }
                    Section("Books") {
                        LabeledContent(
                            "Started",
                            value: summary.booksStarted.formatted()
                        )
                        LabeledContent(
                            "Completed",
                            value: summary.booksCompleted.formatted()
                        )
                        // LabeledContent(
                        //     "Completed Runtime",
                        //     value: duration(summary.finishedRuntime)
                        // )
                    }
                    Section("Chapters and Sessions") {
                        LabeledContent(
                            "Chapters Started",
                            value: summary.chaptersStarted.formatted()
                        )
                        LabeledContent(
                            "Chapters Completed",
                            value: summary.chaptersCompleted.formatted()
                        )
                        LabeledContent(
                            "Sessions",
                            value: summary.sessions.formatted()
                        )
                    }
                    if summary.realTimeCoverage == .approximate {
                        Section {
                            Label(
                                "Some listening time is approximate because a server update had an uncertain result.",
                                systemImage: "exclamationmark.triangle"
                            )
                        }
                    }
                }
                .refreshable {
                    await model.loadStatistics()
                    await model.synchronizePrivateCloud()
                }
            }
        }
        .navigationTitle("Listening Statistics")
        .task {
            await model.loadStatistics()
        }
        .accessibilityIdentifier("statistics.view")
    }

    private func duration(_ seconds: Double) -> String {
        let totalMinutes = max(0, Int(seconds.rounded())) / 60
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
    @State private var editingAccount: ServerAccount?
    @State private var showDisableCloudSyncConfirmation = false

    @ColourSchemePreference private var colourScheme

    var body: some View {
        NavigationStack {
            Form {
                Section("Accounts") {
                    ForEach(model.accounts, id: \.id) { account in
                        Button {
                            model.prepareAccountLogin()
                            editingAccount = account
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
                        .disabled(model.accountActionStatus == .switching)
                        .accessibilityIdentifier(
                            "settings.account.\(account.id.rawValue)"
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

                if model.privateCloudSyncAvailable {
                    cloudSection
                }

                Section("Appearance") {
                    Picker("Colour Scheme", selection: $colourScheme) {
                        ForEach(ColourScheme.allCases, id: \.self) { scheme in
                            Text(scheme.rawValue.capitalized)
                                .tag(scheme)
                        }
                    }
                    .accessibilityIdentifier("settings.appearance.tint")
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

                    Stepper(
                        "Files Ahead: \(model.downloads.automaticLookaheadCount)",
                        value: Binding(
                            get: {
                                model.downloads.automaticLookaheadCount
                            },
                            set: { value in
                                model.downloads
                                    .setAutomaticLookaheadCount(value)
                            }
                        ),
                        in: 1...20
                    )
                    .accessibilityIdentifier(
                        "settings.downloads.filesAhead"
                    )

                    Picker(
                        "Delete Automatic Downloads",
                        selection: Binding(
                            get: {
                                model.downloads.automaticCleanupPolicy
                            },
                            set: { value in
                                model.downloads.setAutomaticCleanupPolicy(
                                    value
                                )
                            }
                        )
                    ) {
                        ForEach(
                            AutomaticDownloadCleanupPolicy.allCases
                        ) { policy in
                            Text(policy.label).tag(policy)
                        }
                    }
                    .accessibilityIdentifier(
                        "settings.downloads.automaticCleanup"
                    )

                    NavigationLink {
                        DownloadStorageView(model: model)
                    } label: {
                        LabeledContent(
                            "Manage Downloads",
                            value: downloadStorageText
                        )
                    }
                    .accessibilityIdentifier(
                        "settings.downloads.manage"
                    )
                }

                Section("Playback") {
                    Picker(
                        "Skip Back",
                        selection: Binding(
                            get: {
                                model.playback.skipBackwardInterval
                            },
                            set: { value in
                                model.playback.setSkipBackwardInterval(value)
                            }
                        )
                    ) {
                        ForEach(PlaybackSkipInterval.allCases) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    .accessibilityIdentifier(
                        "settings.playback.skipBackward"
                    )

                    Picker(
                        "Skip Forward",
                        selection: Binding(
                            get: {
                                model.playback.skipForwardInterval
                            },
                            set: { value in
                                model.playback.setSkipForwardInterval(value)
                            }
                        )
                    ) {
                        ForEach(PlaybackSkipInterval.allCases) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    .accessibilityIdentifier(
                        "settings.playback.skipForward"
                    )

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
                    NavigationLink {
                        StatisticsView(model: model)
                    } label: {
                        Label("Listening Stats", systemImage: "chart.bar")
                    }
                    .accessibilityIdentifier("settings.statistics")
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                    .accessibilityIdentifier("settings.about")
                    NavigationLink {
                        DiagnosticsView(model: model)
                    } label: {
                        Label(
                            "Diagnostics",
                            systemImage: "stethoscope"
                        )
                    }
                    .accessibilityIdentifier("settings.diagnostics")
                }

            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showAddAccount) {
                NativeLoginView(
                    model: model,
                    navigationTitle: "Add Account",
                    showsOfflineDownloads: false
                ) {
                    showAddAccount = false
                } onCancel: {
                    showAddAccount = false
                }
            }
            .sheet(item: $editingAccount) { account in
                AccountEditorView(
                    model: model,
                    account: account
                ) {
                    editingAccount = nil
                } onCancel: {
                    editingAccount = nil
                }
            }
            .confirmationDialog(
                "Turn Off iCloud Sync?",
                isPresented: $showDisableCloudSyncConfirmation,
                titleVisibility: .visible
            ) {
                Button("Keep Data in iCloud") {
                    Task {
                        await model.setPrivateCloudSyncEnabled(
                            false,
                            deleteCloudData: false
                        )
                    }
                }
                Button("Delete Data from iCloud", role: .destructive) {
                    Task {
                        await model.setPrivateCloudSyncEnabled(
                            false,
                            deleteCloudData: true
                        )
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Your statistics, accounts, preferences, and credentials remain on this device."
                )
            }
        }
    }

    private var cloudSection: some View {
        Section {
            Toggle(
                "Sync with iCloud",
                isOn: Binding(
                    get: {
                        model.privateCloudSyncEnabled
                    },
                    set: { enabled in
                        if enabled {
                            Task {
                                await model.setPrivateCloudSyncEnabled(true)
                            }
                        } else {
                            showDisableCloudSyncConfirmation = true
                        }
                    }
                )
            )
            .disabled(model.privateCloudState == .syncing)
            .accessibilityIdentifier("settings.icloud.enabled")

            Button(
                "Sync Now",
                systemImage: "arrow.triangle.2.circlepath"
            ) {
                Task {
                    await model.synchronizePrivateCloud()
                }
            }
            .disabled(
                !model.privateCloudSyncEnabled
                    || model.privateCloudState == .syncing
            )
            .accessibilityIdentifier("settings.icloud.syncNow")

            if case .failed(let failure) = model.privateCloudState {
                Text(failure.message)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("settings.icloud.error")
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text(
                "Syncs listening statistics, account details, preferences, and native usernames and passwords. Access and refresh tokens stay on this device."
            )
        }
    }

    private var downloadStorageText: String {
        ByteCountFormatter.string(
            fromByteCount: storedDownloadBytes(model.downloads.records),
            countStyle: .file
        )
    }

}

private struct DownloadsView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            DownloadStorageView(model: model)
        }
    }
}

private struct DownloadStorageView: View {
    @Bindable var model: AppModel
    @State private var showRemoveAllConfirmation = false

    var body: some View {
        Group {
            if model.downloads.records.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle"
                )
            } else {
                List {
                    storageSummary
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
        .confirmationDialog(
            "Remove Downloads?",
            isPresented: $showRemoveAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Downloads", role: .destructive) {
                Task {
                    await model.downloads.removeAll(
                        excluding: protectedDownloadID
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if protectedDownloadID == nil {
                Text(
                    "This removes all audiobook files stored on this device."
                )
            } else {
                Text(
                    "This removes every downloaded audiobook except the one currently playing."
                )
            }
        }
    }

    private var storageSummary: some View {
        Section("Storage") {
            LabeledContent(
                "Audiobooks",
                value: String(model.downloads.records.count)
            )
            LabeledContent("Stored", value: byteCount(totalStoredBytes))
            LabeledContent(
                "Available Offline",
                value: String(completeDownloadCount)
            )
            Button(
                protectedDownloadID == nil
                    ? "Remove All Downloads"
                    : "Remove Other Downloads",
                systemImage: "trash",
                role: .destructive
            ) {
                showRemoveAllConfirmation = true
            }
            .disabled(removableDownloadCount == 0)
            .accessibilityIdentifier("downloads.removeAll")
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

    private var totalStoredBytes: Int64 {
        storedDownloadBytes(model.downloads.records)
    }

    private var completeDownloadCount: Int {
        model.downloads.records.count {
            model.downloads.isFullBookAvailable($0)
        }
    }

    private var protectedDownloadID: DownloadID? {
        guard let accountID = model.playback.accountID,
            let itemID = model.playback.itemID
        else {
            return nil
        }
        return model.downloads.record(
            accountID: accountID,
            itemID: itemID
        )?.manifest.downloadID
    }

    private var removableDownloadCount: Int {
        model.downloads.records.count {
            $0.manifest.downloadID != protectedDownloadID
        }
    }

    @ViewBuilder
    private func downloadRow(_ record: DownloadedBookRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.detail.title)
                    .font(.headline)
                if record.manifest.purpose == .automaticCache {
                    Spacer()
                    Label("Automatic", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(
                value: model.downloads.progress[
                    record.manifest.downloadID
                ]
                    ?? (downloadIsComplete(record) ? 1 : 0)
            )
            HStack {
                Text(
                    model.downloads.pausedDownloadIDs.contains(
                        record.manifest.downloadID
                    )
                        ? "Paused"
                        : downloadStateLabel(record)
                )
                Spacer()

                Text(
                    "\(byteCount(model.downloads.downloadedByteLength(for: record))) of \(byteCount(model.downloads.expectedByteLength(for: record)))"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if record.manifest.downloadID == protectedDownloadID {
                Label("Playing", systemImage: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if record.manifest.purpose == .automaticCache,
                record.manifest.state != .deleting
            {
                if let account = model.account,
                    account.id == record.manifest.accountID

                {
                    if !model.downloads.isFullyDownloaded(for: record) {
                        Button("Download Full Book") {
                            Task {
                                await model.downloads.downloadFullBook(
                                    record,
                                    account: account
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if model.downloads.automaticCacheState(
                        for: record
                    ) == .failed {
                        Button("Retry") {
                            Task {
                                await model.downloads.repair(
                                    record,
                                    account: account
                                )
                            }
                        }
                    }
                } else {
                    Text("Account required to download the full book.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if downloadIsActive(record) {
                    transferControls(record)
                }
            } else if [
                DownloadManifestState.failed,
                .partial,
            ].contains(record.manifest.state) {
                if let account = model.account,
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
                    Text("Account required to retry this download.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !downloadIsComplete(record) {
                transferControls(record)
            }
        }
        .swipeActions {
            if record.manifest.downloadID != protectedDownloadID {
                Button("Delete", role: .destructive) {
                    Task {
                        await model.downloads.remove(record)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func transferControls(
        _ record: DownloadedBookRecord
    ) -> some View {
        @ColourSchemePreference var colourScheme

        HStack {
            if model.downloads.pausedDownloadIDs.contains(
                record.manifest.downloadID
            ) {
                Button("Resume") {
                    Task {
                        await model.downloads.resume(record)
                    }
                }.tint(colourScheme.color)
            } else {
                Button("Pause") {
                    Task {
                        await model.downloads.pause(record)
                    }
                }.tint(colourScheme.color)
            }
            Button("Cancel", role: .destructive) {
                Task {
                    await model.downloads.cancel(record)
                }
            }
        }
    }

    private func downloadStateLabel(
        _ record: DownloadedBookRecord
    ) -> String {
        if record.manifest.state == .deleting {
            return "Removing"
        }
        if let state = model.downloads.automaticCacheState(
            for: record
        ) {
            switch state {
            case .queued, .downloading:
                return "Caching"
            case .cached:
                return "Cached"
            case .failed:
                return "Cache failed"
            }
        }
        switch record.manifest.state {
        case .queued:
            return "Queued"
        case .downloading:
            return "Downloading"
        case .partial:
            return "Repair needed"
        case .complete:
            return "Downloaded"
        case .failed:
            return "Download failed"
        case .deleting:
            return "Removing"
        }
    }

    private func downloadIsComplete(
        _ record: DownloadedBookRecord
    ) -> Bool {
        if record.manifest.purpose == .automaticCache {
            return model.downloads.automaticCacheState(
                for: record
            ) == .cached
        }
        return model.downloads.isFullBookAvailable(record)
    }

    private func downloadIsActive(
        _ record: DownloadedBookRecord
    ) -> Bool {
        if record.manifest.purpose == .automaticCache {
            guard
                let state = model.downloads.automaticCacheState(
                    for: record
                )
            else {
                return false
            }
            return [
                AutomaticCacheState.queued,
                .downloading,
            ].contains(state)
        }
        return [
            DownloadManifestState.queued,
            .downloading,
        ].contains(record.manifest.state)
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
        storedDownloadBytes(records)
    }
}

private func storedDownloadBytes(
    _ records: [DownloadedBookRecord]
) -> Int64 {
    records.reduce(0) { total, record in
        let (sum, overflow) = total.addingReportingOverflow(
            record.manifest.storedByteLength
        )
        return overflow ? Int64.max : sum
    }
}
