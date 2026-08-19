import BleatCore
import BleatTranscription
import Foundation
import SwiftUI

enum BookDetailPlaybackAction: Equatable {
    case start
    case resume
    case playAgain
    case pause

    static func decide(
        itemID: LibraryItemID,
        currentItemID: LibraryItemID?,
        isPlaybackRequested: Bool,
        progress: LibraryBookProgress?
    ) -> BookDetailPlaybackAction {
        if itemID == currentItemID, isPlaybackRequested {
            return .pause
        }

        guard let progress, progress.progress > 0 else {
            return .start
        }
        return progress.isFinished ? .playAgain : .resume
    }

    var label: String {
        switch self {
        case .start:
            "Start"
        case .resume:
            "Resume"
        case .playAgain:
            "Play Again"
        case .pause:
            "Pause"
        }
    }

    var systemImage: String {
        switch self {
        case .start, .resume, .playAgain:
            "play.fill"
        case .pause:
            "pause.fill"
        }
    }
}

struct RootView: View {
    @Bindable var model: AppModel
    @State private var navigation = AppNavigationCoordinator()
    @State private var deepLinkInbox = AppDeepLinkInbox.shared
    @State private var isShowingDiagnostics = false
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
                SignedInView(model: model, navigation: navigation)
                    .tint(colourScheme.color)
                    #if targetEnvironment(macCatalyst)
                        .id(colourScheme)
                    #endif
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
                    Button("Diagnostics") {
                        isShowingDiagnostics = true
                    }
                    .accessibilityIdentifier("app.diagnostics")
                }
                .tint(colourScheme.color)
            }
        }
        .task {
            model.setRemoteTelemetryForeground(scenePhase == .active)
            await model.start()
            if let route = deepLinkInbox.takePendingRoute() {
                navigation.receive(route: route)
            }
            await navigation.applyPendingRoute(model: model)
        }
        .onOpenURL { url in
            _ = deepLinkInbox.receive(url: url)
        }
        .onChange(of: deepLinkInbox.revision) { _, _ in
            guard let route = deepLinkInbox.takePendingRoute() else {
                return
            }
            navigation.receive(route: route)
            Task { await navigation.applyPendingRoute(model: model) }
        }
        .onChange(of: model.isNavigationReady) { _, ready in
            guard ready else { return }
            Task { await navigation.applyPendingRoute(model: model) }
        }
        .alert(
            "Cannot Open Link",
            isPresented: Binding(
                get: { navigation.deepLinkFailure != nil },
                set: { isPresented in
                    if !isPresented { navigation.deepLinkFailure = nil }
                }
            )
        ) {
            Button("OK") { navigation.deepLinkFailure = nil }
        } message: {
            if let failure = navigation.deepLinkFailure {
                Text(failure.message)
            }
        }
        .alert(
            "Use Server Settings from iCloud?",
            isPresented: Binding(
                get: {
                    !model.pendingCloudServerConfigurationChanges.isEmpty
                },
                set: { _ in }
            ),
            presenting: model.pendingCloudServerConfigurationChanges.first
        ) { change in
            Button("Use iCloud Settings") {
                Task {
                    await model.resolveCloudServerConfigurationChange(
                        change,
                        accept: true
                    )
                }
            }
            Button(
                change.current == nil ? "Don't Add" : "Keep This Device",
                role: .cancel
            ) {
                Task {
                    await model.resolveCloudServerConfigurationChange(
                        change,
                        accept: false
                    )
                }
            }
        } message: { change in
            Text(cloudServerConfigurationChangeMessage(change))
        }
        .sheet(isPresented: $isShowingDiagnostics) {
            NavigationStack {
                DiagnosticsView(model: model)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                isShowingDiagnostics = false
                            }
                        }
                    }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            model.setLiveUpdatesActive(phase == .active)
            model.setRemoteTelemetryForeground(phase == .active)
            if phase != .active {
                Task {
                    await model.synchronizePrivateCloud()
                }
            }
        }
    }

    private func cloudServerConfigurationChangeMessage(
        _ change: CloudServerConfigurationChange
    ) -> String {
        let incomingLocal = change.incoming.localServer?.url.absoluteString
            ?? "None"
        if let current = change.current {
            let currentLocal = current.localServer?.url.absoluteString
                ?? "None"
            return "This device uses primary \(current.server.url.absoluteString) and local \(currentLocal). iCloud returned primary \(change.incoming.server.url.absoluteString) and local \(incomingLocal)."
        }
        return "iCloud returned a saved account using primary \(change.incoming.server.url.absoluteString) and local \(incomingLocal)."
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
    var onSignedIn: () -> Void = {}
    var onCancel: (() -> Void)?
    @State private var serverAddress = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var invalidURLErrorMessage: String?
    @State private var autoLaunchedServer: String?

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

    private var discoveredServer: DiscoveredServer? {
        guard case .loaded(let server) = model.loginDiscovery else {
            return nil
        }
        return server
    }

    private var supportsLocalLogin: Bool {
        discoveredServer?.authenticationMethods.contains(.local) ?? true
    }

    private var supportsOpenIDLogin: Bool {
        discoveredServer?.authenticationMethods.contains(.openID) ?? false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField(
                        "Server URL",
                        text: $serverAddress
                    )
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Server URL")
                    .accessibilityIdentifier("login.server")

                    nearbyServers
                }

                if supportsLocalLogin {
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
                }

                if supportsOpenIDLogin {
                    Section {
                        Button(
                            discoveredServer?.authenticationFormData?
                                .openIDButtonText
                                ?? "Sign in with OpenID"
                        ) {
                            let submittedServerAddress = serverAddress
                            Task {
                                if await model.loginWithOpenID(
                                    serverAddress: submittedServerAddress
                                ) {
                                    onSignedIn()
                                }
                            }
                        }
                        .disabled(isSubmitting)
                        .accessibilityIdentifier("login.openid")
                    }
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
                        isDisabled: !canSubmit || !supportsLocalLogin,
                        accessibilityIdentifier: "login.submit",
                        action: submit
                    )
                }

                Section {
                    NavigationLink {
                        DiagnosticsView(model: model)
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                    .accessibilityIdentifier("login.diagnostics")
                }

            }
            #if targetEnvironment(macCatalyst)
                .safeAreaInset(edge: .top, spacing: 0) {
                    Text("Please log into a server")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 48)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("login.subtitle")
                }
            #endif
            .navigationTitle(navigationTitle)
            .task {
                model.startNearbyServerDiscovery()
            }
            .task(id: serverAddress) {
                try? await Task.sleep(for: .milliseconds(300))
                await model.discoverLoginServer(serverAddress)
            }
            .onChange(of: model.loginDiscovery) { _, state in
                guard case .loaded(let discovered) = state,
                    discovered.authenticationFormData?.openIDAutoLaunch == true,
                    autoLaunchedServer != discovered.baseURL.url.absoluteString
                else {
                    return
                }
                autoLaunchedServer = discovered.baseURL.url.absoluteString
                let submittedServerAddress = serverAddress
                Task {
                    if await model.loginWithOpenID(
                        serverAddress: submittedServerAddress
                    ) {
                        onSignedIn()
                    }
                }
            }
            .onDisappear {
                model.cancelNearbyServerDiscovery()
            }
            .onChange(of: model.nearbyServerDiscoveryState) {
                _, state in
                guard
                    serverAddress.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty,
                    case .results(let results) = state,
                    let first = results.first
                else {
                    return
                }
                serverAddress = first.server.baseURL.url.absoluteString
            }
            .toolbar {
                if let onCancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                }
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

    @ViewBuilder
    private var nearbyServers: some View {
        switch model.nearbyServerDiscoveryState {
        case .idle, .searching:
            HStack(spacing: 8) {
                ProgressView()
                Text("Looking for nearby servers")
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("login.nearby.searching")
        case .results(let results):
            ForEach(results) { result in
                Button {
                    serverAddress =
                        result.server.baseURL.url.absoluteString
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.name)
                                .foregroundStyle(.primary)
                            Text(
                                result.server.baseURL.url.absoluteString
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if serverAddress
                            == result.server.baseURL.url.absoluteString
                        {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .accessibilityLabel(
                    "Use \(result.name), \(result.server.baseURL.url.absoluteString)"
                )
                .accessibilityIdentifier("login.nearby.server")
            }
        case .noResults:
            VStack(alignment: .leading, spacing: 8) {
                Text("No nearby servers found")
                    .foregroundStyle(.secondary)
                retryDiscoveryButton
            }
            .accessibilityIdentifier("login.nearby.noResults")
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 8) {
                Text(failure.title)
                    .font(.headline)
                Text(failure.message)
                    .foregroundStyle(.secondary)
                retryDiscoveryButton
            }
            .accessibilityIdentifier("login.nearby.error")
        }
    }

    private var retryDiscoveryButton: some View {
        Button("Try Again") {
            model.startNearbyServerDiscovery()
        }
        .accessibilityIdentifier("login.nearby.retry")
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
                    if model.playback.showsMiniPlayer {
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

    private var currentAccount: ServerAccount {
        model.accounts.first(where: { $0.id == account.id }) ?? account
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Servers") {
                    TextField(
                        "Primary server URL",
                        text: $serverAddress
                    )
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("accountEditor.server")

                    TextField(
                        "Local server URL (optional)",
                        text: $localServerAddress
                    )
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("accountEditor.localServer")

                    if currentAccount.localServer != nil {
                        LabeledContent(
                            "Local server",
                            value: currentAccount.localServerValidated
                                ? "Validated" : "Not yet validated"
                        )
                    }
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

                if account.supportsOpenIDAuthentication,
                    model.account?.id == account.id
                {
                    Section {
                        Button("Sign in with OpenID") {
                            Task {
                                if await model.reauthenticateWithOpenID() {
                                    onSaved()
                                }
                            }
                        }
                        .disabled(isSubmitting)
                        .accessibilityIdentifier("accountEditor.openid")
                    }
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
        Button("Keep Listening History", role: .destructive) {
            removeAccount(statistics: .keep)
        }
        Button("Delete Listening History", role: .destructive) {
            removeAccount(statistics: .delete)
        }
    }

    private var removalDataMessage: String {
        "This removes the account and its downloaded books from this device. Choose whether to keep its listening history."
    }

    private func removeAccount(
        statistics statisticsDisposition: AccountStatisticsDisposition
    ) {
        guard let scope = pendingRemovalScope else {
            return
        }
        pendingRemovalScope = nil
        Task {
            if await model.removeAccount(
                account,
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
                    value: report.environment.appVersion
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

            Section("Network") {
                NavigationLink {
                    BonjourTroubleshooterView()
                } label: {
                    Label(
                        "Bonjour Troubleshooter",
                        systemImage: "bonjour"
                    )
                }
                .accessibilityIdentifier(
                    "diagnostics.bonjourTroubleshooter"
                )
            }

            RemoteTelemetryConsentSection(model: model)

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

                #if DEBUG
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
                #endif
            } footer: {
                Text(
                    "The snapshot includes server hostnames and ports. Exports exclude account names, URL paths and queries, credentials, tokens, response bodies, media titles and URLs, remote identifiers, session IDs, listening positions, and local file paths."
                )
            }
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
    @Bindable var navigation: AppNavigationCoordinator
    @State private var playbackFailure: AppFailure?
    @State private var bookActionPresentation =
        BookActionContextPresentation()

    var body: some View {
        GeometryReader { geometry in
            #if targetEnvironment(macCatalyst)
                VStack(spacing: 0) {
                    TopTabBar(selection: $navigation.selectedTab)
                    catalystTabs(containerHeight: geometry.size.height)
                        .tabViewStyle(.page(indexDisplayMode: .never))
                }
            #else
                mobileTabs(containerHeight: geometry.size.height)
            #endif
        }
        .sheet(isPresented: $navigation.showsPlayer) {
            NowPlaying(playback: model.playback)

        }
        .sheet(item: bookActionPresentation.requestBinding) { request in
            BookActionPreparationView(
                model: model,
                request: request,
                presentation: bookActionPresentation
            )
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
        .alert(
            playbackFailure?.title ?? "Playback unavailable",
            isPresented: Binding(
                get: { playbackFailure != nil },
                set: { if !$0 { playbackFailure = nil } }
            )
        ) {
            Button("OK") { playbackFailure = nil }
        } message: {
            if let playbackFailure {
                Text(playbackFailure.message)
            }
        }
        .accessibilityIdentifier("app.signedIn")
        .environment(bookActionPresentation)
        .onChange(of: model.account?.id) {
            bookActionPresentation.dismiss()
        }
    }

    #if targetEnvironment(macCatalyst)
        private func catalystTabs(containerHeight: CGFloat) -> some View {
            TabView(selection: $navigation.selectedTab) {
                Tab("Home", systemImage: "house", value: .home) {
                    tabContent(containerHeight: containerHeight) {
                        HomeView(
                            model: model,
                            navigation: navigation,
                            handlePlaybackOutcome: handlePlaybackOutcome
                        )
                    }
                }

                Tab("Library", systemImage: "books.vertical", value: .library) {
                    tabContent(containerHeight: containerHeight) {
                        LibraryView(
                            model: model,
                            navigation: navigation,
                            handlePlaybackOutcome: handlePlaybackOutcome
                        )
                    }
                }

                Tab(
                    "Downloads", systemImage: "arrow.down.circle",
                    value: .downloads
                ) {
                    tabContent(containerHeight: containerHeight) {
                        DownloadsView(model: model)
                    }
                }

                Tab("Settings", systemImage: "gearshape", value: .settings) {
                    tabContent(containerHeight: containerHeight) {
                        SettingsView(model: model, navigation: navigation)
                    }
                }

                Tab(
                    "Search", systemImage: "magnifyingglass", value: .search,
                    role: .search
                ) {
                    tabContent(containerHeight: containerHeight) {
                        SearchView(
                            model: model,
                            navigation: navigation,
                            handlePlaybackOutcome: handlePlaybackOutcome
                        )
                    }
                }
            }
        }
    #else
        private func mobileTabs(containerHeight: CGFloat) -> some View {
            TabView(selection: $navigation.selectedTab) {
                Tab(value: .home) {
                    tabContent(containerHeight: containerHeight) {
                        HomeView(
                            model: model,
                            navigation: navigation,
                            handlePlaybackOutcome: handlePlaybackOutcome
                        )
                    }
                } label: {
                    mobileTabLabel("Home", systemImage: "house")
                }

                Tab(value: .library) {
                    tabContent(containerHeight: containerHeight) {
                        LibraryView(
                            model: model,
                            navigation: navigation,
                            handlePlaybackOutcome: handlePlaybackOutcome
                        )
                    }
                } label: {
                    mobileTabLabel("Library", systemImage: "books.vertical")
                }

                Tab(value: .downloads) {
                    tabContent(containerHeight: containerHeight) {
                        DownloadsView(model: model)
                    }
                } label: {
                    mobileTabLabel(
                        "Downloads",
                        systemImage: "arrow.down.circle"
                    )
                }

                Tab(value: .settings) {
                    tabContent(containerHeight: containerHeight) {
                        SettingsView(model: model, navigation: navigation)
                    }
                } label: {
                    mobileTabLabel("Settings", systemImage: "gearshape")
                }

                Tab(value: .search, role: .search) {
                    tabContent(containerHeight: containerHeight) {
                        SearchView(
                            model: model,
                            navigation: navigation,
                            handlePlaybackOutcome: handlePlaybackOutcome
                        )
                    }
                } label: {
                    mobileTabLabel(
                        "Search",
                        systemImage: "magnifyingglass"
                    )
                }
            }
        }

        private func mobileTabLabel(
            _ title: String,
            systemImage: String
        ) -> some View {
            Label(title, systemImage: systemImage)
                .font(.caption2)
        }
    #endif

    private func tabContent<Content: View>(
        containerHeight: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.playback.showsMiniPlayer {
                    MiniPlayerView(
                        playback: model.playback,
                        containerHeight: containerHeight
                    ) {
                        navigation.showsPlayer = true
                    }
                }
            }
    }

    private func handlePlaybackOutcome(_ outcome: PlaybackStartOutcome) {
        guard let failure = outcome.presentationFailure else { return }
        playbackFailure = failure
    }
}

private struct TopTabBar: View {
    @Binding var selection: AppRootTab

    var body: some View {
        Group {
            if #available(iOS 26.0, macOS 26.0, *) {
                liquidGlassTabs
            } else {
                legacyTabs
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("app.tabBar")
    }

    @available(iOS 26.0, macOS 26.0, *)
    private var liquidGlassTabs: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 12) {
                ForEach(AppRootTab.macTabs, id: \.self) { tab in
                    Button {
                        selection = tab
                    } label: {
                        Label(tab.title, systemImage: tab.systemImage)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        selection == tab ? Color.accentColor : .primary
                    )
                    .glassEffect(
                        .regular
                            .tint(
                                selection == tab
                                    ? Color.accentColor.opacity(0.22) : nil
                            )
                            .interactive(),
                        in: Capsule()
                    )
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(
                        selection == tab ? .isSelected : []
                    )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var legacyTabs: some View {
        Picker("Navigation", selection: $selection) {
            ForEach(AppRootTab.macTabs, id: \.self) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

extension AppRootTab {
    fileprivate static let macTabs: [Self] = [
        .home,
        .library,
        .search,
        .downloads,
    ]

    fileprivate var systemImage: String {
        switch self {
        case .home: "house"
        case .library: "books.vertical"
        case .search: "magnifyingglass"
        case .downloads: "arrow.down.circle"
        case .settings: "gearshape"
        }
    }
}

private enum BookContextAction: Hashable {
    case markPlayed(Bool)
    case download
    case edit
    case transcribe
}

private extension BookActionAvailability {
    var canOpenEditor: Bool {
        visibleActions.contains(.editMetadata)
            || visibleActions.contains(.editCover)
            || visibleActions.contains(.deleteFromServer)
    }
}

@MainActor
@Observable
private final class BookActionContextPresentation {
    struct Request: Identifiable {
        let id = UUID()
        let account: ServerAccount
        let book: LibraryBookSummary
        let action: BookContextAction
    }

    var request: Request?

    var requestBinding: Binding<Request?> {
        Binding(
            get: { self.request },
            set: { self.request = $0 }
        )
    }

    func present(
        action: BookContextAction,
        account: ServerAccount,
        book: LibraryBookSummary
    ) {
        request = Request(account: account, book: book, action: action)
    }

    func dismiss() {
        request = nil
    }
}

private enum BookTranscriptionMenu {
    static var isAvailable: Bool {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains(
                "--ui-testing-transcription-unavailable"
            ) {
                return false
            }
            if ProcessInfo.processInfo.arguments.contains(
                "--ui-testing-transcription-available"
            ) {
                return true
            }
        #endif
        return SpeechTranscriptionCapability.isAvailable
    }

    static var title: String {
        isAvailable
            ? "Transcribe"
            : "Transcription unavailable on this device"
    }
}

private struct BookActionContextMenuModifier: ViewModifier {
    @Environment(BookActionContextPresentation.self) private var presentation
    @Bindable var model: AppModel
    let account: ServerAccount
    let book: LibraryBookSummary
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .contextMenu {
                    contextMenuContent
                }
        } else {
            content
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        let availability = BookActionAvailability(
            user: account.user,
            summary: book
        )
        if availability.access == .allowed {
            Button(
                model.isBookFinished(book.id)
                    ? "Mark Unplayed" : "Mark Played",
                systemImage: model.isBookFinished(book.id)
                    ? "arrow.uturn.backward.circle" : "checkmark.circle"
            ) {
                begin(.markPlayed(!model.isBookFinished(book.id)))
            }
            .accessibilityIdentifier(
                "book.context.\(book.id.rawValue).progress"
            )

            if availability.visibleActions.contains(.download),
                canStartDownload
            {
                Button("Download", systemImage: "arrow.down.circle") {
                    begin(.download)
                }
                .accessibilityIdentifier(
                    "book.context.\(book.id.rawValue).download"
                )
            }

            if availability.canOpenEditor {
                Button("Edit", systemImage: "pencil") {
                    begin(.edit)
                }
                .accessibilityIdentifier(
                    "book.context.\(book.id.rawValue).edit"
                )
            }

            #if os(iOS) && !targetEnvironment(macCatalyst)
                Button(
                    BookTranscriptionMenu.title,
                    systemImage: "waveform.badge.mic"
                ) {
                    begin(.transcribe)
                }
                .disabled(!BookTranscriptionMenu.isAvailable)
                .accessibilityIdentifier(
                    "book.context.\(book.id.rawValue).transcribe"
                )
            #endif
        }
    }

    private var canStartDownload: Bool {
        guard let record = model.downloads.record(
            accountID: account.id,
            itemID: book.id
        ) else {
            return true
        }
        return record.manifest.purpose == .automaticCache
    }

    private func begin(_ action: BookContextAction) {
        presentation.present(action: action, account: account, book: book)
    }
}

private struct BookActionPreparationView: View {
    @Bindable var model: AppModel
    let request: BookActionContextPresentation.Request
    @Bindable var presentation: BookActionContextPresentation

    @State private var preparedDetail: LibraryBookDetail?
    @State private var preparationFailure: AppFailure?
    @State private var isPreparing = true

    @ViewBuilder
    var body: some View {
        if let failure = preparationFailure {
            ContentUnavailableView {
                Label(failure.title, systemImage: failure.systemImage)
            } description: {
                Text(failure.message)
            } actions: {
                if failure.allowsRetry {
                    Button("Try Again") {
                        preparationFailure = nil
                        preparedDetail = nil
                        isPreparing = true
                    }
                    .accessibilityIdentifier(
                        "book.context.\(request.book.id.rawValue).retry"
                    )
                }
                Button("Cancel", role: .cancel) {
                    presentation.dismiss()
                }
            }
            .accessibilityIdentifier(
                "book.context.\(request.book.id.rawValue).error"
            )
        } else if isPreparing {
            ProgressView("Preparing \(request.book.title)")
                .accessibilityIdentifier(
                    "book.context.\(request.book.id.rawValue).loading"
                )
                .task(id: isPreparing) {
                    await prepareSelectedAction()
                }
        } else if let detail = preparedDetail {
            switch request.action {
            case .edit:
                MetadataEditorView(model: model, detail: detail) {
                    presentation.dismiss()
                    model.completeBookDeletion()
                }
            case .transcribe:
                #if os(iOS) && !targetEnvironment(macCatalyst)
                    ChapterTranscriptionView(
                        detail: detail,
                        account: request.account,
                        appModel: model,
                        downloads: model.downloads
                    )
                #else
                    EmptyView()
                #endif
            case .download, .markPlayed:
                EmptyView()
            }
        }
    }

    @MainActor
    private func prepareSelectedAction() async {
        switch await model.prepareBookAction(
            for: request.book,
            account: request.account
        ) {
        case .failed(let failure):
            preparationFailure = failure
            isPreparing = false
        case .loaded(let detail):
            let availability = BookActionAvailability(
                user: request.account.user,
                detail: detail
            )
            guard availability.access == .allowed else {
                preparationFailure = AppFailure(
                    operation(for: request.action),
                    failureCause(for: availability.access)
                )
                isPreparing = false
                return
            }
            switch request.action {
            case .markPlayed(let isFinished):
                await model.setFinished(isFinished, detail: detail)
                if case .failed(let failure) = model.bookProgressUpdateState {
                    preparationFailure = failure
                    isPreparing = false
                } else {
                    presentation.dismiss()
                }
            case .download:
                guard availability.visibleActions.contains(.download) else {
                    preparationFailure = AppFailure(
                        .download,
                        .permissionDenied
                    )
                    isPreparing = false
                    return
                }
                if let record = model.downloads.record(
                    accountID: request.account.id,
                    itemID: detail.id
                ) {
                    if record.manifest.purpose == .automaticCache {
                        await model.downloads.downloadFullBook(
                            record,
                            account: request.account
                        )
                    }
                } else {
                    await model.downloads.download(
                        detail: detail,
                        account: request.account
                    )
                }
                presentation.dismiss()
            case .edit:
                guard availability.canOpenEditor else {
                    preparationFailure = AppFailure(
                        .saveMetadata,
                        .permissionDenied
                    )
                    isPreparing = false
                    return
                }
                preparedDetail = detail
                isPreparing = false
            case .transcribe:
                guard BookTranscriptionMenu.isAvailable else {
                    presentation.dismiss()
                    return
                }
                preparedDetail = detail
                isPreparing = false
            }
        }
    }

    private func operation(
        for action: BookContextAction
    ) -> AppFailureOperation {
        switch action {
        case .markPlayed: .updateProgress
        case .download: .download
        case .edit: .saveMetadata
        case .transcribe: .loadBook
        }
    }

    private func failureCause(
        for access: LibraryItemAccessDecision
    ) -> AppFailureCause {
        switch access {
        case .allowed: .permissionDenied
        case .inaccessibleLibrary: .inaccessibleLibrary
        case .inaccessibleTags: .inaccessibleTags
        case .explicitContentDenied: .explicitContentDenied
        }
    }
}

private struct HomeView: View {
    @Bindable var model: AppModel
    @Bindable var navigation: AppNavigationCoordinator
    let handlePlaybackOutcome: (PlaybackStartOutcome) -> Void

    var body: some View {
        NavigationStack(path: navigation.pathBinding(for: .home)) {
            HomeContent(
                model: model,
                navigation: navigation,
                handlePlaybackOutcome: handlePlaybackOutcome
            )
            .safeAreaInset(edge: .top, spacing: 0) {
                homeContext
            }
            .navigationDestination(for: LibraryBookSummary.self) { book in
                BookDetailView(
                    model: model,
                    book: book,
                    navigation: navigation,
                    origin: .home
                )
            }
            .navigationDestination(for: SeriesDestination.self) { series in
                SeriesDetailView(
                    model: model,
                    destination: series,
                    navigation: navigation,
                    origin: .home,
                    handlePlaybackOutcome: handlePlaybackOutcome
                )
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
    @Bindable var navigation: AppNavigationCoordinator
    let handlePlaybackOutcome: (PlaybackStartOutcome) -> Void

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
                        VStack(spacing: 20) {
                            homeRefreshFailure
                            ContentUnavailableView(
                                "No personalized shelves",
                                systemImage: "books.vertical"
                            )
                            .accessibilityIdentifier("home.empty")
                        }
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
                homeRefreshFailure
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
        await model.refreshSelectedLibraryForPullToRefresh()
    }

    @ViewBuilder
    private var homeRefreshFailure: some View {
        if case .failed(let failure) = model.homeShelvesRefreshState {
            RefreshFailureBanner(
                failure: failure,
                accessibilityIdentifier: "home.refreshError"
            ) {
                Task {
                    await model.refreshSelectedLibrary()
                }
            }
            .padding(.horizontal)
        }
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
                        if let account = model.account {
                            ShelfBookCard(
                                model: model,
                                navigation: navigation,
                                account: account,
                                book: record.detail.summary,
                                navigationIdentifier:
                                    "home.downloaded.\(record.detail.id.rawValue)",
                                playbackIdentifier:
                                    "home.downloaded.\(record.detail.id.rawValue).play",
                                coverLoadPolicy: .cacheOnly,
                                handlePlaybackOutcome: handlePlaybackOutcome
                            )
                        }
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
                        if let account = model.account {
                            ShelfBookCard(
                                model: model,
                                navigation: navigation,
                                account: account,
                                book: book,
                                navigationIdentifier:
                                    "home.book.\(book.id.rawValue)",
                                playbackIdentifier:
                                    "home.book.\(book.id.rawValue).play",
                                handlePlaybackOutcome: handlePlaybackOutcome
                            )
                        }
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct ShelfBookCard: View {
    @Bindable var model: AppModel
    let navigation: AppNavigationCoordinator
    let account: ServerAccount
    let book: LibraryBookSummary
    let navigationIdentifier: String
    let playbackIdentifier: String
    var coverLoadPolicy: BookCoverLoadPolicy = .allowNetwork
    let handlePlaybackOutcome: (PlaybackStartOutcome) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button {
                navigation.showBook(book, from: .home)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Color.clear
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .accessibilityLabel("Open \(book.title)")
            .accessibilityIdentifier(navigationIdentifier)

            if book.collapsedSeries == nil {
                PlayableBookCoverView(
                    accountID: account.id,
                    server: account.server,
                    itemID: book.id,
                    updatedAtMilliseconds: book.updatedAtMilliseconds,
                    width: 360,
                    height: 360,
                    cornerRadius: 10,
                    loadPolicy: coverLoadPolicy,
                    title: book.title,
                    state: model.coverPlaybackState(
                        accountID: account.id,
                        itemID: book.id
                    ),
                    accessibilityIdentifier: playbackIdentifier,
                    performPlaybackAction: {
                        await model.performBrowsingPlaybackAction(
                            book: book,
                            account: account
                        )
                    },
                    handleOutcome: handlePlaybackOutcome
                )
                .frame(width: 148, height: 148)
            } else {
                BookCoverView(
                    accountID: account.id,
                    server: account.server,
                    itemID: book.id,
                    updatedAtMilliseconds: book.updatedAtMilliseconds,
                    width: 360,
                    height: 360,
                    cornerRadius: 10,
                    loadPolicy: coverLoadPolicy
                )
                .allowsHitTesting(false)
                .frame(width: 148, height: 148)
            }
        }
        .modifier(
            BookActionContextMenuModifier(
                model: model,
                account: account,
                book: book,
                isEnabled: book.collapsedSeries == nil
            )
        )
    }
}

private struct LibraryView: View {
    @Bindable var model: AppModel
    @Bindable var navigation: AppNavigationCoordinator
    let handlePlaybackOutcome: (PlaybackStartOutcome) -> Void

    var body: some View {
        NavigationStack(path: navigation.pathBinding(for: .library)) {
            VStack(spacing: 0) {
                libraryPicker
                libraryControls
                BookListContent(
                    model: model,
                    navigation: navigation,
                    origin: .library,
                    handlePlaybackOutcome: handlePlaybackOutcome
                )
            }
            .navigationTitle("Library")
        }
    }

    @ViewBuilder
    private var libraryControls: some View {
        if model.selectedLibrary != nil {
            VStack(spacing: 4) {
                if model.libraryBrowseFilter.isEntityScoped {
                    HStack(spacing: 8) {
                        Label(
                            model.libraryBrowseFilter.label,
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                        .font(.subheadline)
                        Spacer()
                        Button("Clear") {
                            Task {
                                await model.setLibraryBrowseFilter(.all)
                            }
                        }
                        .accessibilityIdentifier("library.activeFilter.clear")
                    }
                    .padding(.horizontal)
                    .padding(.top, 4)
                }
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
                            if model.libraryBrowseFilter == .all {
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
                                if model.libraryBrowseFilter
                                    == .progress(filter)
                                {
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
                            model.libraryBrowseFilter.label,
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                    }
                    .accessibilityIdentifier("library.filter")
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
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
        case .sequence:
            "Series Sequence"
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
    @Bindable var navigation: AppNavigationCoordinator
    let origin: AppRootTab
    let handlePlaybackOutcome: (PlaybackStartOutcome) -> Void

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
                        VStack(spacing: 20) {
                            libraryRefreshFailures
                            ContentUnavailableView(
                                "No audiobook libraries",
                                systemImage: "books.vertical"
                            )
                        }
                    }
                } else {
                    booksContent
                }
            }
        }
        .navigationDestination(for: LibraryBookSummary.self) { book in
            BookDetailView(
                model: model,
                book: book,
                navigation: navigation,
                origin: origin
            )
        }
        .navigationDestination(for: SeriesDestination.self) { series in
            SeriesDetailView(
                model: model,
                destination: series,
                navigation: navigation,
                origin: origin,
                handlePlaybackOutcome: handlePlaybackOutcome
            )
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
                    VStack(spacing: 20) {
                        libraryRefreshFailures
                        ContentUnavailableView(
                            "No audiobooks",
                            systemImage: "book.closed"
                        )
                    }
                }
            } else {
                List {
                    libraryRefreshFailures
                    ForEach(page.browseEntries, id: \.book.id.rawValue) {
                        entry in
                        switch entry {
                        case .book(let book):
                            if let account = model.account {
                                BookSummaryRow(
                                    model: model,
                                    navigation: navigation,
                                    book: book,
                                    account: account,
                                    origin: origin,
                                    navigationIdentifier:
                                        "library.book.\(book.id.rawValue)",
                                    navigationAccessibilityLabel:
                                        "Open \(book.title)",
                                    playbackIdentifier:
                                        "library.book.\(book.id.rawValue).play",
                                    handlePlaybackOutcome:
                                        handlePlaybackOutcome
                                )
                            }
                        case .series(let series, representative: let book):
                            NavigationLink(
                                value: SeriesDestination(
                                    libraryID: book.libraryID,
                                    id: series.id,
                                    name: series.name
                                )
                            ) {
                                SeriesSummaryRow(
                                    series: series,
                                    representative: book,
                                    accountID: model.account?.id,
                                    server: model.account?.server
                                )
                            }
                            .accessibilityIdentifier(
                                "library.series.\(series.id.rawValue)"
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
                    await model.refreshLibrariesForPullToRefresh()
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
            await model.refreshLibrariesForPullToRefresh()
        }
    }

    @ViewBuilder
    private var libraryRefreshFailures: some View {
        if case .failed(let failure) = model.librariesRefreshState {
            RefreshFailureBanner(
                failure: failure,
                accessibilityIdentifier: "library.refreshError"
            ) {
                Task {
                    await model.refreshLibraries()
                }
            }
        }
        if case .failed(let failure) = model.booksRefreshState {
            RefreshFailureBanner(
                failure: failure,
                accessibilityIdentifier: "books.refreshError"
            ) {
                Task {
                    await model.refreshSelectedLibrary()
                }
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

private struct RefreshFailureBanner: View {
    let failure: AppFailure
    let accessibilityIdentifier: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label(
                failure.message,
                systemImage: "wifi.exclamationmark"
            )
            .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Try Again", action: retry)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct SearchView: View {
    @Bindable var model: AppModel
    @Bindable var navigation: AppNavigationCoordinator
    let handlePlaybackOutcome: (PlaybackStartOutcome) -> Void
    @FocusState private var isSearchFocused: Bool

    private var taskContext: SearchTaskContext {
        SearchTaskContext(
            query: navigation.searchQuery,
            libraryID: model.selectedLibrary?.id
        )
    }

    var body: some View {
        NavigationStack(path: navigation.pathBinding(for: .search)) {
            content
                .navigationTitle("Search")
                .navigationDestination(for: LibraryBookSummary.self) { book in
                    BookDetailView(
                        model: model,
                        book: book,
                        navigation: navigation,
                        origin: .search
                    )
                }
                .navigationDestination(for: SeriesDestination.self) { series in
                    SeriesDetailView(
                        model: model,
                        destination: series,
                        navigation: navigation,
                        origin: .search,
                        handlePlaybackOutcome: handlePlaybackOutcome
                    )
                }
        }
        .searchable(
            text: $navigation.searchQuery,
            prompt: "Books, authors, or series"
        )
        .searchFocused($isSearchFocused)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSearchFocused {
                HStack {
                    Spacer()
                    Button("Done") {
                        isSearchFocused = false
                    }
                }
                .padding()
            }
        }
        .task(id: taskContext) {
            await model.search(query: navigation.searchQuery)
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
                ContentUnavailableView.search(text: navigation.searchQuery)
                    .accessibilityIdentifier("search.empty")
            } else {
                List {
                    if !results.books.isEmpty,
                        navigation.searchScope == .all
                            || navigation.searchScope == .book
                    {
                        Section("Books") {
                            ForEach(results.books, id: \.id) { book in
                                if let account = model.account {
                                    BookSummaryRow(
                                        model: model,
                                        navigation: navigation,
                                        book: book,
                                        account: account,
                                        origin: .search,
                                        navigationIdentifier:
                                            "search.book.\(book.id.rawValue)",
                                        navigationAccessibilityLabel:
                                            "Open \(book.title)",
                                        playbackIdentifier:
                                            "search.book.\(book.id.rawValue).play",
                                        handlePlaybackOutcome:
                                            handlePlaybackOutcome
                                    )
                                }
                            }
                        }
                    }
                    if !results.authors.isEmpty,
                        navigation.searchScope == .all
                            || navigation.searchScope == .author
                    {
                        Section("Authors") {
                            ForEach(results.authors, id: \.id) { author in
                                Button(author.name) {
                                    guard
                                        let libraryID = model.selectedLibrary?
                                            .id
                                    else {
                                        return
                                    }
                                    Task {
                                        await navigation.showAuthor(
                                            id: author.id,
                                            name: author.name,
                                            libraryID: libraryID,
                                            model: model
                                        )
                                    }
                                }
                                .accessibilityLabel(
                                    "Show books by \(author.name)"
                                )
                                .accessibilityIdentifier(
                                    "search.author.\(author.id.rawValue)"
                                )
                            }
                        }
                    }
                    if !results.series.isEmpty,
                        navigation.searchScope == .all
                            || navigation.searchScope == .series
                    {
                        Section("Series") {
                            ForEach(results.series, id: \.id) { series in
                                Button(series.name) {
                                    guard
                                        let libraryID = model.selectedLibrary?
                                            .id
                                    else {
                                        return
                                    }
                                    navigation.showSeries(
                                        id: series.id,
                                        name: series.name,
                                        libraryID: libraryID,
                                        from: .search
                                    )
                                }
                                .accessibilityLabel(
                                    "Open \(series.name) series"
                                )
                                .accessibilityIdentifier(
                                    "search.series.\(series.id.rawValue)"
                                )
                            }
                        }
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
    @Bindable var model: AppModel
    let navigation: AppNavigationCoordinator
    let book: LibraryBookSummary
    let account: ServerAccount
    let origin: AppRootTab
    let navigationIdentifier: String
    let navigationAccessibilityLabel: String
    let playbackIdentifier: String
    let handlePlaybackOutcome: (PlaybackStartOutcome) -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            Button {
                navigation.showBook(book, from: origin)
            } label: {
                HStack(spacing: 12) {
                    Color.clear
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading) {
                        Text(book.title)
                        if let author = book.authorName {
                            Text(author)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .accessibilityLabel(navigationAccessibilityLabel)
            .accessibilityIdentifier(navigationIdentifier)

            if book.collapsedSeries == nil {
                PlayableBookCoverView(
                    accountID: account.id,
                    server: account.server,
                    itemID: book.id,
                    updatedAtMilliseconds: book.updatedAtMilliseconds,
                    width: 128,
                    height: 128,
                    title: book.title,
                    state: model.coverPlaybackState(
                        accountID: account.id,
                        itemID: book.id
                    ),
                    accessibilityIdentifier: playbackIdentifier,
                    performPlaybackAction: {
                        await model.performBrowsingPlaybackAction(
                            book: book,
                            account: account
                        )
                    },
                    handleOutcome: handlePlaybackOutcome
                )
                .frame(width: 64, height: 64)
            } else {
                BookCoverView(
                    accountID: account.id,
                    server: account.server,
                    itemID: book.id,
                    updatedAtMilliseconds: book.updatedAtMilliseconds,
                    width: 128,
                    height: 128
                )
                .allowsHitTesting(false)
                .frame(width: 64, height: 64)
            }
        }
        .modifier(
            BookActionContextMenuModifier(
                model: model,
                account: account,
                book: book,
                isEnabled: book.collapsedSeries == nil
            )
        )
    }
}

private struct SeriesSummaryRow: View {
    let series: LibraryCollapsedSeries
    let representative: LibraryBookSummary
    let accountID: AccountID?
    let server: NormalizedServerURL?

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                BookCoverView(
                    accountID: accountID,
                    server: server,
                    itemID: representative.id,
                    updatedAtMilliseconds: representative.updatedAtMilliseconds,
                    width: 128,
                    height: 128
                )
                .frame(width: 64, height: 64)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.secondary.opacity(0.35), lineWidth: 1)
                )
                Image(systemName: "books.vertical.fill")
                    .font(.caption)
                    .padding(4)
                    .background(.thinMaterial, in: Circle())
                    .offset(x: 4, y: 4)
            }
            VStack(alignment: .leading) {
                Text(series.name)
                Text("\(series.numBooks) books")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(series.name), series, \(series.numBooks) books"
        )
    }
}

private struct SeriesDetailView: View {
    @Bindable var model: AppModel
    let destination: SeriesDestination
    @Bindable var navigation: AppNavigationCoordinator
    let origin: AppRootTab
    let handlePlaybackOutcome: (PlaybackStartOutcome) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var coverSwipeOffset: CGFloat = 0

    var body: some View {
        content
            .navigationTitle(destination.name)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: destination) {
                await model.loadSeries(destination)
            }
            .refreshable {
                await model.refreshSeries(destination)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.seriesBooks {
        case .idle, .loading:
            ProgressView()
                .accessibilityIdentifier("series.loading")
        case .failed(let failure):
            ContentUnavailableView {
                Label(failure.title, systemImage: failure.systemImage)
            } description: {
                Text(failure.message)
            } actions: {
                if failure.allowsRetry {
                    Button("Try Again") {
                        Task { await model.loadSeries(destination) }
                    }
                }
            }
            .accessibilityIdentifier("series.error")
        case .loaded(let page):
            List {
                if !page.items.isEmpty {
                    Section {
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 0) {
                                ForEach(page.items, id: \.id) { book in
                                    Group {
                                        if let account = model.account {
                                            SeriesCarouselBookCard(
                                                model: model,
                                                navigation: navigation,
                                                account: account,
                                                book: book,
                                                origin: origin,
                                                sequenceLabel:
                                                    sequenceLabel(for: book),
                                                handlePlaybackOutcome:
                                                    handlePlaybackOutcome
                                            )
                                            .rotation3DEffect(
                                                .degrees(coverDepthAngle),
                                                axis: (x: 0, y: 1, z: 0)
                                            )
                                        }
                                    }
                                    .containerRelativeFrame(.horizontal)
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.paging)
                        .scrollIndicators(.hidden)
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { value in
                                    guard !shouldReduceMotion else { return }
                                    coverSwipeOffset = value.translation.width
                                }
                                .onEnded { _ in
                                    coverSwipeOffset = 0
                                }
                        )
                        .frame(height: 270)
                        .accessibilityIdentifier(
                            shouldReduceMotion
                                ? "series.coverBrowser.reducedMotion"
                                : "series.coverBrowser.depthMotion"
                        )
                    }
                    .listRowInsets(EdgeInsets())

                    Section("Books") {
                        ForEach(page.items.indices, id: \.self) { index in
                            let book = page.items[index]
                            if let account = model.account {
                                BookSummaryRow(
                                    model: model,
                                    navigation: navigation,
                                    book: book,
                                    account: account,
                                    origin: origin,
                                    navigationIdentifier:
                                        "series.book.\(index)",
                                    navigationAccessibilityLabel:
                                        "Open \(book.title), \(sequenceLabel(for: book))",
                                    playbackIdentifier:
                                        "series.book.\(book.id.rawValue).play",
                                    handlePlaybackOutcome:
                                        handlePlaybackOutcome
                                )
                            }
                        }
                    }
                }
                if page.hasNextPage {
                    seriesLoadMore
                }
            }
            .accessibilityIdentifier("series.results")
        }
    }

    @ViewBuilder
    private var seriesLoadMore: some View {
        switch model.seriesPaginationState {
        case .idle:
            Button("Load More") {
                Task { await model.loadNextSeriesPage() }
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("series.loadMore")
        case .loading:
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
        case .failed:
            Button("Try Again") {
                Task { await model.loadNextSeriesPage() }
            }
        }
    }

    private func sequenceLabel(for book: LibraryBookSummary) -> String {
        guard
            let series = book.series.first(where: {
                $0.id == destination.id
            })
        else {
            return "Unnumbered"
        }
        guard let sequence = series.sequence, !sequence.isEmpty else {
            return "Unnumbered"
        }
        return "Book \(sequence)"
    }

    private var coverDepthAngle: Double {
        SeriesCoverMotion.depthAngle(
            swipeOffset: coverSwipeOffset,
            reduceMotion: shouldReduceMotion
        )
    }

    private var shouldReduceMotion: Bool {
        #if DEBUG
            reduceMotion
                || ProcessInfo.processInfo.arguments.contains(
                    "--ui-testing-reduce-motion"
                )
        #else
            reduceMotion
        #endif
    }
}

private struct SeriesCarouselBookCard: View {
    @Bindable var model: AppModel
    let navigation: AppNavigationCoordinator
    let account: ServerAccount
    let book: LibraryBookSummary
    let origin: AppRootTab
    let sequenceLabel: String
    let handlePlaybackOutcome: (PlaybackStartOutcome) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Button {
                navigation.showBook(book, from: origin)
            } label: {
                VStack(spacing: 8) {
                    Color.clear
                        .frame(width: 180, height: 180)
                    Text(book.title)
                        .font(.headline)
                    Text(sequenceLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .accessibilityLabel("Open \(book.title), \(sequenceLabel)")
            .accessibilityIdentifier(
                "series.carousel.\(book.id.rawValue)"
            )

            if book.collapsedSeries == nil {
                PlayableBookCoverView(
                    accountID: account.id,
                    server: account.server,
                    itemID: book.id,
                    updatedAtMilliseconds: book.updatedAtMilliseconds,
                    width: 480,
                    height: 480,
                    cornerRadius: 14,
                    title: book.title,
                    state: model.coverPlaybackState(
                        accountID: account.id,
                        itemID: book.id
                    ),
                    accessibilityIdentifier:
                        "series.carousel.\(book.id.rawValue).play",
                    performPlaybackAction: {
                        await model.performBrowsingPlaybackAction(
                            book: book,
                            account: account
                        )
                    },
                    handleOutcome: handlePlaybackOutcome
                )
                .frame(width: 180, height: 180)
            } else {
                BookCoverView(
                    accountID: account.id,
                    server: account.server,
                    itemID: book.id,
                    updatedAtMilliseconds: book.updatedAtMilliseconds,
                    width: 480,
                    height: 480,
                    cornerRadius: 14
                )
                .allowsHitTesting(false)
                .frame(width: 180, height: 180)
            }
        }
        .modifier(
            BookActionContextMenuModifier(
                model: model,
                account: account,
                book: book,
                isEnabled: book.collapsedSeries == nil
            )
        )
    }
}

private struct BookDetailView: View {
    @Bindable var model: AppModel
    let book: LibraryBookSummary
    @Bindable var navigation: AppNavigationCoordinator
    let origin: AppRootTab
    @Environment(\.dismiss) private var dismiss
    @State private var showMetadataEditor = false
    @State private var showChapterTranscription = false
    @State private var showRemoveDownloadConfirmation = false
    @State private var playbackFailure: AppFailure?

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
                if canShowActionsMenu(detail) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if canOpenEditor(detail) {
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
                                .disabled(
                                    model.bookProgressUpdateState == .saving
                                )
                                .accessibilityIdentifier(
                                    "book.detail.finished"
                                )
                            }

                            #if os(iOS) && !targetEnvironment(macCatalyst)
                                Button(
                                    transcriptionMenuTitle,
                                    systemImage: "waveform.badge.mic"
                                ) {
                                    showChapterTranscription = true
                                }
                                .disabled(!transcriptionMenuIsAvailable)
                                .accessibilityIdentifier(
                                    "book.detail.transcription"
                                )
                            #endif
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
        #if os(iOS) && !targetEnvironment(macCatalyst)
            .sheet(isPresented: $showChapterTranscription) {
                if let detail = loadedDetail,
                    let account = model.account
                {
                    ChapterTranscriptionView(
                        detail: detail,
                        account: account,
                        appModel: model,
                        downloads: model.downloads
                    )
                }
            }
        #endif
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
        .alert(
            playbackFailure?.title ?? "Playback unavailable",
            isPresented: Binding(
                get: { playbackFailure != nil },
                set: { if !$0 { playbackFailure = nil } }
            )
        ) {
            Button("OK") { playbackFailure = nil }
        } message: {
            if let playbackFailure {
                Text(playbackFailure.message)
            }
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
        return BookActionAvailability(
            user: user,
            detail: detail
        ).canOpenEditor
    }

    private func canShowActionsMenu(_ detail: LibraryBookDetail) -> Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
            true
        #else
            canOpenEditor(detail)
        #endif
    }

    private var transcriptionMenuIsAvailable: Bool {
        BookTranscriptionMenu.isAvailable
    }

    private var transcriptionMenuTitle: String {
        transcriptionMenuIsAvailable
            ? "Transcribe Audiobook"
            : "Transcription unavailable on this device"
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
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(
                                Array(detail.authors.enumerated()),
                                id: \.offset
                            ) { index, author in
                                Button {
                                    Task {
                                        await navigation.showAuthor(
                                            id: author.id,
                                            name: author.name,
                                            libraryID: detail.libraryID,
                                            model: model
                                        )
                                    }
                                } label: {
                                    Text(author.name)
                                        .underline()
                                        .frame(
                                            maxWidth: .infinity,
                                            minHeight: 44,
                                            alignment: .leading
                                        )
                                }
                                .buttonStyle(.plain)
                                .font(.headline)
                                .accessibilityLabel(
                                    "Show books by \(author.name)"
                                )
                                .accessibilityIdentifier(
                                    "book.detail.author.\(index)"
                                )
                            }
                        }
                    }
                    if !detail.series.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(
                                Array(detail.series.enumerated()),
                                id: \.offset
                            ) { index, series in
                                Button {
                                    navigation.showSeries(
                                        id: series.id,
                                        name: series.name,
                                        libraryID: detail.libraryID,
                                        from: origin
                                    )
                                } label: {
                                    Text(seriesLinkLabel(series))
                                        .underline()
                                        .frame(
                                            maxWidth: .infinity,
                                            minHeight: 44,
                                            alignment: .leading
                                        )
                                }
                                .buttonStyle(.plain)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(
                                    series.sequence.map {
                                        "Open \(series.name) series, book \($0)"
                                    } ?? "Open \(series.name) series"
                                )
                                .accessibilityIdentifier(
                                    "book.detail.series.\(index)"
                                )
                            }
                        }
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
                    currentItemID:
                        model.playback.accountID == model.account?.id
                        ? model.playback.itemID : nil,
                    isPlaybackRequested:
                        model.playback.isPlaybackRequested,
                    progress: detail.progress
                )
                if availability.visibleActions.contains(.play),
                    let account = model.account
                {
                    Button {
                        switch primaryAction {
                        case .pause:
                            model.playback.pause()
                        case .start, .resume:
                            Task {
                                let outcome = await model.startPlayback(
                                    detail: detail,
                                    account: account
                                )
                                if case .failed(let failure) = outcome {
                                    playbackFailure = failure
                                }
                            }
                        case .playAgain:
                            Task {
                                let outcome = await model.startPlayback(
                                    detail: detail,
                                    account: account,
                                    position: .beginning
                                )
                                if case .failed(let failure) = outcome {
                                    playbackFailure = failure
                                }
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
                            && model.playback.accountID == account.id
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
                            HStack(alignment: .top, spacing: 8) {
                                Image(
                                    systemName: downloadStatusIcon(record)
                                )
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(downloadStatus(record))
                                    Text(downloadBytes(record))
                                        .foregroundStyle(.secondary)
                                }
                                .fixedSize(horizontal: true, vertical: false)
                                Spacer()
                            }
                            .font(.subheadline)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier(
                                "book.detail.downloadStatus"
                            )

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
        DownloadByteProgressFormatter.string(
            downloadedBytes: model.downloads.downloadedByteLength(
                for: record
            ),
            expectedBytes: model.downloads.expectedByteLength(for: record)
        )
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

    private func seriesLinkLabel(_ series: LibraryBookSeries) -> String {
        guard let sequence = series.sequence, !sequence.isEmpty else {
            return series.name
        }
        return "\(series.name) #\(sequence)"
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

private struct RemoteTelemetryConsentSection: View {
    @Bindable var model: AppModel

    var body: some View {
        Section {
            Toggle(
                "Share diagnostic telemetry",
                isOn: Binding(
                    get: {
                        model.remoteTelemetryEnabled
                    },
                    set: { enabled in
                        model.setRemoteTelemetryEnabled(enabled)
                    }
                )
            )
            .accessibilityIdentifier("diagnostics.telemetry.enabled")
        } header: {
            Text("Privacy")
        } footer: {
            Text(
                "Shares bounded technical diagnostics such as app and operating-system versions, operation outcomes, and timing. Audiobook content, credentials, accounts, servers, searches, transcripts, and device identifiers are excluded. You can turn this off at any time without affecting local Diagnostics."
            )
            .accessibilityIdentifier("diagnostics.telemetry.explanation")
        }
    }
}

private struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var navigation: AppNavigationCoordinator
    @State private var showAddAccount = false
    @State private var editingAccount: ServerAccount?
    @State private var showDisableCloudSyncConfirmation = false

    @ColourSchemePreference private var colourScheme

    var body: some View {
        NavigationStack(path: navigation.pathBinding(for: .settings)) {
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
                    Button("Add Account", systemImage: "plus.app") {
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
                    .tint(colourScheme.color)
                }

                Section("Downloads") {
                    if DownloadModel.supportsNetworkPolicySelection {
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
                    Picker(
                        "Previous Command",
                        selection: Binding(
                            get: {
                                model.playback.previousCommandAction
                            },
                            set: { value in
                                model.playback.setPreviousCommandAction(value)
                            }
                        )
                    ) {
                        ForEach(HeadphoneCommandAction.allCases) { action in
                            Text(action.label).tag(action)
                        }
                    }
                    .accessibilityIdentifier(
                        "settings.playback.previousCommand"
                    )

                    Picker(
                        "Next Command",
                        selection: Binding(
                            get: {
                                model.playback.nextCommandAction
                            },
                            set: { value in
                                model.playback.setNextCommandAction(value)
                            }
                        )
                    ) {
                        ForEach(HeadphoneCommandAction.allCases) { action in
                            Text(action.label).tag(action)
                        }
                    }
                    .accessibilityIdentifier(
                        "settings.playback.nextCommand"
                    )
                } header: {
                    Text("Headphone Controls")
                } footer: {
                    Text(
                        "AirPods send Previous and Next commands. Bleat cannot identify which AirPod or tap count sent them."
                    )
                }

                Section {
                    settingsDestinationLink(
                        "Listening Stats",
                        systemImage: "chart.bar",
                        destination: .statistics,
                        accessibilityIdentifier: "settings.statistics"
                    )
                    settingsDestinationLink(
                        "About",
                        systemImage: "info.circle",
                        destination: .about,
                        accessibilityIdentifier: "settings.about"
                    )
                    settingsDestinationLink(
                        "Diagnostics",
                        systemImage: "stethoscope",
                        destination: .diagnostics,
                        accessibilityIdentifier: "settings.diagnostics"
                    )
                }

            }
            .navigationTitle("Settings")
            .navigationDestination(for: DeepLinkSettingsDestination.self) {
                destination in
                switch destination {
                case .root:
                    EmptyView()
                case .diagnostics:
                    DiagnosticsView(model: model)
                case .statistics:
                    StatisticsView(model: model)
                case .about:
                    AboutView()
                }
            }
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

    private func settingsDestinationLink(
        _ title: String,
        systemImage: String,
        destination: DeepLinkSettingsDestination,
        accessibilityIdentifier: String
    ) -> some View {
        NavigationLink(value: destination) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(colourScheme.color)
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
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
            .disabled(
                model.privateCloudState == .syncing
                    || model.privateCloudState == .cancelling
            )
            .accessibilityIdentifier("settings.icloud.enabled")

            if model.canCancelPrivateCloudSynchronization {
                Button(
                    "Cancel Sync",
                    systemImage: "xmark.circle",
                    role: .destructive
                ) {
                    Task {
                        await model.cancelPrivateCloudSynchronization()
                    }
                }
                .accessibilityIdentifier("settings.icloud.cancel")
            } else if model.privateCloudState == .cancelling {
                ProgressView("Cancelling…")
                    .accessibilityIdentifier("settings.icloud.cancelling")
            } else {
                Button(
                    model.privateCloudState == .cancelled
                        ? "Retry Sync" : "Sync Now",
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
            }

            if model.privateCloudState == .cancelled {
                Text("iCloud synchronization was cancelled.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.icloud.cancelled")
            }

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

enum DownloadByteProgressFormatter {
    private struct Unit {
        let byteCount: Double
        let symbol: String
    }

    static func string(
        downloadedBytes: Int64,
        expectedBytes: Int64
    ) -> String {
        let expectedBytes = max(expectedBytes, 0)
        let unit = unit(for: expectedBytes)
        let downloaded = formattedValue(
            bytes: max(downloadedBytes, 0),
            unit: unit
        )
        let expected = formattedValue(bytes: expectedBytes, unit: unit)
        return "\(downloaded)/\(expected) \(unit.symbol)"
    }

    private static func unit(for expectedBytes: Int64) -> Unit {
        switch expectedBytes {
        case 1_000_000_000_000...:
            Unit(byteCount: 1_000_000_000_000, symbol: "TB")
        case 1_000_000_000...:
            Unit(byteCount: 1_000_000_000, symbol: "GB")
        case 1_000_000...:
            Unit(byteCount: 1_000_000, symbol: "MB")
        case 1_000...:
            Unit(byteCount: 1_000, symbol: "KB")
        default:
            Unit(byteCount: 1, symbol: "bytes")
        }
    }

    private static func formattedValue(bytes: Int64, unit: Unit) -> String {
        let value = Double(bytes) / unit.byteCount
        if value < 10, abs(value - value.rounded()) >= 0.05 {
            return value.formatted(
                .number.precision(.fractionLength(1))
            )
        }
        return value.formatted(.number.precision(.fractionLength(0)))
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
