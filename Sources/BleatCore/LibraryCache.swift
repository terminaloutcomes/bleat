import Foundation
import SwiftData

@Model
public final class CachedLibraryCollectionRecord {
    @Attribute(.unique)
    var accountID: String
    var refreshedAt: Date

    init(accountID: String, refreshedAt: Date) {
        self.accountID = accountID
        self.refreshedAt = refreshedAt
    }
}

@Model
public final class CachedLibraryRecord {
    @Attribute(.unique)
    var cacheKey: String
    var accountID: String
    var libraryID: String
    var position: Int
    var payload: Data
    var refreshedAt: Date

    init(
        cacheKey: String,
        accountID: String,
        libraryID: String,
        position: Int,
        payload: Data,
        refreshedAt: Date
    ) {
        self.cacheKey = cacheKey
        self.accountID = accountID
        self.libraryID = libraryID
        self.position = position
        self.payload = payload
        self.refreshedAt = refreshedAt
    }
}

@Model
public final class CachedLibraryPageRecord {
    @Attribute(.unique)
    var cacheKey: String
    var accountID: String
    var libraryID: String
    var payload: Data
    var refreshedAt: Date

    init(
        cacheKey: String,
        accountID: String,
        libraryID: String,
        payload: Data,
        refreshedAt: Date
    ) {
        self.cacheKey = cacheKey
        self.accountID = accountID
        self.libraryID = libraryID
        self.payload = payload
        self.refreshedAt = refreshedAt
    }
}

@Model
public final class CachedLibrarySearchRecord {
    @Attribute(.unique)
    var cacheKey: String
    var accountID: String
    var libraryID: String
    var payload: Data
    var refreshedAt: Date

    init(
        cacheKey: String,
        accountID: String,
        libraryID: String,
        payload: Data,
        refreshedAt: Date
    ) {
        self.cacheKey = cacheKey
        self.accountID = accountID
        self.libraryID = libraryID
        self.payload = payload
        self.refreshedAt = refreshedAt
    }
}

@Model
public final class CachedLibraryHomeRecord {
    @Attribute(.unique)
    var cacheKey: String
    var accountID: String
    var libraryID: String
    var payload: Data
    var refreshedAt: Date

    init(
        cacheKey: String,
        accountID: String,
        libraryID: String,
        payload: Data,
        refreshedAt: Date
    ) {
        self.cacheKey = cacheKey
        self.accountID = accountID
        self.libraryID = libraryID
        self.payload = payload
        self.refreshedAt = refreshedAt
    }
}

@Model
public final class CachedLibraryBookDetailRecord {
    @Attribute(.unique)
    var cacheKey: String
    var accountID: String
    var userID: String
    var libraryID: String
    var libraryItemID: String
    var payload: Data
    var refreshedAt: Date

    init(
        cacheKey: String,
        accountID: String,
        userID: String,
        libraryID: String,
        libraryItemID: String,
        payload: Data,
        refreshedAt: Date
    ) {
        self.cacheKey = cacheKey
        self.accountID = accountID
        self.userID = userID
        self.libraryID = libraryID
        self.libraryItemID = libraryItemID
        self.payload = payload
        self.refreshedAt = refreshedAt
    }
}

public struct CachedLibrariesSnapshot: Equatable, Sendable {
    public let libraries: [LibrarySummary]
    public let refreshedAt: Date
}

public struct CachedLibraryPageSnapshot: Equatable, Sendable {
    public let page: LibraryItemsPage
    public let refreshedAt: Date
}

public struct CachedLibrarySearchSnapshot: Equatable, Sendable {
    public let results: LibrarySearchResults
    public let refreshedAt: Date

    public var items: [LibraryBookSummary] { results.books }
}

public struct CachedLibraryHomeSnapshot: Equatable, Sendable {
    public let shelves: [LibraryBookShelf]
    public let refreshedAt: Date
}

public struct CachedLibraryBookDetailSnapshot: Equatable, Sendable {
    public let detail: LibraryBookDetail
    public let refreshedAt: Date
}

public enum LibraryCacheError: Error, Equatable, Sendable {
    case invalidAccountID
    case invalidUserID
    case invalidLibraryID
    case invalidLibrary
    case duplicateLibraryID(LibraryID)
    case invalidPage
    case invalidStoredLibrary(LibraryID)
    case invalidStoredPage
    case invalidSearchResults
    case invalidStoredSearchResults
    case invalidHomeShelves
    case invalidStoredHomeShelves
    case invalidBookDetail
    case invalidStoredBookDetail
    case encodingFailed
    case persistenceFailed
}

@ModelActor
public actor LibraryCache {
    public func replaceLibraries(
        _ libraries: [LibrarySummary],
        for accountID: AccountID,
        refreshedAt: Date = Date()
    ) throws(LibraryCacheError) {
        guard !accountID.rawValue.isEmpty else {
            throw .invalidAccountID
        }
        var seen: Set<LibraryID> = []
        for library in libraries {
            guard library.isValidForStorage else {
                throw library.id.rawValue.isEmpty
                    ? .invalidLibraryID
                    : .invalidLibrary
            }
            guard seen.insert(library.id).inserted else {
                throw .duplicateLibraryID(library.id)
            }
        }

        let records = try libraryRecords()
        let collections = try collectionRecords()
        let accountRecords = records.filter {
            $0.accountID == accountID.rawValue
        }
        let retainedIDs = Set(libraries.map(\.id.rawValue))
        for record in accountRecords
            where !retainedIDs.contains(record.libraryID)
        {
            modelContext.delete(record)
        }
        let pages = try pageRecords()
        for page in pages
            where page.accountID == accountID.rawValue
                && !retainedIDs.contains(page.libraryID)
        {
            modelContext.delete(page)
        }
        let searches = try searchRecords()
        for search in searches
            where search.accountID == accountID.rawValue
                && !retainedIDs.contains(search.libraryID)
        {
            modelContext.delete(search)
        }
        let homes = try homeRecords()
        for home in homes
            where home.accountID == accountID.rawValue
                && !retainedIDs.contains(home.libraryID)
        {
            modelContext.delete(home)
        }
        let details = try detailRecords()
        for detail in details
            where detail.accountID == accountID.rawValue
                && !retainedIDs.contains(detail.libraryID)
        {
            modelContext.delete(detail)
        }

        for (position, library) in libraries.enumerated() {
            let payload = try encode(library)
            let key = Self.key([
                accountID.rawValue,
                library.id.rawValue,
            ])
            if let record = accountRecords.first(where: {
                $0.cacheKey == key
            }) {
                record.position = position
                record.payload = payload
                record.refreshedAt = refreshedAt
            } else {
                modelContext.insert(CachedLibraryRecord(
                    cacheKey: key,
                    accountID: accountID.rawValue,
                    libraryID: library.id.rawValue,
                    position: position,
                    payload: payload,
                    refreshedAt: refreshedAt
                ))
            }
        }
        if let collection = collections.first(where: {
            $0.accountID == accountID.rawValue
        }) {
            collection.refreshedAt = refreshedAt
        } else {
            modelContext.insert(CachedLibraryCollectionRecord(
                accountID: accountID.rawValue,
                refreshedAt: refreshedAt
            ))
        }
        try save()
    }

    public func libraries(
        for accountID: AccountID
    ) throws(LibraryCacheError) -> CachedLibrariesSnapshot? {
        guard !accountID.rawValue.isEmpty else {
            throw .invalidAccountID
        }
        guard let collection = try collectionRecords().first(where: {
            $0.accountID == accountID.rawValue
        }) else {
            return nil
        }
        let records = try libraryRecords()
            .filter { $0.accountID == accountID.rawValue }
            .sorted { $0.position < $1.position }
        var libraries: [LibrarySummary] = []
        libraries.reserveCapacity(records.count)
        for record in records {
            let library: LibrarySummary
            do {
                library = try JSONDecoder().decode(
                    LibrarySummary.self,
                    from: record.payload
                )
            } catch {
                throw .invalidStoredLibrary(
                    LibraryID(rawValue: record.libraryID)
                )
            }
            guard library.id.rawValue == record.libraryID,
                  library.isValidForStorage
            else {
                throw .invalidStoredLibrary(
                    LibraryID(rawValue: record.libraryID)
                )
            }
            libraries.append(library)
        }
        return CachedLibrariesSnapshot(
            libraries: libraries,
            refreshedAt: collection.refreshedAt
        )
    }

    public func savePage(
        _ page: LibraryItemsPage,
        request: LibraryItemsPageRequest,
        libraryID: LibraryID,
        accountID: AccountID,
        refreshedAt: Date = Date()
    ) throws(LibraryCacheError) {
        guard !accountID.rawValue.isEmpty else {
            throw .invalidAccountID
        }
        guard !libraryID.rawValue.isEmpty else {
            throw .invalidLibraryID
        }
        guard page.isValidForStorage(
            request: request,
            libraryID: libraryID
        ) else {
            throw .invalidPage
        }
        let key = Self.pageKey(
            accountID: accountID,
            libraryID: libraryID,
            request: request
        )
        let payload = try encode(page)
        let records = try pageRecords()
        if let record = records.first(where: { $0.cacheKey == key }) {
            record.payload = payload
            record.refreshedAt = refreshedAt
        } else {
            modelContext.insert(CachedLibraryPageRecord(
                cacheKey: key,
                accountID: accountID.rawValue,
                libraryID: libraryID.rawValue,
                payload: payload,
                refreshedAt: refreshedAt
            ))
        }
        try save()
    }

    public func page(
        request: LibraryItemsPageRequest,
        libraryID: LibraryID,
        accountID: AccountID
    ) throws(LibraryCacheError) -> CachedLibraryPageSnapshot? {
        guard !accountID.rawValue.isEmpty else {
            throw .invalidAccountID
        }
        guard !libraryID.rawValue.isEmpty else {
            throw .invalidLibraryID
        }
        let key = Self.pageKey(
            accountID: accountID,
            libraryID: libraryID,
            request: request
        )
        guard let record = try pageRecords().first(where: {
            $0.cacheKey == key
        }) else {
            return nil
        }
        let page: LibraryItemsPage
        do {
            page = try JSONDecoder().decode(
                LibraryItemsPage.self,
                from: record.payload
            )
        } catch {
            throw .invalidStoredPage
        }
        guard page.isValidForStorage(
            request: request,
            libraryID: libraryID
        ) else {
            throw .invalidStoredPage
        }
        return CachedLibraryPageSnapshot(
            page: page,
            refreshedAt: record.refreshedAt
        )
    }

    public func saveSearchResults(
        _ results: LibrarySearchResults,
        request: LibrarySearchRequest,
        libraryID: LibraryID,
        accountID: AccountID,
        refreshedAt: Date = Date()
    ) throws(LibraryCacheError) {
        guard !accountID.rawValue.isEmpty else {
            throw .invalidAccountID
        }
        guard !libraryID.rawValue.isEmpty else {
            throw .invalidLibraryID
        }
        guard results.books.count <= request.limit,
              results.authors.count <= request.limit,
              results.series.count <= request.limit,
              results.books.allSatisfy({
                  $0.isValidForStorage(in: libraryID)
              })
        else {
            throw .invalidSearchResults
        }
        let key = Self.searchKey(
            accountID: accountID,
            libraryID: libraryID,
            request: request
        )
        let payload = try encode(results)
        let records = try searchRecords()
        if let record = records.first(where: { $0.cacheKey == key }) {
            record.payload = payload
            record.refreshedAt = refreshedAt
        } else {
            modelContext.insert(CachedLibrarySearchRecord(
                cacheKey: key,
                accountID: accountID.rawValue,
                libraryID: libraryID.rawValue,
                payload: payload,
                refreshedAt: refreshedAt
            ))
        }
        try save()
    }

    public func saveSearchResults(
        _ items: [LibraryBookSummary],
        request: LibrarySearchRequest,
        libraryID: LibraryID,
        accountID: AccountID,
        refreshedAt: Date = Date()
    ) throws(LibraryCacheError) {
        try saveSearchResults(
            LibrarySearchResults(books: items),
            request: request,
            libraryID: libraryID,
            accountID: accountID,
            refreshedAt: refreshedAt
        )
    }

    public func searchResults(
        request: LibrarySearchRequest,
        libraryID: LibraryID,
        accountID: AccountID
    ) throws(LibraryCacheError) -> CachedLibrarySearchSnapshot? {
        guard !accountID.rawValue.isEmpty else {
            throw .invalidAccountID
        }
        guard !libraryID.rawValue.isEmpty else {
            throw .invalidLibraryID
        }
        let key = Self.searchKey(
            accountID: accountID,
            libraryID: libraryID,
            request: request
        )
        guard let record = try searchRecords().first(where: {
            $0.cacheKey == key
        }) else {
            return nil
        }
        let results: LibrarySearchResults
        do {
            results = try JSONDecoder().decode(
                LibrarySearchResults.self,
                from: record.payload
            )
        } catch {
            do {
                results = LibrarySearchResults(
                    books: try JSONDecoder().decode(
                        [LibraryBookSummary].self,
                        from: record.payload
                    )
                )
            } catch {
                throw .invalidStoredSearchResults
            }
        }
        guard results.books.count <= request.limit,
              results.authors.count <= request.limit,
              results.series.count <= request.limit,
              results.books.allSatisfy({
                  $0.isValidForStorage(in: libraryID)
              })
        else {
            throw .invalidStoredSearchResults
        }
        return CachedLibrarySearchSnapshot(
            results: results,
            refreshedAt: record.refreshedAt
        )
    }

    public func saveHomeShelves(
        _ shelves: [LibraryBookShelf],
        request: LibraryHomeRequest,
        libraryID: LibraryID,
        accountID: AccountID,
        refreshedAt: Date = Date()
    ) throws(LibraryCacheError) {
        guard !accountID.rawValue.isEmpty else {
            throw .invalidAccountID
        }
        guard !libraryID.rawValue.isEmpty else {
            throw .invalidLibraryID
        }
        var seenShelfIDs: Set<String> = []
        guard shelves.allSatisfy({
            seenShelfIDs.insert($0.id).inserted
                && $0.isValidForStorage(
                    request: request,
                    libraryID: libraryID
                )
        }) else {
            throw .invalidHomeShelves
        }
        let key = Self.homeKey(
            accountID: accountID,
            libraryID: libraryID,
            request: request
        )
        let payload = try encode(shelves)
        let records = try homeRecords()
        if let record = records.first(where: { $0.cacheKey == key }) {
            record.payload = payload
            record.refreshedAt = refreshedAt
        } else {
            modelContext.insert(CachedLibraryHomeRecord(
                cacheKey: key,
                accountID: accountID.rawValue,
                libraryID: libraryID.rawValue,
                payload: payload,
                refreshedAt: refreshedAt
            ))
        }
        try save()
    }

    public func homeShelves(
        request: LibraryHomeRequest,
        libraryID: LibraryID,
        accountID: AccountID
    ) throws(LibraryCacheError) -> CachedLibraryHomeSnapshot? {
        guard !accountID.rawValue.isEmpty else {
            throw .invalidAccountID
        }
        guard !libraryID.rawValue.isEmpty else {
            throw .invalidLibraryID
        }
        let key = Self.homeKey(
            accountID: accountID,
            libraryID: libraryID,
            request: request
        )
        guard let record = try homeRecords().first(where: {
            $0.cacheKey == key
        }) else {
            return nil
        }
        let shelves: [LibraryBookShelf]
        do {
            shelves = try JSONDecoder().decode(
                [LibraryBookShelf].self,
                from: record.payload
            )
        } catch {
            throw .invalidStoredHomeShelves
        }
        var seenShelfIDs: Set<String> = []
        guard shelves.allSatisfy({
            seenShelfIDs.insert($0.id).inserted
                && $0.isValidForStorage(
                    request: request,
                    libraryID: libraryID
                )
        }) else {
            throw .invalidStoredHomeShelves
        }
        return CachedLibraryHomeSnapshot(
            shelves: shelves,
            refreshedAt: record.refreshedAt
        )
    }

    public func saveBookDetail(
        _ detail: LibraryBookDetail,
        userID: UserID,
        accountID: AccountID,
        refreshedAt: Date = Date()
    ) throws(LibraryCacheError) {
        guard !accountID.rawValue.isEmpty else {
            throw .invalidAccountID
        }
        guard !userID.rawValue.isEmpty else {
            throw .invalidUserID
        }
        guard !detail.libraryID.rawValue.isEmpty else {
            throw .invalidLibraryID
        }
        guard detail.isValidForStorage(
            in: detail.libraryID,
            for: userID
        ) else {
            throw .invalidBookDetail
        }
        let key = Self.detailKey(
            accountID: accountID,
            userID: userID,
            libraryID: detail.libraryID,
            itemID: detail.id
        )
        let payload = try encode(detail)
        let records = try detailRecords()
        if let record = records.first(where: { $0.cacheKey == key }) {
            record.payload = payload
            record.refreshedAt = refreshedAt
        } else {
            modelContext.insert(CachedLibraryBookDetailRecord(
                cacheKey: key,
                accountID: accountID.rawValue,
                userID: userID.rawValue,
                libraryID: detail.libraryID.rawValue,
                libraryItemID: detail.id.rawValue,
                payload: payload,
                refreshedAt: refreshedAt
            ))
        }
        try save()
    }

    public func bookDetail(
        for itemID: LibraryItemID,
        in libraryID: LibraryID,
        userID: UserID,
        accountID: AccountID
    ) throws(LibraryCacheError) -> CachedLibraryBookDetailSnapshot? {
        guard !accountID.rawValue.isEmpty else {
            throw .invalidAccountID
        }
        guard !userID.rawValue.isEmpty else {
            throw .invalidUserID
        }
        guard !libraryID.rawValue.isEmpty else {
            throw .invalidLibraryID
        }
        guard !itemID.rawValue.isEmpty else {
            throw .invalidBookDetail
        }
        let key = Self.detailKey(
            accountID: accountID,
            userID: userID,
            libraryID: libraryID,
            itemID: itemID
        )
        guard let record = try detailRecords().first(where: {
            $0.cacheKey == key
        }) else {
            return nil
        }
        let detail: LibraryBookDetail
        do {
            detail = try JSONDecoder().decode(
                LibraryBookDetail.self,
                from: record.payload
            )
        } catch {
            throw .invalidStoredBookDetail
        }
        guard detail.id == itemID,
              detail.libraryID == libraryID,
              record.accountID == accountID.rawValue,
              record.userID == userID.rawValue,
              record.libraryID == libraryID.rawValue,
              record.libraryItemID == itemID.rawValue,
              detail.isValidForStorage(in: libraryID, for: userID)
        else {
            throw .invalidStoredBookDetail
        }
        return CachedLibraryBookDetailSnapshot(
            detail: detail,
            refreshedAt: record.refreshedAt
        )
    }

    public func invalidateLibrary(
        _ libraryID: LibraryID,
        for accountID: AccountID
    ) throws(LibraryCacheError) {
        guard !accountID.rawValue.isEmpty else {
            throw .invalidAccountID
        }
        guard !libraryID.rawValue.isEmpty else {
            throw .invalidLibraryID
        }
        for record in try pageRecords()
            where record.accountID == accountID.rawValue
                && record.libraryID == libraryID.rawValue
        {
            modelContext.delete(record)
        }
        for record in try searchRecords()
            where record.accountID == accountID.rawValue
                && record.libraryID == libraryID.rawValue
        {
            modelContext.delete(record)
        }
        for record in try homeRecords()
            where record.accountID == accountID.rawValue
                && record.libraryID == libraryID.rawValue
        {
            modelContext.delete(record)
        }
        for record in try detailRecords()
            where record.accountID == accountID.rawValue
                && record.libraryID == libraryID.rawValue
        {
            modelContext.delete(record)
        }
        try save()
    }

    public func removeAccount(
        _ accountID: AccountID
    ) throws(LibraryCacheError) {
        guard !accountID.rawValue.isEmpty else {
            throw .invalidAccountID
        }
        for record in try libraryRecords()
            where record.accountID == accountID.rawValue
        {
            modelContext.delete(record)
        }
        for record in try collectionRecords()
            where record.accountID == accountID.rawValue
        {
            modelContext.delete(record)
        }
        for record in try pageRecords()
            where record.accountID == accountID.rawValue
        {
            modelContext.delete(record)
        }
        for record in try searchRecords()
            where record.accountID == accountID.rawValue
        {
            modelContext.delete(record)
        }
        for record in try homeRecords()
            where record.accountID == accountID.rawValue
        {
            modelContext.delete(record)
        }
        for record in try detailRecords()
            where record.accountID == accountID.rawValue
        {
            modelContext.delete(record)
        }
        try save()
    }

    private func libraryRecords() throws(LibraryCacheError)
        -> [CachedLibraryRecord]
    {
        do {
            return try modelContext.fetch(
                FetchDescriptor<CachedLibraryRecord>()
            )
        } catch {
            throw .persistenceFailed
        }
    }

    private func collectionRecords() throws(LibraryCacheError)
        -> [CachedLibraryCollectionRecord]
    {
        do {
            return try modelContext.fetch(
                FetchDescriptor<CachedLibraryCollectionRecord>()
            )
        } catch {
            throw .persistenceFailed
        }
    }

    private func pageRecords() throws(LibraryCacheError)
        -> [CachedLibraryPageRecord]
    {
        do {
            return try modelContext.fetch(
                FetchDescriptor<CachedLibraryPageRecord>()
            )
        } catch {
            throw .persistenceFailed
        }
    }

    private func searchRecords() throws(LibraryCacheError)
        -> [CachedLibrarySearchRecord]
    {
        do {
            return try modelContext.fetch(
                FetchDescriptor<CachedLibrarySearchRecord>()
            )
        } catch {
            throw .persistenceFailed
        }
    }

    private func homeRecords() throws(LibraryCacheError)
        -> [CachedLibraryHomeRecord]
    {
        do {
            return try modelContext.fetch(
                FetchDescriptor<CachedLibraryHomeRecord>()
            )
        } catch {
            throw .persistenceFailed
        }
    }

    private func detailRecords() throws(LibraryCacheError)
        -> [CachedLibraryBookDetailRecord]
    {
        do {
            return try modelContext.fetch(
                FetchDescriptor<CachedLibraryBookDetailRecord>()
            )
        } catch {
            throw .persistenceFailed
        }
    }

    private func encode<Value: Encodable>(
        _ value: Value
    ) throws(LibraryCacheError) -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw .encodingFailed
        }
    }

    private func save() throws(LibraryCacheError) {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw .persistenceFailed
        }
    }

    private static func pageKey(
        accountID: AccountID,
        libraryID: LibraryID,
        request: LibraryItemsPageRequest
    ) -> String {
        key([
            accountID.rawValue,
            libraryID.rawValue,
            String(request.page),
            String(request.limit),
            request.sort.queryValue,
            request.descending ? "1" : "0",
            request.filter == nil ? "0" : "1",
            request.filter?.rawValue ?? "",
            request.includeProgress ? "1" : "0",
            request.collapseSeries ? "1" : "0",
            request.minified ? "1" : "0",
        ])
    }

    private static func searchKey(
        accountID: AccountID,
        libraryID: LibraryID,
        request: LibrarySearchRequest
    ) -> String {
        key([
            accountID.rawValue,
            libraryID.rawValue,
            request.query,
            String(request.limit),
        ])
    }

    private static func homeKey(
        accountID: AccountID,
        libraryID: LibraryID,
        request: LibraryHomeRequest
    ) -> String {
        key([
            accountID.rawValue,
            libraryID.rawValue,
            String(request.limit),
            request.includeProgress ? "1" : "0",
        ])
    }

    private static func detailKey(
        accountID: AccountID,
        userID: UserID,
        libraryID: LibraryID,
        itemID: LibraryItemID
    ) -> String {
        key([
            accountID.rawValue,
            userID.rawValue,
            libraryID.rawValue,
            itemID.rawValue,
        ])
    }

    private static func key(_ components: [String]) -> String {
        components.map {
            "\($0.utf8.count):\($0)"
        }.joined()
    }
}
