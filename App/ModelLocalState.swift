import Foundation

/// Constructor-owned state for the dedicated macOS unit-test configuration.
/// Explicit stores supplied by restoration tests always retain their identity.
@MainActor
final class ModelLocalState {
    let defaults: UserDefaults
    let downloadsRoot: URL?
    private let suite: String?

    init() {
        #if BLEAT_MACOS_TESTING
            let suite = "BleatMacTests.\(UUID().uuidString)"
            self.suite = suite
            defaults = UserDefaults(suiteName: suite) ?? UserDefaults()
            let root = MacTestStorage.root
            downloadsRoot =
                root
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        #else
            suite = nil
            defaults = .standard
            downloadsRoot = nil
        #endif
    }

    isolated deinit {
        if let suite { defaults.removePersistentDomain(forName: suite) }
    }

    func positionStore() -> PlaybackPositionStore {
        #if BLEAT_MACOS_TESTING
            PlaybackPositionStore(defaults: defaults)
        #else
            .shared
        #endif
    }

    func sessionStore() -> LocalPlaybackSessionStore {
        #if BLEAT_MACOS_TESTING
            LocalPlaybackSessionStore(defaults: defaults)
        #else
            .shared
        #endif
    }

    func bookmarkStore() -> BookmarkMutationStore {
        #if BLEAT_MACOS_TESTING
            BookmarkMutationStore(defaults: defaults)
        #else
            .shared
        #endif
    }

    func preferencesStore() -> PlaybackPreferencesStore {
        #if BLEAT_MACOS_TESTING
            PlaybackPreferencesStore(defaults: defaults)
        #else
            .shared
        #endif
    }

    static var registersRemoteCommands: Bool {
        #if BLEAT_MACOS_TESTING
            false
        #else
            true
        #endif
    }
}

#if BLEAT_MACOS_TESTING
    enum MacTestStorage {
        static let root: URL =
            ProcessInfo.processInfo.environment["BLEAT_MACOS_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatMacTests-\(UUID().uuidString)", isDirectory: true)
    }
#endif
