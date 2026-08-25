import BleatCore
import Foundation

enum LocalPlaybackSessionStoreError: Error, Equatable {
    case corruptedData
    case persistenceFailed
}

private struct StoredLocalPlaybackSession: Codable, Equatable {
    let accountID: AccountID
    let session: LocalPlaybackSession
}

@MainActor
final class LocalPlaybackSessionStore {
    static let shared = LocalPlaybackSessionStore(defaults: .standard)

    private let defaults: UserDefaults
    private let storageKey = "bleat.localPlaybackSessions.v1"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func session(
        accountID: AccountID,
        itemID: LibraryItemID
    ) throws(LocalPlaybackSessionStoreError) -> LocalPlaybackSession? {
        try entries().first {
            $0.accountID == accountID
                && $0.session.libraryItemID == itemID
        }?.session
    }

    func pending(
        accountID: AccountID
    ) throws(LocalPlaybackSessionStoreError) -> [LocalPlaybackSession] {
        try entries()
            .filter { $0.accountID == accountID }
            .map(\.session)
            .sorted {
                $0.startedAtMilliseconds < $1.startedAtMilliseconds
            }
    }

    func save(
        _ session: LocalPlaybackSession,
        accountID: AccountID
    ) throws(LocalPlaybackSessionStoreError) {
        var stored = try entries()
        stored.removeAll {
            $0.accountID == accountID && $0.session.id == session.id
        }
        stored.append(
            StoredLocalPlaybackSession(
                accountID: accountID,
                session: session
            )
        )
        try persist(stored)
    }

    func removeAcknowledged(
        accountID: AccountID,
        sessionIDs: Set<PlaybackSessionID>
    ) throws(LocalPlaybackSessionStoreError) {
        guard !sessionIDs.isEmpty else {
            return
        }
        var stored = try entries()
        stored.removeAll {
            $0.accountID == accountID
                && sessionIDs.contains($0.session.id)
        }
        try persist(stored)
    }

    func removeAll(
        accountID: AccountID
    ) throws(LocalPlaybackSessionStoreError) {
        var stored = try entries()
        stored.removeAll { $0.accountID == accountID }
        try persist(stored)
    }

    func migrateAccountIdentity(
        from legacyID: AccountID,
        to canonicalID: AccountID
    ) throws(LocalPlaybackSessionStoreError) {
        let migrated = try entries().map {
            StoredLocalPlaybackSession(
                accountID: $0.accountID == legacyID
                    ? canonicalID : $0.accountID,
                session: $0.session
            )
        }
        try persist(migrated)
    }

    private func entries()
        throws(LocalPlaybackSessionStoreError)
        -> [StoredLocalPlaybackSession]
    {
        guard let data = defaults.data(forKey: storageKey) else {
            return []
        }
        do {
            return try JSONDecoder().decode(
                [StoredLocalPlaybackSession].self,
                from: data
            )
        } catch {
            throw .corruptedData
        }
    }

    private func persist(
        _ entries: [StoredLocalPlaybackSession]
    ) throws(LocalPlaybackSessionStoreError) {
        do {
            defaults.set(
                try JSONEncoder().encode(entries),
                forKey: storageKey
            )
        } catch {
            throw .persistenceFailed
        }
    }
}
