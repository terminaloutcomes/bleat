import Foundation

public protocol LibraryRemoteDataSource: Sendable {
    func libraries() async throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<[LibrarySummary]>

    func libraryItems(
        in libraryID: LibraryID,
        request: LibraryItemsPageRequest
    ) async throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<LibraryItemsPage>

    func search(
        in libraryID: LibraryID,
        request: LibrarySearchRequest
    ) async throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<[LibraryBookSummary]>
}

extension AudiobookshelfAPI: LibraryRemoteDataSource {}

public enum LibraryFetchPolicy: Equatable, Sendable {
    case remoteOnly
    case remoteElseCache
    case cacheOnly
}

public enum LibraryRepositorySource: Equatable, Sendable {
    case remote
    case cache
}

public struct LibraryRepositoryResult<Value: Sendable>: Sendable {
    public let value: Value
    public let source: LibraryRepositorySource
    public let refreshedAt: Date
    public let correlationID: APICorrelationID?

    public init(
        value: Value,
        source: LibraryRepositorySource,
        refreshedAt: Date,
        correlationID: APICorrelationID?
    ) {
        self.value = value
        self.source = source
        self.refreshedAt = refreshedAt
        self.correlationID = correlationID
    }
}

public enum LibraryRepositoryError: Error, Equatable, Sendable {
    case remote(AudiobookshelfAPIError)
    case cache(LibraryCacheError)
    case fallbackCache(
        remote: AudiobookshelfAPIError,
        cache: LibraryCacheError
    )
    case noCachedValue
    case cancelled
}

public actor LibraryRepository<Remote: LibraryRemoteDataSource> {
    private let accountID: AccountID
    private let remote: Remote
    private let cache: LibraryCache

    public init(
        accountID: AccountID,
        remote: Remote,
        cache: LibraryCache
    ) {
        self.accountID = accountID
        self.remote = remote
        self.cache = cache
    }

    public func libraries(
        policy: LibraryFetchPolicy = .remoteElseCache
    ) async throws(LibraryRepositoryError)
        -> LibraryRepositoryResult<[LibrarySummary]>
    {
        if policy == .cacheOnly {
            return try await cachedLibraries()
        }

        let result: AudiobookshelfAPIResult<[LibrarySummary]>
        do {
            result = try await remote.libraries()
        } catch let error {
            return try await fallbackLibraries(
                after: error,
                policy: policy
            )
        }
        let refreshedAt = Date()
        do {
            try await cache.replaceLibraries(
                result.value,
                for: accountID,
                refreshedAt: refreshedAt
            )
        } catch let error {
            throw .cache(error)
        }
        return LibraryRepositoryResult(
            value: result.value,
            source: .remote,
            refreshedAt: refreshedAt,
            correlationID: result.correlationID
        )
    }

    public func libraryItems(
        in libraryID: LibraryID,
        request: LibraryItemsPageRequest,
        policy: LibraryFetchPolicy = .remoteElseCache
    ) async throws(LibraryRepositoryError)
        -> LibraryRepositoryResult<LibraryItemsPage>
    {
        if policy == .cacheOnly {
            return try await cachedPage(
                request: request,
                libraryID: libraryID
            )
        }

        let result: AudiobookshelfAPIResult<LibraryItemsPage>
        do {
            result = try await remote.libraryItems(
                in: libraryID,
                request: request
            )
        } catch let error {
            return try await fallbackPage(
                request: request,
                libraryID: libraryID,
                after: error,
                policy: policy
            )
        }
        let refreshedAt = Date()
        do {
            try await cache.savePage(
                result.value,
                request: request,
                libraryID: libraryID,
                accountID: accountID,
                refreshedAt: refreshedAt
            )
        } catch let error {
            throw .cache(error)
        }
        return LibraryRepositoryResult(
            value: result.value,
            source: .remote,
            refreshedAt: refreshedAt,
            correlationID: result.correlationID
        )
    }

    public func search(
        in libraryID: LibraryID,
        request: LibrarySearchRequest,
        policy: LibraryFetchPolicy = .remoteElseCache
    ) async throws(LibraryRepositoryError)
        -> LibraryRepositoryResult<[LibraryBookSummary]>
    {
        if policy == .cacheOnly {
            return try await cachedSearch(
                request: request,
                libraryID: libraryID
            )
        }

        let result: AudiobookshelfAPIResult<[LibraryBookSummary]>
        do {
            result = try await remote.search(
                in: libraryID,
                request: request
            )
        } catch let error {
            return try await fallbackSearch(
                request: request,
                libraryID: libraryID,
                after: error,
                policy: policy
            )
        }
        let refreshedAt = Date()
        do {
            try await cache.saveSearchResults(
                result.value,
                request: request,
                libraryID: libraryID,
                accountID: accountID,
                refreshedAt: refreshedAt
            )
        } catch let error {
            throw .cache(error)
        }
        return LibraryRepositoryResult(
            value: result.value,
            source: .remote,
            refreshedAt: refreshedAt,
            correlationID: result.correlationID
        )
    }

    private func cachedLibraries()
        async throws(LibraryRepositoryError)
        -> LibraryRepositoryResult<[LibrarySummary]>
    {
        let cached: CachedLibrariesSnapshot?
        do {
            cached = try await cache.libraries(for: accountID)
        } catch let error {
            throw .cache(error)
        }
        guard let snapshot = cached else {
            throw .noCachedValue
        }
        return LibraryRepositoryResult(
            value: snapshot.libraries,
            source: .cache,
            refreshedAt: snapshot.refreshedAt,
            correlationID: nil
        )
    }

    private func cachedPage(
        request: LibraryItemsPageRequest,
        libraryID: LibraryID
    ) async throws(LibraryRepositoryError)
        -> LibraryRepositoryResult<LibraryItemsPage>
    {
        let cached: CachedLibraryPageSnapshot?
        do {
            cached = try await cache.page(
                request: request,
                libraryID: libraryID,
                accountID: accountID
            )
        } catch let error {
            throw .cache(error)
        }
        guard let snapshot = cached else {
            throw .noCachedValue
        }
        return LibraryRepositoryResult(
            value: snapshot.page,
            source: .cache,
            refreshedAt: snapshot.refreshedAt,
            correlationID: nil
        )
    }

    private func cachedSearch(
        request: LibrarySearchRequest,
        libraryID: LibraryID
    ) async throws(LibraryRepositoryError)
        -> LibraryRepositoryResult<[LibraryBookSummary]>
    {
        let cached: CachedLibrarySearchSnapshot?
        do {
            cached = try await cache.searchResults(
                request: request,
                libraryID: libraryID,
                accountID: accountID
            )
        } catch let error {
            throw .cache(error)
        }
        guard let snapshot = cached else {
            throw .noCachedValue
        }
        return LibraryRepositoryResult(
            value: snapshot.items,
            source: .cache,
            refreshedAt: snapshot.refreshedAt,
            correlationID: nil
        )
    }

    private func fallbackLibraries(
        after remoteError: AudiobookshelfAPIError,
        policy: LibraryFetchPolicy
    ) async throws(LibraryRepositoryError)
        -> LibraryRepositoryResult<[LibrarySummary]>
    {
        if remoteError == .cancelled || Task.isCancelled {
            throw .cancelled
        }
        guard policy == .remoteElseCache else {
            throw .remote(remoteError)
        }
        do {
            return try await cachedLibraries()
        } catch let cacheError {
            throw fallbackError(
                remote: remoteError,
                cache: cacheError
            )
        }
    }

    private func fallbackPage(
        request: LibraryItemsPageRequest,
        libraryID: LibraryID,
        after remoteError: AudiobookshelfAPIError,
        policy: LibraryFetchPolicy
    ) async throws(LibraryRepositoryError)
        -> LibraryRepositoryResult<LibraryItemsPage>
    {
        if remoteError == .cancelled || Task.isCancelled {
            throw .cancelled
        }
        guard policy == .remoteElseCache else {
            throw .remote(remoteError)
        }
        do {
            return try await cachedPage(
                request: request,
                libraryID: libraryID
            )
        } catch let cacheError {
            throw fallbackError(
                remote: remoteError,
                cache: cacheError
            )
        }
    }

    private func fallbackSearch(
        request: LibrarySearchRequest,
        libraryID: LibraryID,
        after remoteError: AudiobookshelfAPIError,
        policy: LibraryFetchPolicy
    ) async throws(LibraryRepositoryError)
        -> LibraryRepositoryResult<[LibraryBookSummary]>
    {
        if remoteError == .cancelled || Task.isCancelled {
            throw .cancelled
        }
        guard policy == .remoteElseCache else {
            throw .remote(remoteError)
        }
        do {
            return try await cachedSearch(
                request: request,
                libraryID: libraryID
            )
        } catch let cacheError {
            throw fallbackError(
                remote: remoteError,
                cache: cacheError
            )
        }
    }

    private func fallbackError(
        remote: AudiobookshelfAPIError,
        cache: LibraryRepositoryError
    ) -> LibraryRepositoryError {
        switch cache {
        case .noCachedValue:
            .remote(remote)
        case let .cache(cacheError):
            .fallbackCache(remote: remote, cache: cacheError)
        default:
            cache
        }
    }
}
