import BleatCore
import Foundation
import Observation

enum DownloadModelFailure: Error, Equatable, Sendable {
    case storageUnavailable
    case permissionDenied
    case preparationFailed
    case repairPlanChanged
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)
    case transferFailed

    var message: String {
        switch self {
        case .storageUnavailable:
            "Bleat could not access downloaded media storage."
        case .permissionDenied:
            "This account is not allowed to download that audiobook."
        case .preparationFailed:
            "Bleat could not prepare this audiobook for download."
        case .repairPlanChanged:
            "The server's audio files changed. Delete and download the book again."
        case .insufficientStorage(let requiredBytes, let availableBytes):
            "This download needs \(Self.byteCount(requiredBytes)), but only \(Self.byteCount(availableBytes)) is available."
        case .transferFailed:
            "One or more audio files could not be downloaded."
        }
    }

    private static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: max(value, 0),
            countStyle: .file
        )
    }
}

enum DownloadNetworkPolicy: String, Equatable, Sendable {
    case wifiOnly
    case allowCellular

    var allowsExpensiveNetworkAccess: Bool {
        self == .allowCellular
    }

    func applying(to request: URLRequest) -> URLRequest {
        var request = request
        request.allowsExpensiveNetworkAccess =
            allowsExpensiveNetworkAccess
        return request
    }
}

enum AutomaticDownloadCleanupPolicy:
    String,
    CaseIterable,
    Equatable,
    Identifiable,
    Sendable
{
    case afterTwentyFourHours
    case afterBook
    case afterChapter

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .afterTwentyFourHours:
            "24 Hours After Finishing"
        case .afterBook:
            "After Finishing the Book"
        case .afterChapter:
            "After Finishing Each Chapter"
        }
    }
}

enum AutomaticDownloadActivityKind: Equatable, Sendable {
    case progress
    case bookFinished
}

struct AutomaticDownloadFileRange: Equatable, Sendable {
    let index: Int
    let start: Double
    let end: Double
}

struct AutomaticDownloadActivity: Equatable, Sendable {
    let kind: AutomaticDownloadActivityKind
    let detail: LibraryBookDetail
    let account: ServerAccount
    let currentTime: Double
    let chapters: [PlaybackChapter]
    let fileRanges: [AutomaticDownloadFileRange]
}

enum AutomaticDownloadPlanner {
    static func targetTrackIndexes(
        plan: DownloadPlan,
        activity: AutomaticDownloadActivity,
        lookaheadCount: Int
    ) -> Set<Int> {
        guard !plan.tracks.isEmpty else {
            return []
        }
        if plan.tracks.count == 1 {
            return [plan.tracks[0].index]
        }

        let ranges = resolvedRanges(plan: plan, activity: activity)
        guard !ranges.isEmpty else {
            return Set(
                plan.tracks.prefix(lookaheadCount + 1).map(\.index)
            )
        }

        let currentFilePosition =
            ranges.lastIndex {
                $0.start <= activity.currentTime
            } ?? 0
        let fallbackEnd = min(
            ranges.count,
            currentFilePosition + lookaheadCount + 1
        )
        let fallbackIndexes = ranges[
            currentFilePosition..<fallbackEnd
        ].map(\.index)

        guard
            let currentChapterIndex = activity.chapters.lastIndex(where: {
                $0.start <= activity.currentTime
            })
        else {
            return Set(fallbackIndexes)
        }
        let finalChapterIndex = min(
            activity.chapters.count - 1,
            currentChapterIndex + lookaheadCount
        )
        let windowEnd = activity.chapters[finalChapterIndex].end
        guard windowEnd.isFinite, windowEnd > activity.currentTime else {
            return Set(fallbackIndexes)
        }
        let chapterIndexes = ranges.compactMap { range in
            range.end > activity.currentTime && range.start < windowEnd
                ? range.index
                : nil
        }
        return chapterIndexes.isEmpty
            ? Set(fallbackIndexes)
            : Set(chapterIndexes)
    }

    static func completedTrackIndexes(
        plan: DownloadPlan,
        activity: AutomaticDownloadActivity
    ) -> Set<Int> {
        guard
            let currentChapter = activity.chapters.last(where: {
                $0.start <= activity.currentTime
            })
        else {
            return []
        }
        return Set(
            resolvedRanges(plan: plan, activity: activity)
                .compactMap {
                    $0.end <= currentChapter.start ? $0.index : nil
                }
        )
    }

    private static func resolvedRanges(
        plan: DownloadPlan,
        activity: AutomaticDownloadActivity
    ) -> [AutomaticDownloadFileRange] {
        let planRanges: [AutomaticDownloadFileRange] =
            plan.tracks.compactMap { track in
                guard
                    let start = track.startOffset,
                    let duration = track.duration
                else {
                    return nil
                }
                return AutomaticDownloadFileRange(
                    index: track.index,
                    start: start,
                    end: start + duration
                )
            }
        if planRanges.count == plan.tracks.count {
            return planRanges
        }
        guard activity.fileRanges.count == plan.tracks.count else {
            return []
        }
        return zip(plan.tracks, activity.fileRanges).map { track, range in
            AutomaticDownloadFileRange(
                index: track.index,
                start: range.start,
                end: range.end
            )
        }
    }
}

enum DownloadNetworkDecision: Equatable, Sendable {
    case schedule
    case confirmCellular(expectedBytes: Int64)

    static func decide(
        policy: DownloadNetworkPolicy,
        expectedBytes: Int64,
        largeDownloadThresholdBytes: Int64
    ) -> DownloadNetworkDecision {
        guard policy == .allowCellular,
            expectedBytes >= largeDownloadThresholdBytes
        else {
            return .schedule
        }
        return .confirmCellular(expectedBytes: expectedBytes)
    }
}

struct PendingCellularDownload: Equatable, Sendable {
    let detail: LibraryBookDetail
    let account: ServerAccount
    let plan: DownloadPlan
    let expectedBytes: Int64
}

private struct AutomaticDownloadKey: Hashable {
    let accountID: AccountID
    let itemID: LibraryItemID
}

enum DownloadRepairPlanner {
    static func tracks(
        record: DownloadedBookRecord,
        plan: DownloadPlan
    ) throws(DownloadModelFailure) -> [DownloadTrackPlan] {
        guard plan.itemID == record.manifest.itemID,
            plan.tracks.count == record.manifest.entries.count
        else {
            throw .repairPlanChanged
        }
        let entries = Dictionary(
            uniqueKeysWithValues: record.manifest.entries.map {
                ($0.trackIndex, $0)
            }
        )
        for track in plan.tracks {
            guard let entry = entries[track.index],
                entry.expectedByteLength == track.expectedByteLength,
                entry.destinationEntry == track.destinationEntry
            else {
                throw .repairPlanChanged
            }
        }
        return plan.tracks.filter {
            guard let state = entries[$0.index]?.state else {
                return false
            }
            return state != .complete && state != .downloading
        }
    }
}

@MainActor
@Observable
final class DownloadModel: NSObject, URLSessionDownloadDelegate {
    static let largeDownloadThresholdBytes: Int64 = 100 * 1_024 * 1_024

    private let service: any AppServicing
    private let defaults: UserDefaults
    private let networkPolicyKey = "bleat.downloads.networkPolicy.v1"
    private let automaticLookaheadKey =
        "bleat.downloads.automaticLookahead.v1"
    private let automaticCleanupPolicyKey =
        "bleat.downloads.automaticCleanupPolicy.v1"
    private nonisolated let layout: DownloadStorageLayout?
    private let storage: DownloadStorage?
    private var accounts: [AccountID: ServerAccount] = [:]
    private var deletingDownloadIDs: Set<DownloadID> = []
    private var automaticUpdatesInProgress: Set<AutomaticDownloadKey> = []
    private var pendingAutomaticUpdates:
        [AutomaticDownloadKey: AutomaticDownloadActivity] = [:]
    private var automaticCleanupTask: Task<Void, Never>?
    @ObservationIgnored
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: bleatBackgroundDownloadSessionIdentifier
        )
        configuration.httpMaximumConnectionsPerHost =
            SystemBackgroundDownloadScheduler.defaultMaximumConnectionsPerHost
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        return URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
    }()

    private(set) var records: [DownloadedBookRecord] = []
    private(set) var progress: [DownloadID: Double] = [:]
    private(set) var pausedDownloadIDs: Set<DownloadID> = []
    private(set) var failure: DownloadModelFailure?
    private(set) var networkPolicy: DownloadNetworkPolicy
    private(set) var automaticLookaheadCount: Int
    private(set) var automaticCleanupPolicy: AutomaticDownloadCleanupPolicy
    private(set) var pendingCellularDownload: PendingCellularDownload?

    init(
        service: any AppServicing,
        defaults: UserDefaults = .standard,
        storageRootURL: URL? = nil
    ) {
        self.service = service
        self.defaults = defaults
        networkPolicy =
            defaults.string(
                forKey: "bleat.downloads.networkPolicy.v1"
            )
            .flatMap(DownloadNetworkPolicy.init(rawValue:))
            ?? .wifiOnly
        automaticLookaheadCount = Self.normalizedLookaheadCount(
            defaults.object(forKey: automaticLookaheadKey) == nil
                ? 5
                : defaults.integer(forKey: automaticLookaheadKey)
        )
        automaticCleanupPolicy =
            defaults.string(forKey: automaticCleanupPolicyKey)
            .flatMap(AutomaticDownloadCleanupPolicy.init(rawValue:))
            ?? .afterTwentyFourHours
        do {
            let rootURL: URL
            if let storageRootURL {
                rootURL = storageRootURL
            } else {
                guard
                    let supportURL = FileManager.default.urls(
                        for: .applicationSupportDirectory,
                        in: .userDomainMask
                    ).first
                else {
                    throw DownloadStorageError.invalidRoot
                }
                rootURL = supportURL.appendingPathComponent(
                    "Bleat/Downloads",
                    isDirectory: true
                )
            }
            let layout = try DownloadStorageLayout(
                rootURL: rootURL
            )
            self.layout = layout
            storage = DownloadStorage(layout: layout)
        } catch {
            layout = nil
            storage = nil
        }
        super.init()
    }

    func start(account: ServerAccount?) async {
        if let account {
            accounts[account.id] = account
        }
        _ = session
        let tasks = await session.allTasks
        for task in tasks where task.state == .suspended {
            guard let description = task.taskDescription,
                let identity =
                    try? DownloadTaskIdentity
                    .decodeTaskDescription(description)
            else {
                continue
            }
            pausedDownloadIDs.insert(identity.downloadID)
        }
        await refresh()
        await cleanupExpiredAutomaticDownloads()
        scheduleAutomaticCleanup()
    }

    func download(
        detail: LibraryBookDetail,
        account: ServerAccount
    ) async {
        let availability = BookActionAvailability(
            user: account.user,
            detail: detail
        )
        guard availability.visibleActions.contains(.download) else {
            failure = .permissionDenied
            return
        }
        guard let storage else {
            failure = .storageUnavailable
            return
        }
        accounts[account.id] = account
        failure = nil
        do {
            let plan = try await service.downloadPlan(
                for: account,
                itemID: detail.id
            )
            let requirement = try await storage.preflight(plan: plan)
            switch DownloadNetworkDecision.decide(
                policy: networkPolicy,
                expectedBytes: requirement.expectedBytes,
                largeDownloadThresholdBytes:
                    Self.largeDownloadThresholdBytes
            ) {
            case .confirmCellular(let expectedBytes):
                pendingCellularDownload = PendingCellularDownload(
                    detail: detail,
                    account: account,
                    plan: plan,
                    expectedBytes: expectedBytes
                )
            case .schedule:
                try await schedule(
                    plan: plan,
                    detail: detail,
                    account: account,
                    storage: storage
                )
            }
            await refresh()
        } catch let error as DownloadStorageError {
            failure = storageFailure(error)
            await refresh()
        } catch {
            failure = .preparationFailed
            await refresh()
        }
    }

    func setNetworkPolicy(_ policy: DownloadNetworkPolicy) {
        networkPolicy = policy
        defaults.set(policy.rawValue, forKey: networkPolicyKey)
    }

    func setAutomaticLookaheadCount(_ count: Int) {
        automaticLookaheadCount = Self.normalizedLookaheadCount(count)
        defaults.set(
            automaticLookaheadCount,
            forKey: automaticLookaheadKey
        )
    }

    func setAutomaticCleanupPolicy(
        _ policy: AutomaticDownloadCleanupPolicy
    ) {
        automaticCleanupPolicy = policy
        defaults.set(policy.rawValue, forKey: automaticCleanupPolicyKey)
        Task { @MainActor [weak self] in
            await self?.applyCleanupPolicyToFinishedDownloads()
        }
    }

    func handleAutomaticPlaybackActivity(
        _ activity: AutomaticDownloadActivity
    ) async {
        let key = AutomaticDownloadKey(
            accountID: activity.account.id,
            itemID: activity.detail.id
        )
        pendingAutomaticUpdates[key] = activity
        guard !automaticUpdatesInProgress.contains(key) else {
            return
        }
        automaticUpdatesInProgress.insert(key)
        defer {
            automaticUpdatesInProgress.remove(key)
        }
        while let pending = pendingAutomaticUpdates.removeValue(forKey: key) {
            await applyAutomaticPlaybackActivity(pending)
        }
    }

    func confirmCellularDownload() async {
        guard let pending = pendingCellularDownload,
            let storage
        else {
            return
        }
        pendingCellularDownload = nil
        failure = nil
        do {
            _ = try await storage.preflight(plan: pending.plan)
            try await schedule(
                plan: pending.plan,
                detail: pending.detail,
                account: pending.account,
                storage: storage
            )
            await refresh()
        } catch let error as DownloadStorageError {
            failure = storageFailure(error)
        } catch {
            failure = .preparationFailed
        }
    }

    func cancelCellularDownload() {
        pendingCellularDownload = nil
    }

    func keepFullBook(
        _ record: DownloadedBookRecord,
        account: ServerAccount
    ) async {
        guard record.manifest.accountID == account.id,
            record.manifest.purpose == .automaticCache,
            let storage
        else {
            return
        }
        failure = nil
        accounts[account.id] = account
        do {
            let plan = try await service.downloadPlan(
                for: account,
                itemID: record.manifest.itemID
            )
            let latest = try await storage.promoteToManual(record)
            let tracks = try DownloadRepairPlanner.tracks(
                record: latest,
                plan: plan
            )
            _ = try await storage.preflight(tracks: tracks)
            try await schedule(
                plan: plan,
                detail: latest.detail,
                account: account,
                storage: storage,
                tracks: tracks,
                downloadID: latest.manifest.downloadID
            )
            await refresh()
        } catch let error as DownloadModelFailure {
            failure = error
        } catch let error as DownloadStorageError {
            failure = storageFailure(error)
        } catch {
            failure = .preparationFailed
        }
    }

    private func applyAutomaticPlaybackActivity(
        _ activity: AutomaticDownloadActivity
    ) async {
        let availability = BookActionAvailability(
            user: activity.account.user,
            detail: activity.detail
        )
        guard availability.visibleActions.contains(.download),
            let storage
        else {
            return
        }
        accounts[activity.account.id] = activity.account

        if activity.kind == .bookFinished {
            await finishAutomaticDownload(
                accountID: activity.account.id,
                itemID: activity.detail.id,
                storage: storage
            )
            return
        }

        do {
            let plan = try await service.downloadPlan(
                for: activity.account,
                itemID: activity.detail.id
            )
            var record = record(
                accountID: activity.account.id,
                itemID: activity.detail.id
            )
            if record?.manifest.purpose == .manual {
                return
            }
            if let existing = record,
                existing.manifest.bookFinishedAt != nil
            {
                record = try await storage.markBookFinished(
                    existing,
                    at: nil
                )
            }

            if automaticCleanupPolicy == .afterChapter,
                let existing = record
            {
                let completedIndexes =
                    AutomaticDownloadPlanner.completedTrackIndexes(
                        plan: plan,
                        activity: activity
                    )
                if !completedIndexes.isEmpty {
                    record = try await storage.removeCompletedTracks(
                        from: existing,
                        trackIndexes: completedIndexes
                    )
                }
            }

            let targets = AutomaticDownloadPlanner.targetTrackIndexes(
                plan: plan,
                activity: activity,
                lookaheadCount: automaticLookaheadCount
            )
            let existingStates = Dictionary(
                uniqueKeysWithValues:
                    record?.manifest.entries.map {
                        ($0.trackIndex, $0.state)
                    } ?? []
            )
            let tracks = plan.tracks.filter {
                targets.contains($0.index)
                    && existingStates[$0.index] != .complete
                    && existingStates[$0.index] != .downloading
            }
            guard !tracks.isEmpty else {
                await refresh()
                return
            }
            _ = try await storage.preflight(tracks: tracks)
            try await schedule(
                plan: plan,
                detail: activity.detail,
                account: activity.account,
                storage: storage,
                purpose: .automaticCache,
                tracks: tracks,
                downloadID: record?.manifest.downloadID
            )
            await refresh()
        } catch {
            await refresh()
        }
    }

    private func finishAutomaticDownload(
        accountID: AccountID,
        itemID: LibraryItemID,
        storage: DownloadStorage
    ) async {
        guard
            let record = record(accountID: accountID, itemID: itemID),
            record.manifest.purpose == .automaticCache
        else {
            return
        }
        switch automaticCleanupPolicy {
        case .afterChapter, .afterBook:
            await remove(record)
        case .afterTwentyFourHours:
            do {
                _ = try await storage.markBookFinished(
                    record,
                    at: Date()
                )
                await refresh()
                scheduleAutomaticCleanup()
            } catch {
                failure = .transferFailed
            }
        }
    }

    private func applyCleanupPolicyToFinishedDownloads() async {
        switch automaticCleanupPolicy {
        case .afterChapter, .afterBook:
            let finished = records.filter {
                $0.manifest.purpose == .automaticCache
                    && $0.manifest.bookFinishedAt != nil
            }
            for record in finished {
                await remove(record)
            }
        case .afterTwentyFourHours:
            await cleanupExpiredAutomaticDownloads()
            scheduleAutomaticCleanup()
        }
    }

    private func cleanupExpiredAutomaticDownloads(
        now: Date = Date()
    ) async {
        let deadline = now.addingTimeInterval(-24 * 60 * 60)
        let expired = records.filter {
            $0.manifest.purpose == .automaticCache
                && ($0.manifest.bookFinishedAt ?? .distantFuture) <= deadline
        }
        for record in expired {
            await remove(record)
        }
    }

    private func scheduleAutomaticCleanup(now: Date = Date()) {
        automaticCleanupTask?.cancel()
        automaticCleanupTask = nil
        let cleanupDates: [Date] = records.compactMap { record in
            guard record.manifest.purpose == .automaticCache,
                let finishedAt = record.manifest.bookFinishedAt
            else {
                return nil
            }
            return finishedAt.addingTimeInterval(24 * 60 * 60)
        }
        guard automaticCleanupPolicy == .afterTwentyFourHours,
            let nextDate = cleanupDates.min()
        else {
            return
        }
        let delay = max(nextDate.timeIntervalSince(now), 0)
        automaticCleanupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else {
                return
            }
            await self?.cleanupExpiredAutomaticDownloads()
            self?.scheduleAutomaticCleanup()
        }
    }

    private static func normalizedLookaheadCount(_ count: Int) -> Int {
        min(max(count, 1), 20)
    }

    private func schedule(
        plan: DownloadPlan,
        detail: LibraryBookDetail,
        account: ServerAccount,
        storage: DownloadStorage,
        purpose: DownloadPurpose = .manual,
        tracks: [DownloadTrackPlan]? = nil,
        downloadID: DownloadID? = nil
    ) async throws {
        let resolvedDownloadID =
            downloadID
            ?? DownloadID(rawValue: UUID().uuidString.lowercased())
        if downloadID == nil {
            _ = try await storage.create(
                downloadID: resolvedDownloadID,
                accountID: account.id,
                plan: plan,
                detail: detail,
                purpose: purpose
            )
        }
        for track in tracks ?? plan.tracks {
            let identity = try DownloadTaskIdentity(
                downloadID: resolvedDownloadID,
                accountID: account.id,
                itemID: detail.id,
                track: track
            )
            let authorizedRequest =
                try await service.authorizedDownloadRequest(
                    for: account,
                    identity: identity
                )
            let task = session.downloadTask(
                with: networkPolicy.applying(to: authorizedRequest)
            )
            task.taskDescription = try identity.taskDescription()
            task.resume()
            _ = try await storage.markDownloading(identity)
        }
    }

    func remove(_ record: DownloadedBookRecord) async {
        guard let storage else {
            failure = .storageUnavailable
            return
        }
        failure = nil
        deletingDownloadIDs.insert(record.manifest.downloadID)
        let tasks = await session.allTasks
        for task in tasks {
            guard let description = task.taskDescription,
                let identity =
                    try? DownloadTaskIdentity
                    .decodeTaskDescription(description),
                identity.downloadID == record.manifest.downloadID
            else {
                continue
            }
            task.cancel()
        }
        do {
            try await storage.remove(record)
            progress[record.manifest.downloadID] = nil
            pausedDownloadIDs.remove(record.manifest.downloadID)
            await refresh()
        } catch {
            failure = .transferFailed
        }
    }

    func removeAll(
        excluding protectedDownloadID: DownloadID? = nil
    ) async {
        let removableRecords = records.filter {
            $0.manifest.downloadID != protectedDownloadID
        }
        for record in removableRecords {
            await remove(record)
        }
    }

    func cancel(_ record: DownloadedBookRecord) async {
        let tasks = await session.allTasks
        for task in tasks {
            guard let description = task.taskDescription,
                let identity =
                    try? DownloadTaskIdentity
                    .decodeTaskDescription(description),
                identity.downloadID == record.manifest.downloadID
            else {
                continue
            }
            task.cancel()
            if let storage {
                _ = try? await storage.markFailed(identity)
            }
        }
        failure = nil
        pausedDownloadIDs.remove(record.manifest.downloadID)
        await refresh()
    }

    func pause(_ record: DownloadedBookRecord) async {
        await setSuspended(true, record: record)
    }

    func resume(_ record: DownloadedBookRecord) async {
        await setSuspended(false, record: record)
    }

    func repair(
        _ record: DownloadedBookRecord,
        account: ServerAccount
    ) async {
        guard record.manifest.accountID == account.id else {
            failure = .permissionDenied
            return
        }
        guard let storage else {
            failure = .storageUnavailable
            return
        }
        failure = nil
        accounts[account.id] = account
        do {
            let plan = try await service.downloadPlan(
                for: account,
                itemID: record.manifest.itemID
            )
            let tracks = try DownloadRepairPlanner.tracks(
                record: record,
                plan: plan
            )
            _ = try await storage.preflight(tracks: tracks)
            for track in tracks {
                let identity = try DownloadTaskIdentity(
                    downloadID: record.manifest.downloadID,
                    accountID: account.id,
                    itemID: record.manifest.itemID,
                    track: track
                )
                let request = try await service.authorizedDownloadRequest(
                    for: account,
                    identity: identity
                )
                let task = session.downloadTask(
                    with: networkPolicy.applying(to: request)
                )
                task.taskDescription = try identity.taskDescription()
                task.resume()
                _ = try await storage.markDownloading(identity)
            }
            await refresh()
        } catch let error as DownloadModelFailure {
            failure = error
        } catch let error as DownloadStorageError {
            failure = storageFailure(error)
        } catch {
            failure = .preparationFailed
        }
    }

    private func storageFailure(
        _ error: DownloadStorageError
    ) -> DownloadModelFailure {
        switch error {
        case .insufficientSpace(
            let requiredBytes,
            let availableBytes
        ):
            .insufficientStorage(
                requiredBytes: requiredBytes,
                availableBytes: availableBytes
            )
        default:
            .preparationFailed
        }
    }

    private func setSuspended(
        _ suspended: Bool,
        record: DownloadedBookRecord
    ) async {
        let tasks = await session.allTasks
        var matched = false
        for task in tasks {
            guard let description = task.taskDescription,
                let identity =
                    try? DownloadTaskIdentity
                    .decodeTaskDescription(description),
                identity.downloadID == record.manifest.downloadID
            else {
                continue
            }
            matched = true
            if suspended {
                task.suspend()
            } else {
                task.resume()
            }
        }
        guard matched else {
            return
        }
        if suspended {
            pausedDownloadIDs.insert(record.manifest.downloadID)
        } else {
            pausedDownloadIDs.remove(record.manifest.downloadID)
        }
    }

    func removeAll(for accountID: AccountID) async {
        let tasks = await session.allTasks
        for task in tasks {
            guard let description = task.taskDescription,
                let identity =
                    try? DownloadTaskIdentity
                    .decodeTaskDescription(description),
                identity.accountID == accountID
            else {
                continue
            }
            task.cancel()
        }
        let accountRecords = records.filter {
            $0.manifest.accountID == accountID
        }
        for record in accountRecords {
            await remove(record)
        }
        accounts[accountID] = nil
    }

    func retainDownloadsAndDetachAccount(
        _ accountID: AccountID
    ) async {
        let accountDownloadIDs = Set(
            records.lazy
                .filter { $0.manifest.accountID == accountID }
                .map(\.manifest.downloadID)
        )
        let tasks = await session.allTasks
        for task in tasks {
            guard let description = task.taskDescription,
                let identity =
                    try? DownloadTaskIdentity
                    .decodeTaskDescription(description),
                identity.accountID == accountID
            else {
                continue
            }
            task.cancel()
            if let storage {
                _ = try? await storage.markFailed(identity)
            }
        }
        for downloadID in accountDownloadIDs {
            progress[downloadID] = nil
            pausedDownloadIDs.remove(downloadID)
        }
        accounts[accountID] = nil
        await refresh()
    }

    func record(
        accountID: AccountID,
        itemID: LibraryItemID
    ) -> DownloadedBookRecord? {
        records.first {
            $0.manifest.accountID == accountID
                && $0.manifest.itemID == itemID
        }
    }

    func localTrackURLs(
        for record: DownloadedBookRecord
    ) async throws(DownloadModelFailure) -> [URL] {
        guard let storage else {
            throw .storageUnavailable
        }
        do {
            return try await storage.localTrackURLs(for: record)
        } catch {
            await refresh()
            throw .transferFailed
        }
    }

    private func refresh() async {
        guard let storage else {
            failure = .storageUnavailable
            return
        }
        do {
            records = try await storage.records()
        } catch {
            failure = .storageUnavailable
        }
    }

    private func acceptPlacement(
        identity: DownloadTaskIdentity,
        observedByteLength: Int64
    ) async {
        guard let storage else {
            failure = .storageUnavailable
            return
        }
        do {
            _ = try await storage.markComplete(
                identity,
                observedByteLength: observedByteLength
            )
            await refresh()
        } catch {
            _ = try? await storage.markFailed(identity)
            failure = .transferFailed
            await refresh()
        }
    }

    private func rejectPlacement(
        identity: DownloadTaskIdentity
    ) async {
        if let storage {
            _ = try? await storage.markFailed(identity)
        }
        failure = .transferFailed
        await refresh()
    }

    private func handleCompletion(
        task: URLSessionTask,
        error: (any Error)?
    ) async {
        guard let description = task.taskDescription,
            let identity =
                try? DownloadTaskIdentity
                .decodeTaskDescription(description),
            let response = task.response as? HTTPURLResponse
        else {
            return
        }
        guard !deletingDownloadIDs.contains(identity.downloadID) else {
            return
        }
        if (200..<300).contains(response.statusCode), error == nil {
            return
        }
        if response.statusCode == 401,
            let request = task.originalRequest,
            let account = accounts[identity.accountID]
        {
            do {
                let replacement =
                    try await service.replacementDownloadRequest(
                        for: account,
                        identity: identity,
                        rejectedRequest: request
                    )
                let replacementTask = session.downloadTask(
                    with: networkPolicy.applying(to: replacement)
                )
                replacementTask.taskDescription = description
                replacementTask.resume()
                return
            } catch {
                failure = .transferFailed
            }
        } else if error != nil || !(200..<300).contains(response.statusCode) {
            failure = .transferFailed
        }
        if let storage {
            _ = try? await storage.markFailed(identity)
        }
        await refresh()
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response as? HTTPURLResponse,
            (200..<300).contains(response.statusCode),
            let description = downloadTask.taskDescription,
            let identity =
                try? DownloadTaskIdentity
                .decodeTaskDescription(description),
            let layout
        else {
            return
        }
        let result = Result {
            try layout.placeDownloadedFile(
                from: location,
                identity: identity
            )
        }
        Task { @MainActor [weak self] in
            switch result {
            case .success(let observed):
                await self?.acceptPlacement(
                    identity: identity,
                    observedByteLength: observed
                )
            case .failure:
                await self?.rejectPlacement(identity: identity)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            await self?.handleCompletion(task: task, error: error)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0,
            let description = downloadTask.taskDescription,
            let identity =
                try? DownloadTaskIdentity
                .decodeTaskDescription(description)
        else {
            return
        }
        let value = min(
            max(
                Double(totalBytesWritten)
                    / Double(totalBytesExpectedToWrite),
                0
            ),
            1
        )
        Task { @MainActor [weak self] in
            guard
                self?.deletingDownloadIDs.contains(
                    identity.downloadID
                ) == false
            else {
                return
            }
            self?.progress[identity.downloadID] = value
        }
    }

    nonisolated func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession
    ) {
        Task { @MainActor in
            let completion =
                BleatAppDelegate.backgroundDownloadCompletion
            BleatAppDelegate.backgroundDownloadCompletion = nil
            completion?()
        }
    }
}
