import BleatCore
import CryptoKit
import OSLog
import Observation
import SwiftUI

enum BookCoverLoadPolicy: Hashable, Sendable {
    case allowNetwork
    case cacheOnly
}

private struct BookCoverResource: Hashable, Sendable {
    let accountID: AccountID
    let url: URL

    init(accountID: AccountID, url: URL) {
        self.accountID = accountID
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = nil
        self.url = components?.url ?? url
    }
}

private struct BookCoverCacheKey: Hashable, Sendable {
    let resource: BookCoverResource
    let url: URL

    init(accountID: AccountID, url: URL) {
        resource = BookCoverResource(accountID: accountID, url: url)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems?.filter {
            $0.name != "ts" && $0.name != "revision"
        }
        components?.queryItems = items
        self.url = components?.url ?? url
    }

    var accountID: AccountID { resource.accountID }
    var memoryKey: NSString {
        "\(accountID.rawValue)\u{0}\(url.absoluteString)" as NSString
    }
}

// A refresh changes request identity even when the server keeps updatedAt.
// Cache invalidation completes before publishing this observable generation.
@MainActor @Observable
final class BookCoverRefresh {
    static let shared = BookCoverRefresh()
    private var presentationGenerations: [AccountID: UUID] = [:]

    func presentationGeneration(accountID: AccountID?) -> UUID? {
        accountID.flatMap { presentationGenerations[$0] }
    }

    private var accountGenerations: [AccountID: UUID] = [:]
    private var itemGenerations: [AccountID: [LibraryItemID: UUID]] = [:]

    func generation(accountID: AccountID?, url: URL?) -> [UUID?] {
        guard let accountID else { return [] }
        let itemID = url.map {
            LibraryItemID(
                rawValue: $0.deletingLastPathComponent().lastPathComponent)
        }
        return [
            accountGenerations[accountID],
            itemID.flatMap { itemGenerations[accountID]?[$0] },
        ]
    }

    func refresh(accountID: AccountID, itemID: LibraryItemID? = nil) {
        presentationGenerations[accountID] = UUID()
        if let itemID {
            itemGenerations[accountID, default: [:]][itemID] = UUID()
        } else {
            accountGenerations[accountID] = UUID()
        }
    }
}

// Refresh-only revisions must not blank usable artwork. A confirmed
// replacement generation or canonical metadata/size/account change does.
struct BookCoverPresentationIdentity: Equatable {
    let accountID: AccountID?
    let url: URL?
    let replacementGeneration: UUID?

    init(accountID: AccountID?, url: URL?, generation: [UUID?]) {
        self.accountID = accountID
        if let url {
            var components = URLComponents(
                url: url, resolvingAgainstBaseURL: false)
            let items = components?.queryItems?.filter { $0.name != "revision" }
            components?.queryItems = items
            self.url = components?.url ?? url
        } else {
            self.url = nil
        }
        replacementGeneration = generation.count > 1 ? generation[1] : nil
    }
}

private struct PersistedBookCover: Codable {
    let timestamp: Int64
    let data: Data
}

private struct LoadedBookCover: @unchecked Sendable {
    let data: Data
    let image: PlatformImage
}

enum BookCoverDiskFailureStage: String, Sendable {
    case prepareRevisionDirectory = "prepare_revision_directory"
    case prepareVariantDirectory = "prepare_variant_directory"
    case writeRevision = "write_revision"
    case encodeVariant = "encode_variant"
    case writeVariant = "write_variant"
    case removeCacheRoot = "remove_cache_root"
    case pruneDiskEntry = "prune_disk_entry"
}

enum BookCoverDiskFailureCause: Equatable, Sendable, Codable {
    case cocoa(code: Int)
    case posix(code: Int32)
    case unclassified

    init(error: any Error) {
        var current = error as NSError
        var visited: Set<ObjectIdentifier> = []
        var cocoaCode: Int?
        while visited.insert(ObjectIdentifier(current)).inserted {
            if current.domain == NSPOSIXErrorDomain,
                let code = Int32(exactly: current.code)
            {
                self = .posix(code: code)
                return
            }
            if current.domain == NSCocoaErrorDomain {
                cocoaCode = current.code
            }
            guard
                let underlying = current.userInfo[NSUnderlyingErrorKey]
                    as? NSError
            else { break }
            current = underlying
        }
        if let cocoaCode {
            self = .cocoa(code: cocoaCode)
        } else {
            self = .unclassified
        }
    }

    var diagnosticCode: String {
        switch self {
        case .cocoa(let code): "cocoa_\(code)"
        case .posix(let code): "posix_\(code)"
        case .unclassified: "unclassified"
        }
    }
}

enum BookCoverCacheResetFailure: Error, Equatable, Sendable, Codable {
    case cacheDirectoryUnavailable
    case removalFailed(BookCoverDiskFailureCause)
}

enum BookCoverCacheEvent: Sendable {
    case joined, committed, obsoleteCompletion
    case diskFailure(
        stage: BookCoverDiskFailureStage, cause: BookCoverDiskFailureCause)
}

protocol BookCoverImageLoading: Sendable {
    func image(for url: URL, accountID: AccountID?, policy: BookCoverLoadPolicy)
        async -> PlatformImage?
}

actor BookCoverImageLoader: BookCoverImageLoading {
    typealias Fetch =
        @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let shared = BookCoverImageLoader()

    nonisolated static func invalidateShared(for url: URL, accountID: AccountID)
        async
    {
        await shared.invalidate(for: url, accountID: accountID)
    }

    nonisolated static func resetSharedLocalData()
        async throws(BookCoverCacheResetFailure)
    {
        try await shared.removeAllForLocalDataReset()
    }

    nonisolated static func removeShared(for accountID: AccountID) async {
        await shared.removeAll(for: accountID)
    }

    private static let maximumResponseBytes = 5 * 1_024 * 1_024
    private static let memoryCapacity = 32 * 1_024 * 1_024
    private static let diskCapacity = 128 * 1_024 * 1_024

    private var tracer: any RemoteTelemetryTracing
    private let fetch: Fetch
    private let observe: @Sendable (BookCoverCacheEvent) -> Void
    private let diskCapacity: Int
    private let cacheRoot: URL?
    private let memory = NSCache<NSString, PlatformImage>()
    private var endpointRouter: ServerEndpointRouter?
    private var memoryKeys: [AccountID: Set<String>] = [:]
    private struct Request {
        let id: UUID
        let generation: UUID
        let timestamp: Int64
        let task: Task<LoadedBookCover?, Never>
    }
    private var inFlight: [BookCoverCacheKey: Request] = [:]
    private var generations: [BookCoverResource: UUID] = [:]
    private var requestedRevisions: [BookCoverResource: String] = [:]
    private var latestRequested: [BookCoverResource: Int64] = [:]
    private var validated: Set<BookCoverCacheKey> = []
    private var memoryDigests: [BookCoverCacheKey: SHA256.Digest] = [:]
    private var memoryTimestamps: [BookCoverCacheKey: Int64] = [:]
    private static let logger = Logger(
        subsystem: "org.terminaloutcomes.bleat", category: "cover-cache")

    init(
        diskCapacity: Int = BookCoverImageLoader.diskCapacity,
        observe: @escaping @Sendable (BookCoverCacheEvent) -> Void = { _ in },
        cacheRoot: URL? = nil,
        tracer: any RemoteTelemetryTracing = InactiveRemoteTelemetryTracer(),
        fetch: @escaping Fetch = { request in
            #if DEBUG || BLEAT_UI_TESTING
                if let response = try UITestAppService.coverImageResponse(
                    for: request)
                {
                    return response
                }
            #endif
            return try await URLSession.shared.data(for: request)
        }
    ) {
        self.diskCapacity = max(0, diskCapacity)
        self.cacheRoot = cacheRoot
        self.fetch = fetch
        self.observe = observe
        self.tracer = tracer
        memory.totalCostLimit = Self.memoryCapacity
        memory.countLimit = 256
    }

    func image(
        for url: URL,
        accountID: AccountID?,
        policy: BookCoverLoadPolicy = .allowNetwork
    ) async -> PlatformImage? {
        guard !Task.isCancelled else { return nil }
        guard let accountID else {
            guard policy == .allowNetwork else {
                return nil
            }
            return await Self.fetchImage(
                URLRequest(
                    url: url,
                    cachePolicy: .reloadIgnoringLocalCacheData
                ),
                using: fetch,
                endpointRouter: endpointRouter,
                tracer: tracer
            )?.image
        }
        let key = BookCoverCacheKey(accountID: accountID, url: url)
        let diskTimestamp = resourceTimestamp(for: key.resource)
        let priorTimestamp = max(
            diskTimestamp, latestRequested[key.resource] ?? 0)
        let knownResource =
            generations[key.resource] != nil || diskTimestamp > 0
            || memoryTimestamps.keys.contains { $0.resource == key.resource }
        var retryVisibleRequests = false
        var knownObsolete = false
        let revision = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "revision" })?.value
        if let revision, requestedRevisions[key.resource] != revision {
            retryVisibleRequests = inFlight.keys.contains {
                $0.resource == key.resource
            }
            retireRequests { $0 == key.resource }
            validated = validated.filter { $0.resource != key.resource }
            requestedRevisions[key.resource] = revision
        }
        let timestamp = max(Self.timestamp(url), priorTimestamp)
        if timestamp > (latestRequested[key.resource] ?? 0) {
            retryVisibleRequests =
                retryVisibleRequests
                || inFlight.keys.contains { $0.resource == key.resource }
            knownObsolete = timestamp > priorTimestamp && knownResource
            retireRequests { $0 == key.resource }
            validated = validated.filter { $0.resource != key.resource }
            latestRequested[key.resource] = timestamp
            // Metadata is authoritative even when no replacement bytes can be
            // fetched. Persist before cache-only/failure fallback so a restart
            // with an older download snapshot cannot resurrect obsolete art.
            persistTimestamp(timestamp, for: key.resource)
        }
        if policy == .cacheOnly, retryVisibleRequests || knownObsolete {
            await publishRetirement(
                for: url, accountID: accountID, knownObsolete: knownObsolete)
        }
        if policy == .cacheOnly || validated.contains(key) {
            if let image = cachedImage(
                for: key, timestamp: timestamp, legacyURL: url)
            {
                Self.logger.debug("cover_cache_hit")
                return image
            }
        }
        guard policy == .allowNetwork else { return nil }
        let generation = generations[key.resource] ?? UUID()
        generations[key.resource] = generation
        let request: Request
        if let current = inFlight[key] {
            request = current
            observe(.joined)
            Self.logger.debug("cover_refresh_joined")
        } else {
            let endpointRouter = endpointRouter
            let tracer = tracer
            let task = Task { [fetch] in
                await Self.fetchImage(
                    URLRequest(
                        url: Self.requestURL(url, timestamp: timestamp),
                        cachePolicy: .reloadIgnoringLocalCacheData),
                    using: fetch, endpointRouter: endpointRouter, tracer: tracer
                )
            }
            request = Request(
                id: UUID(), generation: generation, timestamp: timestamp,
                task: task)
            inFlight[key] = request
            Self.logger.debug("cover_revalidation_started")
        }
        // Retiring a pending variant must also restart its visible consumer.
        // Publish after registering the successor so those consumers can join it.
        if retryVisibleRequests || knownObsolete {
            await publishRetirement(
                for: url, accountID: accountID, knownObsolete: knownObsolete)
        }
        let loaded = await request.task.value
        guard generations[key.resource] == request.generation else {
            observe(.obsoleteCompletion)
            Self.logger.debug("cover_obsolete_completion_rejected")
            return nil
        }
        // Every waiter verifies ownership. Only the owner commits the result.
        guard inFlight[key]?.id == request.id else {
            return cachedImage(for: key, timestamp: timestamp, legacyURL: url)
        }
        inFlight[key] = nil
        guard let loaded else {
            Self.logger.debug("cover_revalidation_failed_offline_fallback")
            return cachedImage(for: key, timestamp: timestamp, legacyURL: url)
        }
        let previous = loadFromDisk(for: key, legacyURL: url)
        let latestTimestamp = max(
            previous?.timestamp ?? 0, resourceTimestamp(for: key.resource))
        // Exact bytes intentionally identify this rendered variant. A changed
        // encoding may cause an extra invalidation, never stale reuse.
        let changed =
            memoryDigests[key].map { $0 != SHA256.hash(data: loaded.data) }
            ?? previous.map { $0.data != loaded.data } ?? false
        if changed || timestamp > latestTimestamp && latestTimestamp > 0 {
            invalidateVariants(
                for: url, accountID: accountID, preserving: request.id)
        }
        let storedTimestamp = max(timestamp, latestTimestamp)
        storeOnDisk(loaded.data, timestamp: storedTimestamp, for: key)
        storeInMemory(loaded.image, timestamp: storedTimestamp, for: key)
        memoryDigests[key] = SHA256.hash(data: loaded.data)
        validated.insert(key)
        observe(.committed)
        Self.logger.debug("cover_revalidation_committed")
        let committedGeneration = generations[key.resource]
        if changed || timestamp > latestTimestamp && latestTimestamp > 0 {
            await BookCoverRefresh.shared.refresh(
                accountID: accountID,
                itemID: LibraryItemID(
                    rawValue: url.deletingLastPathComponent().lastPathComponent)
            )
        }
        guard generations[key.resource] == committedGeneration else {
            return nil
        }
        return loaded.image
    }

    private func publishRetirement(
        for url: URL, accountID: AccountID, knownObsolete: Bool
    ) async {
        await BookCoverRefresh.shared.refresh(
            accountID: accountID,
            itemID: knownObsolete
                ? LibraryItemID(
                    rawValue: url.deletingLastPathComponent().lastPathComponent)
                : nil)
    }

    // Revalidation keeps offline bytes, whereas a confirmed replacement retires
    // every size/timestamp/revision of this one account/server/item.
    func revalidate(for accountID: AccountID) {
        validated = validated.filter { $0.accountID != accountID }
        retireRequests { $0.accountID == accountID }
    }

    func invalidate(for url: URL, accountID: AccountID) {
        invalidateVariants(for: url, accountID: accountID, preserving: nil)
    }

    private func invalidateVariants(
        for url: URL, accountID: AccountID, preserving requestID: UUID?
    ) {
        let resource = BookCoverResource(accountID: accountID, url: url)
        if let requestID {
            for key in inFlight.keys.filter({
                $0.resource == resource && inFlight[$0]?.id != requestID
            }) {
                inFlight.removeValue(forKey: key)?.task.cancel()
            }
        } else {
            retireRequests { $0 == resource }
        }
        let keys = memoryTimestamps.keys.filter { $0.resource == resource }
        for key in keys {
            memory.removeObject(forKey: key.memoryKey)
            memoryTimestamps[key] = nil
            memoryDigests[key] = nil
            memoryKeys[accountID]?.remove(key.memoryKey as String)
            validated.remove(key)
        }
        if let directory = resourceDirectory(for: resource) {
            try? FileManager.default.removeItem(at: directory)
            // A persistent tombstone prevents resurrection of pre-policy files.
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try? Data().write(
                to: directory.appendingPathComponent(".invalidated"),
                options: .atomic)
        }
        Self.logger.debug("cover_confirmed_replacement_invalidated")
    }

    private func retireRequests(matching includes: (BookCoverResource) -> Bool)
    {
        for resource in generations.keys.filter(includes) {
            generations[resource] = UUID()
        }
        for key in inFlight.keys.filter({ includes($0.resource) }) {
            let request = inFlight.removeValue(forKey: key)
            request?.task.cancel()
        }
    }

    private func resourceTimestamp(for resource: BookCoverResource) -> Int64 {
        let memoryTimestamp =
            memoryTimestamps.filter { $0.key.resource == resource }.values.max()
            ?? 0
        guard
            let url = resourceDirectory(for: resource)?.appendingPathComponent(
                ".revision"),
            let data = readCacheData(at: url, maximumBytes: 64),
            let text = String(data: data, encoding: .utf8)
        else { return memoryTimestamp }
        return max(memoryTimestamp, Int64(text) ?? 0)
    }

    private func cachedImage(
        for key: BookCoverCacheKey, timestamp: Int64, legacyURL: URL
    ) -> PlatformImage? {
        let timestamp = max(
            timestamp, resourceTimestamp(for: key.resource),
            latestRequested[key.resource] ?? 0)
        if let cachedTimestamp = memoryTimestamps[key],
            cachedTimestamp >= timestamp,
            let image = memory.object(forKey: key.memoryKey)
        {
            return image
        }
        if let cached = loadFromDisk(for: key, legacyURL: legacyURL),
            cached.timestamp >= timestamp,
            let image = PlatformImageSupport.image(from: cached.data)
        {
            storeInMemory(image, timestamp: cached.timestamp, for: key)
            return image
        }
        return nil
    }

    private static func requestURL(_ url: URL, timestamp: Int64) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems?.map {
            $0.name == "ts"
                ? URLQueryItem(name: "ts", value: String(timestamp)) : $0
        }
        components?.queryItems = items
        return components?.url ?? url
    }

    private static func timestamp(_ url: URL) -> Int64 {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "ts" })?.value.flatMap(Int64.init) ?? 0
    }

    func removeAll(for accountID: AccountID) {
        for key in memoryKeys.removeValue(forKey: accountID) ?? [] {
            memory.removeObject(forKey: key as NSString)
        }
        retireRequests { $0.accountID == accountID }
        validated = validated.filter { $0.accountID != accountID }
        memoryDigests = memoryDigests.filter { $0.key.accountID != accountID }
        memoryTimestamps = memoryTimestamps.filter {
            $0.key.accountID != accountID
        }
        if let directory = accountCacheDirectory(for: accountID) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func removeAllForLocalDataReset() throws(BookCoverCacheResetFailure) {
        // Retire every owner before deleting any bytes. A cancellation-ignoring
        // fetch cannot commit after its generation has been removed.
        retireRequests { _ in true }
        clearMemoryCache()
        inFlight = [:]
        generations = [:]
        requestedRevisions = [:]
        latestRequested = [:]
        validated = []
        guard let directory = cacheDirectory else {
            throw .cacheDirectoryUnavailable
        }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError
        {
            // Reset is idempotent when no artwork has been cached.
        } catch {
            reportDiskFailure(error, stage: .removeCacheRoot)
            throw .removalFailed(BookCoverDiskFailureCause(error: error))
        }
    }

    func clearMemoryCache() {
        memory.removeAllObjects()
        memoryKeys = [:]
        memoryTimestamps = [:]
        memoryDigests = [:]
    }

    func setTracer(_ tracer: any RemoteTelemetryTracing) {
        self.tracer = tracer
    }

    func setEndpointRouter(_ endpointRouter: ServerEndpointRouter?) {
        self.endpointRouter = endpointRouter
    }

    private func storeInMemory(
        _ image: PlatformImage,
        timestamp: Int64,
        for key: BookCoverCacheKey
    ) {
        memoryTimestamps[key] = timestamp
        let size = PlatformImageSupport.pixelSize(of: image)
        let width = Double(size.width)
        let height = Double(size.height)
        let maximumPixels = Double(Self.memoryCapacity / 4)
        let pixelCount =
            width.isFinite && height.isFinite && width > 0 && height > 0
            ? min(width * height, maximumPixels)
            : maximumPixels
        memory.setObject(
            image,
            forKey: key.memoryKey,
            cost: max(1, Int(pixelCount) * 4)
        )
        memoryKeys[key.accountID, default: []].insert(
            key.memoryKey as String
        )
    }

    private static func fetchImage(
        _ request: URLRequest,
        using fetch: Fetch,
        endpointRouter: ServerEndpointRouter?,
        tracer: any RemoteTelemetryTracing
    ) async -> LoadedBookCover? {
        let candidates: [ServerEndpointCandidate]
        if let endpointRouter, let url = request.url {
            candidates = await endpointRouter.candidates(for: url)
        } else if let url = request.url {
            candidates = [
                ServerEndpointCandidate(
                    url: url,
                    primary: nil,
                    isLocal: false
                )
            ]
        } else {
            candidates = []
        }
        for candidate in candidates {
            let span = tracer.beginSpan(operation: .httpRequest)
            var result: RemoteTelemetryHTTPResult = .nonHTTPResponse
            defer {
                span.endHTTPCall(
                    RemoteTelemetryHTTPCall(
                        endpoint: .audiobookshelf(.cover), method: .get,
                        result: result))
            }
            do {
                var routedRequest = request
                routedRequest.url = candidate.url
                let (data, response) = try await fetch(routedRequest)
                if let http = response as? HTTPURLResponse {
                    result = .response(statusCode: http.statusCode)
                }
                guard
                    let response = response as? HTTPURLResponse,
                    (200...299).contains(response.statusCode),
                    data.count <= maximumResponseBytes,
                    let image = PlatformImageSupport.image(from: data)
                else {
                    if candidate.isLocal {
                        await endpointRouter?.markLocalUnavailable(candidate)
                        continue
                    }
                    return nil
                }
                await endpointRouter?.recordConnection(
                    candidate,
                    purpose: .cover
                )
                return LoadedBookCover(
                    data: data,
                    image: image
                )
            } catch {
                result = .failure(error)
                if candidate.isLocal {
                    await endpointRouter?.markLocalUnavailable(candidate)
                    continue
                }
                return nil
            }
        }
        return nil
    }

    // Maintainer-approved synchronous filesystem boundary for the scoped #400
    // fix: reads, atomic writes, pruning and deletion remain actor-owned. Native
    // async durable directory/mutation APIs are unavailable in Foundation. #411
    // owns reconsidering execution, awaited cancellation/cleanup and latency;
    // this approval does not extend to other filesystem owners.
    private func readCacheData(at url: URL, maximumBytes: Int) -> Data? {
        guard
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey,
            ]),
            values.isRegularFile == true, let size = values.fileSize,
            (0...maximumBytes).contains(size)
        else { return nil }
        return try? Data(contentsOf: url)
    }

    private func loadFromDisk(for key: BookCoverCacheKey, legacyURL: URL)
        -> PersistedBookCover?
    {
        guard let directory = resourceDirectory(for: key.resource),
            let url = diskURL(for: key)
        else { return nil }
        if let data = readCacheData(
            at: url, maximumBytes: Self.maximumResponseBytes * 2),
            data.count <= Self.maximumResponseBytes * 2,
            let cached = try? JSONDecoder().decode(
                PersistedBookCover.self, from: data),
            cached.data.count <= Self.maximumResponseBytes,
            PlatformImageSupport.image(from: cached.data) != nil
        {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: url.path)
            return cached
        }
        // Preserve existing offline artwork on upgrade; online requests must
        // validate it before use. A replacement tombstone prohibits fallback.
        guard
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(".invalidated").path),
            let legacy = accountCacheDirectory(for: key.accountID)?
                .appendingPathComponent(Self.hash(legacyURL.absoluteString)),
            let data = readCacheData(
                at: legacy, maximumBytes: Self.maximumResponseBytes),
            data.count <= Self.maximumResponseBytes,
            PlatformImageSupport.image(from: data) != nil
        else { return nil }
        return PersistedBookCover(
            timestamp: Self.timestamp(legacyURL), data: data)
    }

    private func persistTimestamp(
        _ timestamp: Int64, for resource: BookCoverResource
    ) {
        guard let directory = resourceDirectory(for: resource) else { return }
        var stage = BookCoverDiskFailureStage.prepareRevisionDirectory
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            stage = .writeRevision
            try Data(String(timestamp).utf8).write(
                to: directory.appendingPathComponent(".revision"),
                options: .atomic)
        } catch {
            reportDiskFailure(error, stage: stage)
        }
    }

    private func storeOnDisk(
        _ data: Data,
        timestamp: Int64,
        for key: BookCoverCacheKey
    ) {
        guard data.count <= Self.maximumResponseBytes,
            let url = diskURL(for: key)
        else {
            return
        }
        var stage = BookCoverDiskFailureStage.prepareVariantDirectory
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            stage = .encodeVariant
            let persisted = try JSONEncoder().encode(
                PersistedBookCover(timestamp: timestamp, data: data))
            // Advance the watermark before publishing payload bytes. If an
            // interrupted write leaves an older payload, it must not become
            // eligible through an older saved metadata snapshot after restart.
            stage = .writeRevision
            try Data(String(timestamp).utf8).write(
                to: url.deletingLastPathComponent().appendingPathComponent(
                    ".revision"), options: .atomic)
            stage = .writeVariant
            try persisted.write(to: url, options: .atomic)
            pruneDiskCache()
        } catch {
            reportDiskFailure(error, stage: stage)
        }
    }

    private func reportDiskFailure(
        _ error: any Error, stage: BookCoverDiskFailureStage
    ) {
        let cause = BookCoverDiskFailureCause(error: error)
        observe(.diskFailure(stage: stage, cause: cause))
        Self.logger.error(
            "cover_disk_failure stage=\(stage.rawValue, privacy: .public) cause=\(cause.diagnosticCode, privacy: .public)"
        )
    }

    private func diskURL(for key: BookCoverCacheKey) -> URL? {
        guard diskCapacity > 0,
            let directory = resourceDirectory(for: key.resource)
        else {
            return nil
        }
        return directory.appendingPathComponent(
            Self.hash(key.url.absoluteString),
            isDirectory: false
        )
    }

    private func resourceDirectory(for resource: BookCoverResource) -> URL? {
        guard diskCapacity > 0 else { return nil }
        return accountCacheDirectory(for: resource.accountID)?
            .appendingPathComponent("v2", isDirectory: true)
            .appendingPathComponent(
                Self.hash(resource.url.absoluteString), isDirectory: true)
    }

    private func accountCacheDirectory(
        for accountID: AccountID
    ) -> URL? {
        cacheDirectory?.appendingPathComponent(
            Self.hash(accountID.rawValue),
            isDirectory: true
        )
    }

    private var cacheDirectory: URL? {
        let root =
            cacheRoot
            ?? FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first
        guard let root else {
            return nil
        }
        return cacheRoot == nil
            ? root.appendingPathComponent("BookCovers", isDirectory: true)
            : root
    }

    private func pruneDiskCache() {
        guard diskCapacity > 0,
            let cacheDirectory,
            let enumerator = FileManager.default.enumerator(
                at: cacheDirectory,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                ],
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }
        var files: [(url: URL, size: Int64, modifiedAt: Date)] = []
        var totalSize: Int64 = 0
        for case let url as URL in enumerator {
            guard
                let values = try? url.resourceValues(
                    forKeys: [
                        .isRegularFileKey,
                        .fileSizeKey,
                        .contentModificationDateKey,
                    ]
                ), values.isRegularFile == true
            else {
                continue
            }
            let size = Int64(max(0, values.fileSize ?? 0))
            let (newTotal, overflowed) =
                totalSize.addingReportingOverflow(size)
            totalSize = overflowed ? .max : newTotal
            files.append(
                (
                    url: url,
                    size: size,
                    modifiedAt: values.contentModificationDate
                        ?? .distantPast
                )
            )
        }
        guard totalSize > Int64(diskCapacity) else {
            return
        }
        for file in files.sorted(by: { $0.modifiedAt < $1.modifiedAt }) {
            do {
                try FileManager.default.removeItem(at: file.url)
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain
                && error.code == NSFileNoSuchFileError
            {
                // An entry already removed by the OS no longer consumes bytes.
            } catch {
                reportDiskFailure(error, stage: .pruneDiskEntry)
                continue
            }
            totalSize -= min(file.size, totalSize)
            if totalSize <= Int64(diskCapacity) {
                break
            }
        }
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

private enum BookCoverLoadState {
    case idle
    case loading
    case loaded(PlatformImage)
    case failed
}

struct BookCoverView: View {
    let accountID: AccountID?
    let url: URL?
    let cornerRadius: CGFloat
    let loadPolicy: BookCoverLoadPolicy
    @State private var state = BookCoverLoadState.idle
    @State private var loadedRequest: BookCoverRequest?

    init(
        accountID: AccountID?,
        server: NormalizedServerURL?,
        itemID: LibraryItemID,
        updatedAtMilliseconds: Int64,
        width: Int,
        height: Int,
        cornerRadius: CGFloat = 8,
        loadPolicy: BookCoverLoadPolicy = .allowNetwork
    ) {
        self.accountID = accountID
        url = BookCoverURL.make(
            server: server,
            itemID: itemID,
            updatedAtMilliseconds: updatedAtMilliseconds,
            width: width,
            height: height
        )
        self.cornerRadius = cornerRadius
        self.loadPolicy = loadPolicy
    }

    init(
        accountID: AccountID?,
        url: URL?,
        cornerRadius: CGFloat = 8,
        loadPolicy: BookCoverLoadPolicy = .allowNetwork
    ) {
        self.accountID = accountID
        self.url = url
        self.cornerRadius = cornerRadius
        self.loadPolicy = loadPolicy
    }

    var body: some View {
        // Keep the loading task attached to a concrete container across state changes.
        Color.clear.overlay {
            switch state {
            case .loaded(let image):
                if loadedRequest?.presentation == request.presentation {
                    PlatformImageSupport.resizableView(for: image)
                        .scaledToFill()
                } else {
                    placeholder.overlay { ProgressView() }
                }
            case .idle, .loading:
                placeholder
                    .overlay {
                        ProgressView()
                    }
            case .failed:
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
        .task(id: request) {
            guard let url else {
                state = .failed
                return
            }
            let loadingRequest = request
            if case .loaded = state {} else { state = .loading }
            let image = await BookCoverImageLoader.shared.image(
                for: url,
                accountID: accountID,
                policy: loadPolicy
            )
            guard !Task.isCancelled, request == loadingRequest else {
                return
            }
            if image == nil, case .loaded = state,
                loadedRequest?.presentation == loadingRequest.presentation
            {
                return
            }
            loadedRequest = loadingRequest
            state = image.map(BookCoverLoadState.loaded) ?? .failed
        }
    }

    private var request: BookCoverRequest {
        BookCoverRequest(
            generation: BookCoverRefresh.shared.generation(
                accountID: accountID, url: url), policy: loadPolicy,
            accountID: accountID, url: url)
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            Image(systemName: "book.closed.fill")
                .font(.title)
                .foregroundStyle(.secondary)
        }
    }
}

private struct BookCoverRequest: Hashable {
    let generation: [UUID?]
    let policy: BookCoverLoadPolicy
    let accountID: AccountID?
    let url: URL?

    var presentation: BookCoverPresentationIdentity {
        BookCoverPresentationIdentity(
            accountID: accountID, url: url, generation: generation)
    }
}

enum PlayableBookCoverState: Equatable, Sendable {
    case idle
    case preparing
    case playing
    case paused

    static func derive(
        target: PlaybackStartTarget?,
        accountID: AccountID,
        itemID: LibraryItemID,
        playbackAccountID: AccountID?,
        playbackItemID: LibraryItemID?,
        playbackState: PlaybackState,
        isPlaybackRequested: Bool
    ) -> Self {
        if target
            == PlaybackStartTarget(
                accountID: accountID,
                itemID: itemID
            )
        {
            return .preparing
        }
        guard playbackAccountID == accountID,
            playbackItemID == itemID
        else {
            return .idle
        }
        switch playbackState {
        case .preparing:
            return .preparing
        case .ready, .buffering, .playing, .paused:
            return isPlaybackRequested ? .playing : .paused
        case .idle, .ended, .failed:
            return .idle
        }
    }
}

struct PlayableBookCoverView: View {
    let accountID: AccountID
    let server: NormalizedServerURL?
    let itemID: LibraryItemID
    let updatedAtMilliseconds: Int64
    let width: Int
    let height: Int
    let cornerRadius: CGFloat
    let loadPolicy: BookCoverLoadPolicy
    let title: String
    let state: PlayableBookCoverState
    let accessibilityIdentifier: String
    let performPlaybackAction: () async -> BrowsingPlaybackActionOutcome
    let handleOutcome: (PlaybackStartOutcome) -> Void

    init(
        accountID: AccountID,
        server: NormalizedServerURL?,
        itemID: LibraryItemID,
        updatedAtMilliseconds: Int64,
        width: Int,
        height: Int,
        cornerRadius: CGFloat = 8,
        loadPolicy: BookCoverLoadPolicy = .allowNetwork,
        title: String,
        state: PlayableBookCoverState,
        accessibilityIdentifier: String,
        performPlaybackAction:
            @escaping () async -> BrowsingPlaybackActionOutcome,
        handleOutcome: @escaping (PlaybackStartOutcome) -> Void
    ) {
        self.accountID = accountID
        self.server = server
        self.itemID = itemID
        self.updatedAtMilliseconds = updatedAtMilliseconds
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.loadPolicy = loadPolicy
        self.title = title
        self.state = state
        self.accessibilityIdentifier = accessibilityIdentifier
        self.performPlaybackAction = performPlaybackAction
        self.handleOutcome = handleOutcome
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            BookCoverView(
                accountID: accountID,
                server: server,
                itemID: itemID,
                updatedAtMilliseconds: updatedAtMilliseconds,
                width: width,
                height: height,
                cornerRadius: cornerRadius,
                loadPolicy: loadPolicy
            )
            .allowsHitTesting(false)

            Button(action: performAction) {
                Group {
                    if state == .preparing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: controlSystemImage)
                            .font(.title)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.68), in: Circle())
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focusable(state != .preparing)
            .disabled(state == .preparing)
            .padding(4)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    private var controlSystemImage: String {
        state == .playing ? "pause.circle.fill" : "play.circle.fill"
    }

    private var accessibilityLabel: String {
        switch state {
        case .idle, .paused:
            "Play \(title)"
        case .preparing:
            "Preparing \(title)"
        case .playing:
            "Pause \(title)"
        }
    }

    private func performAction() {
        guard state != .preparing else { return }
        Task {
            let outcome = await performPlaybackAction()
            if case .start(let startOutcome) = outcome {
                handleOutcome(startOutcome)
            }
        }
    }
}
