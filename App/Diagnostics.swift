import BleatCore
import Foundation
import UIKit

struct DiagnosticsEnvironment: Equatable, Sendable {
    let appVersion: String
    let appBuild: String
    let operatingSystem: String

    @MainActor
    static var current: DiagnosticsEnvironment {
        let bundle = Bundle.main
        let device = UIDevice.current
        return DiagnosticsEnvironment(
            appVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "Unknown",
            appBuild: bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "Unknown",
            operatingSystem: "\(device.systemName) \(device.systemVersion)"
        )
    }
}

struct DiagnosticsReport: Equatable, Sendable {
    let generatedAt: Date
    let environment: DiagnosticsEnvironment
    let appState: String
    let accountCount: Int
    let serverVersion: String?
    let connectionState: String?
    let libraryState: String
    let homeState: String
    let searchState: String
    let playbackState: String
    let playbackSyncState: String
    let downloadCount: Int
    let errorCodes: [String]

    var text: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        let errors =
            errorCodes.isEmpty
            ? "None"
            : errorCodes.joined(separator: ", ")
        return """
            Bleat Diagnostics
            Generated: \(formatter.string(from: generatedAt))
            App: \(environment.appVersion) (\(environment.appBuild))
            Operating system: \(environment.operatingSystem)
            App state: \(appState)
            Saved accounts: \(accountCount)
            Server version: \(serverVersion ?? "Unavailable")
            Connection state: \(connectionState ?? "No active account")
            Libraries: \(libraryState)
            Home: \(homeState)
            Search: \(searchState)
            Playback: \(playbackState)
            Playback sync: \(playbackSyncState)
            Downloads: \(downloadCount)
            Active error codes: \(errors)

            Privacy: This report excludes credentials, cookies, tokens, server \
            addresses, usernames, response bodies, media URLs, playback \
            session IDs, and local file paths.
            """
    }
}

extension AppModel {
    func diagnosticsReport(
        generatedAt: Date = Date(),
        environment: DiagnosticsEnvironment = .current
    ) -> DiagnosticsReport {
        DiagnosticsReport(
            generatedAt: generatedAt,
            environment: environment,
            appState: phase.diagnosticsLabel,
            accountCount: accounts.count,
            serverVersion: account?.serverVersion,
            connectionState: account?.connectionState.diagnosticsLabel,
            libraryState: libraries.diagnosticsLabel,
            homeState: homeShelves.diagnosticsLabel,
            searchState: searchResults.diagnosticsLabel,
            playbackState: playback.state.diagnosticsLabel,
            playbackSyncState: playback.syncState.diagnosticsLabel,
            downloadCount: downloads.records.count,
            errorCodes: activeDiagnosticsErrors
        )
    }

    private var activeDiagnosticsErrors: [String] {
        var errors: [AppFailure] = []
        if case .unavailable(let failure) = phase {
            errors.append(failure)
        }
        if case .failed(let failure) = loginStatus {
            errors.append(failure)
        }
        if case .failed(let failure) = accountActionStatus {
            errors.append(failure)
        }
        errors.append(
            contentsOf: [
                libraries.failure,
                homeShelves.failure,
                searchResults.failure,
                bookDetail.failure,
                playback.state.failure,
                bookmarkFailure,
            ].compactMap(\.self))
        return Array(Set(errors.map(\.diagnosticsCode))).sorted()
    }

    private var bookmarkFailure: AppFailure? {
        if case .failed(let failure) = playback.bookmarkState {
            return failure
        }
        return nil
    }
}

extension AppPhase {
    fileprivate var diagnosticsLabel: String {
        switch self {
        case .launching:
            "Launching"
        case .signedOut:
            "Signed out"
        case .signedIn:
            "Signed in"
        case .unavailable:
            "Unavailable"
        }
    }
}

extension ResourceState {
    fileprivate var diagnosticsLabel: String {
        switch self {
        case .idle:
            "Idle"
        case .loading:
            "Loading"
        case .loaded:
            "Loaded"
        case .failed:
            "Failed"
        }
    }

    fileprivate var failure: AppFailure? {
        if case .failed(let failure) = self {
            return failure
        }
        return nil
    }
}

extension AccountConnectionState {
    fileprivate var diagnosticsLabel: String {
        switch self {
        case .connected:
            "Connected"
        case .offline:
            "Offline"
        case .reauthenticationRequired:
            "Reauthentication required"
        }
    }
}

extension PlaybackState {
    fileprivate var diagnosticsLabel: String {
        switch self {
        case .idle:
            "Idle"
        case .preparing:
            "Preparing"
        case .ready:
            "Ready"
        case .playing:
            "Playing"
        case .paused:
            "Paused"
        case .ended:
            "Ended"
        case .failed:
            "Failed"
        }
    }

    fileprivate var failure: AppFailure? {
        if case .failed(let failure) = self {
            return failure
        }
        return nil
    }
}

extension PlaybackSyncState {
    fileprivate var diagnosticsLabel: String {
        switch self {
        case .idle:
            "Idle"
        case .syncing:
            "Syncing"
        case .failed:
            "Failed"
        }
    }
}

extension AppFailure {
    fileprivate var diagnosticsCode: String {
        switch self {
        case .persistenceUnavailable:
            "persistence_unavailable"
        case .invalidServerAddress:
            "invalid_server_address"
        case .serverUnavailable:
            "server_unavailable"
        case .serverRequiresHTTPS:
            "server_requires_https"
        case .serverNotReady:
            "server_not_ready"
        case .serverUnsupported:
            "server_unsupported"
        case .localLoginUnavailable:
            "local_login_unavailable"
        case .invalidCredentials:
            "invalid_credentials"
        case .loginFailed:
            "login_failed"
        case .accountUnavailable:
            "account_unavailable"
        case .libraryUnavailable:
            "library_unavailable"
        case .homeUnavailable:
            "home_unavailable"
        case .searchUnavailable:
            "search_unavailable"
        case .bookUnavailable:
            "book_unavailable"
        case .playbackDenied:
            "playback_denied"
        case .playbackUnavailable:
            "playback_unavailable"
        case .progressUnavailable:
            "progress_unavailable"
        case .mediaUnavailable:
            "media_unavailable"
        case .invalidMetadata:
            "invalid_metadata"
        case .metadataUnavailable:
            "metadata_unavailable"
        case .bookmarkUnavailable:
            "bookmark_unavailable"
        case .accountRemovalFailed:
            "account_removal_failed"
        }
    }
}
