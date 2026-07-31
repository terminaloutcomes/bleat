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
    case playbackNeedsBandwidth
    case playbackReleasedBandwidth
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
    enum Kind: Equatable, Sendable {
        case create
        case promote(DownloadID)
    }

    let kind: Kind
    let detail: LibraryBookDetail
    let account: ServerAccount
    let plan: DownloadPlan
    let expectedBytes: Int64
}

private struct AutomaticDownloadKey: Hashable {
    let accountID: AccountID
    let itemID: LibraryItemID
}

private struct AutomaticDownloadTaskKey: Hashable {
    let downloadID: DownloadID
    let trackIndex: Int

    init(_ identity: DownloadTaskIdentity) {
        downloadID = identity.downloadID
        trackIndex = identity.trackIndex
    }
}

enum DownloadRepairScope: Equatable, Sendable {
    case record
    case fullBook
}

enum DownloadRepairPlanner {
    static func tracks(
        record: DownloadedBookRecord,
        plan: DownloadPlan,
        scope: DownloadRepairScope = .record
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
        let targetIndexes: Set<Int>
        switch scope {
        case .record:
            targetIndexes =
                record.manifest.purpose == .automaticCache
                ? record.manifest.automaticTargetTrackIndexes ?? []
                : Set(plan.tracks.map(\.index))
        case .fullBook:
            targetIndexes = Set(plan.tracks.map(\.index))
        }
        guard !targetIndexes.isEmpty else {
            throw .repairPlanChanged
        }
        return plan.tracks.filter {
            guard targetIndexes.contains($0.index) else {
                return false
            }
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
    private let diagnostics: any DiagnosticRecording
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
    private var latestAutomaticProgress:
        [AutomaticDownloadKey: AutomaticDownloadActivity] = [:]
    private var playbackBlockedAutomaticDownloads: Set<AutomaticDownloadKey> =
        []
    private var playbackSuspendedDownloadIDs: Set<DownloadID> = []
    private var supersededAutomaticTasks: Set<AutomaticDownloadTaskKey> = []
    private var transferredBytesByTrack: [DownloadID: [Int: Int64]] = [:]
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
        storageRootURL: URL? = nil,
        diagnostics: any DiagnosticRecording =
            SystemDiagnosticRecorder.shared
    ) {
        self.service = service
        self.diagnostics = diagnostics
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
        await diagnostics.record(
            .started(.restoreDownloads, category: .download)
        )
        if let account {
            accounts[account.id] = account
        }
        _ = session
        await refresh()
        await discardLegacyAutomaticCaches()
        let tasks = await session.allTasks
        for task in tasks where task.state == .suspended {
            guard let description = task.taskDescription,
                let identity =
                    try? DownloadTaskIdentity
                    .decodeTaskDescription(description)
            else {
                continue
            }
            if record(downloadID: identity.downloadID)?
                .manifest.purpose == .automaticCache
            {
                if let url = task.currentRequest?.url
                    ?? task.originalRequest?.url
                {
                    await service.recordServerActivity(
                        url: url,
                        purpose: .download
                    )
                }
                task.resume()
            } else {
                pausedDownloadIDs.insert(identity.downloadID)
            }
        }
        await cleanupExpiredAutomaticDownloads()
        scheduleAutomaticCleanup()
        await diagnostics.record(
            .completed(
                .restoreDownloads,
                category: .download,
                count: records.count
            )
        )
    }

    func download(
        detail: LibraryBookDetail,
        account: ServerAccount
    ) async {
        await diagnostics.record(
            .started(.planDownload, category: .download)
        )
        let availability = BookActionAvailability(
            user: account.user,
            detail: detail
        )
        guard availability.visibleActions.contains(.download) else {
            failure = .permissionDenied
            await diagnostics.record(
                .failed(
                    .planDownload,
                    category: .download,
                    failureCode: .mediaUnavailable
                )
            )
            return
        }
        guard let storage else {
            failure = .storageUnavailable
            await diagnostics.record(
                .failed(
                    .planDownload,
                    category: .download,
                    failureCode: .persistenceUnavailable
                )
            )
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
                    kind: .create,
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
            await diagnostics.record(
                .completed(.planDownload, category: .download)
            )
        } catch let error as DownloadStorageError {
            failure = storageFailure(error)
            await refresh()
            await diagnostics.record(
                .failed(
                    .planDownload,
                    category: .download,
                    failureCode: .persistenceUnavailable
                )
            )
        } catch {
            failure = .preparationFailed
            await refresh()
            await diagnostics.record(
                .failed(
                    .planDownload,
                    category: .download,
                    failureCode: .mediaUnavailable
                )
            )
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

    func reloadSyncedPreferences() {
        networkPolicy =
            defaults.string(forKey: networkPolicyKey)
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
        scheduleAutomaticCleanup()
    }

    func handleAutomaticPlaybackActivity(
        _ activity: AutomaticDownloadActivity
    ) async {
        let key = AutomaticDownloadKey(
            accountID: activity.account.id,
            itemID: activity.detail.id
        )
        switch activity.kind {
        case .playbackNeedsBandwidth:
            await setAutomaticDownloadsBlocked(true, for: key)
            return
        case .playbackReleasedBandwidth:
            await setAutomaticDownloadsBlocked(false, for: key)
            if let latest = latestAutomaticProgress[key] {
                await handleAutomaticPlaybackActivity(latest)
            }
            return
        case .progress:
            latestAutomaticProgress[key] = activity
            await setAutomaticDownloadsBlocked(false, for: key)
        case .bookFinished:
            latestAutomaticProgress[key] = nil
            await setAutomaticDownloadsBlocked(false, for: key)
        }
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
            switch pending.kind {
            case .create:
                _ = try await storage.preflight(plan: pending.plan)
                try await schedule(
                    plan: pending.plan,
                    detail: pending.detail,
                    account: pending.account,
                    storage: storage
                )
            case .promote(let downloadID):
                guard let record = record(downloadID: downloadID) else {
                    throw DownloadStorageError.recordNotFound
                }
                let tracks = try DownloadRepairPlanner.tracks(
                    record: record,
                    plan: pending.plan,
                    scope: .fullBook
                )
                _ = try await storage.preflight(tracks: tracks)
                try await promote(
                    record,
                    plan: pending.plan,
                    tracks: tracks,
                    account: pending.account,
                    storage: storage
                )
            }
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

    func downloadFullBook(
        _ record: DownloadedBookRecord,
        account: ServerAccount
    ) async {
        guard record.manifest.accountID == account.id,
            record.manifest.purpose == .automaticCache,
            let storage
        else {
            failure = .preparationFailed
            return
        }
        let availability = BookActionAvailability(
            user: account.user,
            detail: record.detail
        )
        guard availability.visibleActions.contains(.download) else {
            failure = .permissionDenied
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
                plan: plan,
                scope: .fullBook
            )
            _ = try await storage.preflight(tracks: tracks)
            let fullBookBytes =
                try DownloadStorageRequirement(plan: plan).expectedBytes
            switch DownloadNetworkDecision.decide(
                policy: networkPolicy,
                expectedBytes: fullBookBytes,
                largeDownloadThresholdBytes:
                    Self.largeDownloadThresholdBytes
            ) {
            case .confirmCellular(let expectedBytes):
                pendingCellularDownload = PendingCellularDownload(
                    kind: .promote(record.manifest.downloadID),
                    detail: record.detail,
                    account: account,
                    plan: plan,
                    expectedBytes: expectedBytes
                )
            case .schedule:
                try await promote(
                    record,
                    plan: plan,
                    tracks: tracks,
                    account: account,
                    storage: storage
                )
            }
            await refresh()
        } catch let error as DownloadStorageError {
            failure = storageFailure(error)
        } catch let error as DownloadModelFailure {
            failure = error
        } catch {
            failure = .preparationFailed
        }
    }

    private func promote(
        _ record: DownloadedBookRecord,
        plan: DownloadPlan,
        tracks: [DownloadTrackPlan],
        account: ServerAccount,
        storage: DownloadStorage
    ) async throws {
        let promoted = try await storage.promoteToManual(record)
        guard !tracks.isEmpty else {
            return
        }
        try await schedule(
            plan: plan,
            detail: promoted.detail,
            account: account,
            storage: storage,
            purpose: .manual,
            tracks: tracks,
            downloadID: promoted.manifest.downloadID
        )
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

            let targets = AutomaticDownloadPlanner.targetTrackIndexes(
                plan: plan,
                activity: activity,
                lookaheadCount: automaticLookaheadCount
            )
            guard !targets.isEmpty else {
                return
            }
            if let existing = record {
                record = try await storage.updateAutomaticWindow(
                    existing,
                    targetTrackIndexes: targets
                )
                await cancelObsoleteAutomaticTasks(
                    for: existing,
                    retaining: targets,
                    storage: storage
                )
                await refresh()
                record =
                    self.record(
                        downloadID: existing.manifest.downloadID
                    ) ?? record
            }

            if automaticCleanupPolicy == .afterChapter,
                let existing = record
            {
                let completedIndexes =
                    AutomaticDownloadPlanner.completedTrackIndexes(
                        plan: plan,
                        activity: activity
                    ).subtracting(targets)
                if !completedIndexes.isEmpty {
                    record = try await storage.removeCompletedTracks(
                        from: existing,
                        trackIndexes: completedIndexes
                    )
                }
            }

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
                tracks: Array(tracks.prefix(1)),
                downloadID: record?.manifest.downloadID,
                automaticTargetTrackIndexes: targets
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

    private func discardLegacyAutomaticCaches() async {
        guard let storage else {
            return
        }
        let legacyRecords = records.filter {
            $0.manifest.isLegacyAutomaticCache
        }
        guard !legacyRecords.isEmpty else {
            return
        }
        let legacyIDs = Set(
            legacyRecords.map(\.manifest.downloadID)
        )
        deletingDownloadIDs.formUnion(legacyIDs)
        let tasks = await session.allTasks
        for task in tasks {
            guard let description = task.taskDescription,
                let identity =
                    try? DownloadTaskIdentity
                    .decodeTaskDescription(description),
                legacyIDs.contains(identity.downloadID)
            else {
                continue
            }
            task.cancel()
        }
        for record in legacyRecords {
            try? await storage.remove(record)
            progress[record.manifest.downloadID] = nil
            transferredBytesByTrack[record.manifest.downloadID] = nil
            pausedDownloadIDs.remove(record.manifest.downloadID)
            playbackSuspendedDownloadIDs.remove(
                record.manifest.downloadID
            )
        }
        await refresh()
    }

    private func cancelObsoleteAutomaticTasks(
        for record: DownloadedBookRecord,
        retaining targetTrackIndexes: Set<Int>,
        storage: DownloadStorage
    ) async {
        let states = Dictionary(
            uniqueKeysWithValues: record.manifest.entries.map {
                ($0.trackIndex, $0.state)
            }
        )
        let tasks = await session.allTasks
        for task in tasks {
            guard let description = task.taskDescription,
                let identity =
                    try? DownloadTaskIdentity
                    .decodeTaskDescription(description),
                identity.downloadID == record.manifest.downloadID,
                !targetTrackIndexes.contains(identity.trackIndex)
            else {
                continue
            }
            supersededAutomaticTasks.insert(
                AutomaticDownloadTaskKey(identity)
            )
            task.cancel()
            if states[identity.trackIndex] == .downloading {
                _ = try? await storage.markQueued(identity)
            }
            clearTransferredBytes(for: identity)
        }
    }

    private func schedule(
        plan: DownloadPlan,
        detail: LibraryBookDetail,
        account: ServerAccount,
        storage: DownloadStorage,
        purpose: DownloadPurpose = .manual,
        tracks: [DownloadTrackPlan]? = nil,
        downloadID: DownloadID? = nil,
        automaticTargetTrackIndexes: Set<Int>? = nil
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
                purpose: purpose,
                automaticTargetTrackIndexes:
                    automaticTargetTrackIndexes
            )
        }
        for track in tracks ?? plan.tracks {
            let identity = try DownloadTaskIdentity(
                downloadID: resolvedDownloadID,
                accountID: account.id,
                itemID: detail.id,
                track: track
            )
            supersededAutomaticTasks.remove(
                AutomaticDownloadTaskKey(identity)
            )
            var authorizedRequest =
                try await service.authorizedDownloadRequest(
                    for: account,
                    identity: identity
                )
            if purpose == .automaticCache {
                authorizedRequest.networkServiceType = .background
            }
            let task = session.downloadTask(
                with: networkPolicy.applying(to: authorizedRequest)
            )
            task.taskDescription = try identity.taskDescription()
            task.priority =
                purpose == .automaticCache
                ? URLSessionTask.lowPriority
                : URLSessionTask.defaultPriority
            let key = AutomaticDownloadKey(
                accountID: account.id,
                itemID: detail.id
            )
            if purpose == .automaticCache,
                playbackBlockedAutomaticDownloads.contains(key)
            {
                playbackSuspendedDownloadIDs.insert(
                    resolvedDownloadID
                )
            } else {
                task.resume()
            }
            _ = try await storage.markDownloading(identity)
        }
    }

    @discardableResult
    func remove(_ record: DownloadedBookRecord) async -> Bool {
        guard let storage else {
            failure = .storageUnavailable
            return false
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
            transferredBytesByTrack[record.manifest.downloadID] = nil
            pausedDownloadIDs.remove(record.manifest.downloadID)
            playbackSuspendedDownloadIDs.remove(
                record.manifest.downloadID
            )
            await refresh()
            return true
        } catch {
            failure = .transferFailed
            return false
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
        await diagnostics.record(
            .started(.cancelDownload, category: .download)
        )
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
        progress[record.manifest.downloadID] = nil
        transferredBytesByTrack[record.manifest.downloadID] = nil
        pausedDownloadIDs.remove(record.manifest.downloadID)
        playbackSuspendedDownloadIDs.remove(
            record.manifest.downloadID
        )
        await refresh()
        await diagnostics.record(
            .completed(.cancelDownload, category: .download)
        )
    }

    func pause(_ record: DownloadedBookRecord) async {
        await diagnostics.record(
            .started(.pauseDownload, category: .download)
        )
        await setSuspended(true, record: record)
        await diagnostics.record(
            .completed(.pauseDownload, category: .download)
        )
    }

    func resume(_ record: DownloadedBookRecord) async {
        await diagnostics.record(
            .started(.resumeDownload, category: .download)
        )
        await setSuspended(false, record: record)
        await diagnostics.record(
            .completed(.resumeDownload, category: .download)
        )
    }

    func repair(
        _ record: DownloadedBookRecord,
        account: ServerAccount
    ) async {
        await diagnostics.record(
            .started(.repairDownload, category: .download)
        )
        guard record.manifest.accountID == account.id else {
            failure = .permissionDenied
            await diagnostics.record(
                .failed(
                    .repairDownload,
                    category: .download,
                    failureCode: .mediaUnavailable
                )
            )
            return
        }
        guard let storage else {
            failure = .storageUnavailable
            await diagnostics.record(
                .failed(
                    .repairDownload,
                    category: .download,
                    failureCode: .persistenceUnavailable
                )
            )
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
            let scheduledTracks =
                record.manifest.purpose == .automaticCache
                ? Array(tracks.prefix(1))
                : tracks
            if !scheduledTracks.isEmpty {
                try await schedule(
                    plan: plan,
                    detail: record.detail,
                    account: account,
                    storage: storage,
                    purpose: record.manifest.purpose,
                    tracks: scheduledTracks,
                    downloadID: record.manifest.downloadID
                )
            }
            await refresh()
            await diagnostics.record(
                .completed(
                    .repairDownload,
                    category: .download,
                    count: tracks.count
                )
            )
        } catch let error as DownloadModelFailure {
            failure = error
            await diagnostics.record(
                .failed(
                    .repairDownload,
                    category: .download,
                    failureCode: .mediaUnavailable
                )
            )
        } catch let error as DownloadStorageError {
            failure = storageFailure(error)
            await diagnostics.record(
                .failed(
                    .repairDownload,
                    category: .download,
                    failureCode: .persistenceUnavailable
                )
            )
        } catch {
            failure = .preparationFailed
            await diagnostics.record(
                .failed(
                    .repairDownload,
                    category: .download,
                    failureCode: .mediaUnavailable
                )
            )
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
            } else if !automaticDownloadIsBlocked(record) {
                task.resume()
            } else {
                playbackSuspendedDownloadIDs.insert(
                    record.manifest.downloadID
                )
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
            transferredBytesByTrack[downloadID] = nil
            pausedDownloadIDs.remove(downloadID)
            playbackSuspendedDownloadIDs.remove(downloadID)
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

    private func record(
        downloadID: DownloadID
    ) -> DownloadedBookRecord? {
        records.first {
            $0.manifest.downloadID == downloadID
        }
    }

    private func automaticDownloadIsBlocked(
        _ record: DownloadedBookRecord
    ) -> Bool {
        record.manifest.purpose == .automaticCache
            && playbackBlockedAutomaticDownloads.contains(
                AutomaticDownloadKey(
                    accountID: record.manifest.accountID,
                    itemID: record.manifest.itemID
                )
            )
    }

    private func setAutomaticDownloadsBlocked(
        _ blocked: Bool,
        for key: AutomaticDownloadKey
    ) async {
        if blocked {
            playbackBlockedAutomaticDownloads.insert(key)
        } else {
            playbackBlockedAutomaticDownloads.remove(key)
        }
        let automaticDownloadIDs = Set(
            records.lazy.filter {
                $0.manifest.accountID == key.accountID
                    && $0.manifest.itemID == key.itemID
                    && $0.manifest.purpose == .automaticCache
            }.map(\.manifest.downloadID)
        )
        guard !automaticDownloadIDs.isEmpty else {
            return
        }
        let tasks = await session.allTasks
        for task in tasks {
            guard let description = task.taskDescription,
                let identity =
                    try? DownloadTaskIdentity
                    .decodeTaskDescription(description),
                automaticDownloadIDs.contains(identity.downloadID)
            else {
                continue
            }
            if blocked {
                if task.state == .running {
                    task.suspend()
                    playbackSuspendedDownloadIDs.insert(
                        identity.downloadID
                    )
                }
            } else if playbackSuspendedDownloadIDs.contains(
                identity.downloadID
            ) && !pausedDownloadIDs.contains(identity.downloadID) {
                task.resume()
            }
        }
        if !blocked {
            playbackSuspendedDownloadIDs.subtract(
                automaticDownloadIDs
            )
        }
    }

    func downloadedByteLength(
        for record: DownloadedBookRecord
    ) -> Int64 {
        Self.scopedDownloadedByteLength(
            for: record,
            transferredByteLengthsByTrack:
                transferredBytesByTrack[record.manifest.downloadID] ?? [:]
        )
    }

    func isFullyDownloaded(for record: DownloadedBookRecord) -> Bool {
        downloadedByteLength(for: record)
            >= expectedByteLength(for: record)
    }

    static func scopedDownloadedByteLength(
        for record: DownloadedBookRecord,
        transferredByteLengthsByTrack: [Int: Int64]
    ) -> Int64 {
        if record.manifest.purpose == .automaticCache,
            let targets = record.manifest.automaticTargetTrackIndexes
        {
            return Self.combinedDownloadedByteLength(
                storedByteLength:
                    record.manifest.automaticStoredByteLength ?? 0,
                transferredByteLengths:
                    transferredByteLengthsByTrack.compactMap {
                        targets.contains($0.key) ? $0.value : nil
                    },
                expectedByteLength:
                    record.manifest.automaticExpectedByteLength ?? 0
            )
        }
        return Self.combinedDownloadedByteLength(
            storedByteLength: record.manifest.storedByteLength,
            transferredByteLengths:
                transferredByteLengthsByTrack.values.map { $0 },
            expectedByteLength: record.manifest.expectedByteLength
        )
    }

    func expectedByteLength(
        for record: DownloadedBookRecord
    ) -> Int64 {
        if record.manifest.purpose == .automaticCache {
            return record.manifest.automaticExpectedByteLength ?? 0
        }
        return record.manifest.expectedByteLength
    }

    func automaticCacheState(
        for record: DownloadedBookRecord
    ) -> AutomaticCacheState? {
        guard record.manifest.purpose == .automaticCache else {
            return nil
        }
        return record.manifest.automaticCacheState
    }

    func isFullBookAvailable(
        _ record: DownloadedBookRecord
    ) -> Bool {
        record.manifest.isFullBookComplete
    }

    static func combinedDownloadedByteLength(
        storedByteLength: Int64,
        transferredByteLengths: [Int64],
        expectedByteLength: Int64
    ) -> Int64 {
        let transferred = transferredByteLengths.reduce(
            0,
            Self.saturatingAdd
        )
        return min(
            Self.saturatingAdd(
                max(storedByteLength, 0),
                transferred
            ),
            max(expectedByteLength, 0)
        )
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
            let currentIDs = Set(records.map(\.manifest.downloadID))
            for downloadID in Array(progress.keys)
            where !currentIDs.contains(downloadID) {
                progress[downloadID] = nil
            }
            for record in records {
                updateProgress(for: record.manifest.downloadID)
            }
        } catch {
            failure = .storageUnavailable
        }
    }

    private func acceptPlacement(
        identity: DownloadTaskIdentity,
        observedByteLength: Int64
    ) async {
        supersededAutomaticTasks.remove(
            AutomaticDownloadTaskKey(identity)
        )
        guard let storage else {
            failure = .storageUnavailable
            return
        }
        do {
            _ = try await storage.markComplete(
                identity,
                observedByteLength: observedByteLength
            )
            await diagnostics.record(
                .completed(.completeDownload, category: .download)
            )
            await refresh()
            clearTransferredBytes(for: identity)
            let key = AutomaticDownloadKey(
                accountID: identity.accountID,
                itemID: identity.itemID
            )
            if record(downloadID: identity.downloadID)?
                .manifest.purpose == .automaticCache,
                let activity = latestAutomaticProgress[key],
                !playbackBlockedAutomaticDownloads.contains(key)
            {
                await handleAutomaticPlaybackActivity(activity)
            }
        } catch {
            _ = try? await storage.markFailed(identity)
            clearTransferredBytes(for: identity)
            failure = .transferFailed
            await diagnostics.record(
                .failed(
                    .completeDownload,
                    category: .download,
                    failureCode: .mediaUnavailable
                )
            )
            await refresh()
        }
    }

    private func rejectPlacement(
        identity: DownloadTaskIdentity
    ) async {
        if supersededAutomaticTasks.remove(
            AutomaticDownloadTaskKey(identity)
        ) != nil {
            clearTransferredBytes(for: identity)
            return
        }
        if let storage {
            _ = try? await storage.markFailed(identity)
        }
        clearTransferredBytes(for: identity)
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
                .decodeTaskDescription(description)
        else {
            return
        }
        if supersededAutomaticTasks.remove(
            AutomaticDownloadTaskKey(identity)
        ) != nil {
            clearTransferredBytes(for: identity)
            return
        }
        guard !deletingDownloadIDs.contains(identity.downloadID) else {
            return
        }
        guard let response = task.response as? HTTPURLResponse else {
            if error != nil, let storage {
                _ = try? await storage.markFailed(identity)
                clearTransferredBytes(for: identity)
                await refresh()
            }
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
                var replacement =
                    try await service.replacementDownloadRequest(
                        for: account,
                        identity: identity,
                        rejectedRequest: request
                    )
                if record(downloadID: identity.downloadID)?
                    .manifest.purpose == .automaticCache
                {
                    replacement.networkServiceType = .background
                }
                let replacementTask = session.downloadTask(
                    with: networkPolicy.applying(to: replacement)
                )
                replacementTask.taskDescription = description
                replacementTask.priority =
                    record(downloadID: identity.downloadID)?
                        .manifest.purpose == .automaticCache
                    ? URLSessionTask.lowPriority
                    : URLSessionTask.defaultPriority
                clearTransferredBytes(for: identity)
                if let record = record(
                    downloadID: identity.downloadID
                ), automaticDownloadIsBlocked(record) {
                    playbackSuspendedDownloadIDs.insert(
                        identity.downloadID
                    )
                } else {
                    replacementTask.resume()
                }
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
        clearTransferredBytes(for: identity)
        await refresh()
    }

    private func updateTransferredBytes(
        _ totalBytesWritten: Int64,
        for identity: DownloadTaskIdentity
    ) {
        transferredBytesByTrack[identity.downloadID, default: [:]][
            identity.trackIndex
        ] = max(totalBytesWritten, 0)
        updateProgress(for: identity.downloadID)
    }

    private func clearTransferredBytes(
        for identity: DownloadTaskIdentity
    ) {
        transferredBytesByTrack[identity.downloadID]?[
            identity.trackIndex
        ] = nil
        if transferredBytesByTrack[identity.downloadID]?.isEmpty == true {
            transferredBytesByTrack[identity.downloadID] = nil
        }
        updateProgress(for: identity.downloadID)
    }

    private func updateProgress(for downloadID: DownloadID) {
        guard let record = record(downloadID: downloadID) else {
            progress[downloadID] = nil
            return
        }
        let expected = expectedByteLength(for: record)
        guard expected > 0 else {
            progress[downloadID] =
                isFullBookAvailable(record)
                    || automaticCacheState(for: record) == .cached
                ? 1 : 0
            return
        }
        progress[downloadID] = min(
            max(
                Double(downloadedByteLength(for: record))
                    / Double(expected),
                0
            ),
            1
        )
    }

    private static func saturatingAdd(
        _ lhs: Int64,
        _ rhs: Int64
    ) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
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
        guard let description = downloadTask.taskDescription,
            let identity =
                try? DownloadTaskIdentity
                .decodeTaskDescription(description)
        else {
            return
        }
        Task { @MainActor [weak self] in
            guard
                self?.deletingDownloadIDs.contains(
                    identity.downloadID
                ) == false
            else {
                return
            }
            self?.updateTransferredBytes(
                totalBytesWritten,
                for: identity
            )
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
