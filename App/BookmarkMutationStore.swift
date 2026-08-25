import BleatCore
import Foundation

enum QueuedBookmarkMutationKind: String, Codable, Equatable, Sendable {
    case create
    case rename
    case delete
}

enum QueuedBookmarkMutationStatus: String, Codable, Equatable, Sendable {
    case pending
    case failed
}

struct QueuedBookmarkMutation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let accountID: AccountID
    let itemID: LibraryItemID
    let time: Double
    let title: String?
    let createdAtMilliseconds: Int64
    let kind: QueuedBookmarkMutationKind
    var status: QueuedBookmarkMutationStatus

    var bookmark: AudioBookmark? {
        guard let title, kind != .delete else {
            return nil
        }
        return AudioBookmark(
            libraryItemID: itemID,
            time: time,
            title: title,
            createdAtMilliseconds: createdAtMilliseconds
        )
    }

    func reidentified(as accountID: AccountID) -> QueuedBookmarkMutation {
        QueuedBookmarkMutation(
            id: id,
            accountID: accountID,
            itemID: itemID,
            time: time,
            title: title,
            createdAtMilliseconds: createdAtMilliseconds,
            kind: kind,
            status: status
        )
    }
}

enum BookmarkMutationStoreError: Error, Equatable {
    case invalidTime
    case emptyTitle
    case corruptedData
    case persistenceFailed
}

enum BookmarkReconciliationDecision: Equatable {
    case complete
    case create(title: String)
    case rename(AudioBookmark, title: String)
    case delete(AudioBookmark)
    case invalid

    static func decide(
        mutation: QueuedBookmarkMutation,
        remote: [AudioBookmark]
    ) -> BookmarkReconciliationDecision {
        let existing = remote.first {
            $0.libraryItemID == mutation.itemID
                && abs($0.time - mutation.time) < 0.001
        }
        switch mutation.kind {
        case .create:
            guard let title = mutation.title else {
                return .invalid
            }
            return existing?.title == title ? .complete : .create(title: title)
        case .rename:
            guard let title = mutation.title else {
                return .invalid
            }
            if existing?.title == title {
                return .complete
            }
            guard let existing else {
                return .invalid
            }
            return .rename(existing, title: title)
        case .delete:
            guard let existing else {
                return .complete
            }
            return .delete(existing)
        }
    }
}

@MainActor
final class BookmarkMutationStore {
    static let shared = BookmarkMutationStore(defaults: .standard)

    private let defaults: UserDefaults
    private let storageKey = "bleat.bookmarkMutations.v1"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func mutations(
        accountID: AccountID,
        itemID: LibraryItemID? = nil
    ) throws(BookmarkMutationStoreError) -> [QueuedBookmarkMutation] {
        try entries().filter {
            $0.accountID == accountID
                && (itemID == nil || $0.itemID == itemID)
        }
    }

    @discardableResult
    func enqueue(
        accountID: AccountID,
        bookmark: AudioBookmark,
        kind: QueuedBookmarkMutationKind,
        title: String? = nil,
        status: QueuedBookmarkMutationStatus
    ) throws(BookmarkMutationStoreError) -> QueuedBookmarkMutation {
        guard bookmark.time.isFinite, bookmark.time >= 0 else {
            throw .invalidTime
        }
        let normalizedTitle: String?
        switch kind {
        case .create, .rename:
            let value = (title ?? bookmark.title).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !value.isEmpty else {
                throw .emptyTitle
            }
            normalizedTitle = value
        case .delete:
            normalizedTitle = nil
        }
        let mutation = QueuedBookmarkMutation(
            id: UUID(),
            accountID: accountID,
            itemID: bookmark.libraryItemID,
            time: bookmark.time,
            title: normalizedTitle,
            createdAtMilliseconds: bookmark.createdAtMilliseconds,
            kind: kind,
            status: status
        )
        var stored = try entries()
        stored.append(mutation)
        try persist(stored)
        return mutation
    }

    func markPending(
        accountID: AccountID
    ) throws(BookmarkMutationStoreError) {
        var stored = try entries()
        for index in stored.indices
        where stored[index].accountID == accountID {
            stored[index].status = .pending
        }
        try persist(stored)
    }

    func markFailed(
        _ id: UUID
    ) throws(BookmarkMutationStoreError) {
        var stored = try entries()
        guard let index = stored.firstIndex(where: { $0.id == id })
        else {
            return
        }
        stored[index].status = .failed
        try persist(stored)
    }

    func remove(
        _ id: UUID
    ) throws(BookmarkMutationStoreError) {
        var stored = try entries()
        stored.removeAll { $0.id == id }
        try persist(stored)
    }

    func removeAll(
        accountID: AccountID
    ) throws(BookmarkMutationStoreError) {
        var stored = try entries()
        stored.removeAll { $0.accountID == accountID }
        try persist(stored)
    }

    func migrateAccountIdentity(
        from legacyID: AccountID,
        to canonicalID: AccountID
    ) throws(BookmarkMutationStoreError) {
        let migrated = try entries().map {
            $0.accountID == legacyID
                ? $0.reidentified(as: canonicalID) : $0
        }
        try persist(migrated)
    }

    func applying(
        _ mutations: [QueuedBookmarkMutation],
        to remote: [AudioBookmark]
    ) -> [AudioBookmark] {
        var merged = remote
        for mutation in mutations {
            let bookmarkID = "\(mutation.itemID.rawValue):\(mutation.time)"
            merged.removeAll { $0.id == bookmarkID }
            if let bookmark = mutation.bookmark {
                merged.append(bookmark)
            }
        }
        return merged.sorted { $0.time < $1.time }
    }

    private func entries()
        throws(BookmarkMutationStoreError) -> [QueuedBookmarkMutation]
    {
        guard let data = defaults.data(forKey: storageKey) else {
            return []
        }
        do {
            return try JSONDecoder().decode(
                [QueuedBookmarkMutation].self,
                from: data
            )
        } catch {
            throw .corruptedData
        }
    }

    private func persist(
        _ entries: [QueuedBookmarkMutation]
    ) throws(BookmarkMutationStoreError) {
        do {
            defaults.set(try JSONEncoder().encode(entries), forKey: storageKey)
        } catch {
            throw .persistenceFailed
        }
    }
}
