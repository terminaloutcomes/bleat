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
    case transportUnavailable
    case requestRejected(statusCode: Int)

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
        case .transportUnavailable:
            "The connection was lost repeatedly while downloading."
        case .requestRejected(let statusCode):
            "The server rejected a download request (HTTP \(statusCode))."
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
        #if os(macOS)
            return .schedule
        #else
            guard policy == .allowCellular,
                expectedBytes >= largeDownloadThresholdBytes
            else {
                return .schedule
            }
            return .confirmCellular(expectedBytes: expectedBytes)
        #endif
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

    init(downloadID: DownloadID, trackIndex: Int) {
        self.downloadID = downloadID
        self.trackIndex = trackIndex
    }
}

private struct TransferInactivityWatchdog {
    let taskIdentifier: Int
    let timer: Task<Void, Never>
}

struct AutomaticCachePin: Hashable, Sendable {
    fileprivate let id: UUID
    fileprivate let downloadID: DownloadID
}

struct AutomaticCachedPlaybackWindow: Sendable {
    let downloadID: DownloadID
    let tracks: [AppPlaybackTrack]
    let trackIndexes: Set<Int>
    let pin: AutomaticCachePin

    var startTime: Double {
        tracks.first?.startOffset ?? 0
    }

    var endTime: Double {
        guard let last = tracks.last else { return startTime }
        return last.startOffset + last.duration
    }
}

private struct TimedAutomaticCacheEntry {
    let entry: DownloadManifestEntry
    let startOffset: Double
    let duration: Double
}

private enum DeferredAutomaticCacheCleanup {
    case tracks(Set<Int>)
    case record
}

private enum DownloadTransferOutcome {
    case chunkStored(
        committedByteLength: Int64,
        validator: DownloadValidator?,
        finalized: Bool
    )
    case placementRejected
    case transportFailed(rejectedRequest: URLRequest?)
    case unauthorized(rejectedRequest: URLRequest)
    case requestRejected(
        statusCode: Int,
        rejectedRequest: URLRequest?
    )
}

enum DownloadTransferResult: Equatable, Sendable {
    case chunkStored(finalized: Bool)
    case retryableFailure
    case terminalFailure
}

enum DownloadTransferHTTPDisposition: Equatable, Sendable {
    case success
    case unauthorized
    case retryableFailure
    case terminalFailure
}

enum DownloadTransferNextAction: Equatable, Sendable {
    case stop
    case continueChunk
    case advanceAutomaticDownload
    case retry
    case fail
}

private enum DownloadRetryDisposition: Equatable {
    case immediate
    case afterNetworkChange
}

struct DownloadTransferContext: Equatable, Sendable {
    let isPaused: Bool
    let isCancelled: Bool
    let isDeleting: Bool
    let isSuperseded: Bool
    let isAutomatic: Bool
}

enum DownloadTransferReconciler {
    static func nextAction(
        after result: DownloadTransferResult,
        context: DownloadTransferContext
    ) -> DownloadTransferNextAction {
        guard !context.isPaused,
            !context.isCancelled,
            !context.isDeleting,
            !context.isSuperseded
        else {
            return .stop
        }
        switch result {
        case .chunkStored(let finalized):
            if finalized {
                return context.isAutomatic
                    ? .advanceAutomaticDownload : .stop
            }
            return .continueChunk
        case .retryableFailure:
            return .retry
        case .terminalFailure:
            return .fail
        }
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
    static let rangeChunkByteLength: Int64 = 16 * 1_024 * 1_024
    static let maximumTransferRetries = 2
    static let transferInactivityTimeoutSeconds: TimeInterval = 10

    static var supportsNetworkPolicySelection: Bool {
        #if os(macOS)
            false
        #else
            true
        #endif
    }

    private let service: any AppServicing
    private let diagnostics: any DiagnosticRecording
    private let remoteTelemetryTracer: any RemoteTelemetryTracing
    private let transferRetrySleep:
        @Sendable (Duration) async throws -> Void
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
    private var cancelledDownloadIDs: Set<DownloadID> = []
    private var pendingRecoveryDownloadIDs: Set<DownloadID> = []
    private var pendingRecoveryTaskKeys: Set<AutomaticDownloadTaskKey> = []
    private var transferRetryCounts: [AutomaticDownloadTaskKey: Int] = [:]
    private var terminalTransferTaskKeys: Set<AutomaticDownloadTaskKey> = []
    private var transferInactivityWatchdogs:
        [AutomaticDownloadTaskKey: TransferInactivityWatchdog] = [:]
    private var isRecoveringInterruptedTransfers = false
    private var automaticUpdatesInProgress: Set<AutomaticDownloadKey> = []
    private var pendingAutomaticUpdates:
        [AutomaticDownloadKey: AutomaticDownloadActivity] = [:]
    private var latestAutomaticProgress:
        [AutomaticDownloadKey: AutomaticDownloadActivity] = [:]
    private var playbackBlockedAutomaticDownloads: Set<AutomaticDownloadKey> =
        []
    private var playbackSuspendedDownloadIDs: Set<DownloadID> = []
    private var supersededAutomaticTasks: Set<String> = []
    private var transferSpans: [AutomaticDownloadTaskKey: RemoteTelemetrySpan] =
        [:]
    private var automaticCachePins: [DownloadID: [UUID: Set<Int>]] = [:]
    private var deferredAutomaticCacheCleanup:
        [DownloadID: DeferredAutomaticCacheCleanup] = [:]
    private var transferredBytesByTrack: [DownloadID: [Int: Int64]] = [:]
    private var displayedDownloadedBytes: [DownloadID: Int64] = [:]
    private var networkPathState: AppNetworkPathState = .unknown
    private var isForegroundActive = false
    private var automaticCleanupTask: Task<Void, Never>?
    @ObservationIgnored
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: bleatBackgroundDownloadSessionIdentifier
        )
        configuration.httpMaximumConnectionsPerHost =
            bleatBackgroundDownloadMaximumConnectionsPerHost
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
            SystemDiagnosticRecorder.shared,
        remoteTelemetryTracer: any RemoteTelemetryTracing =
            InactiveRemoteTelemetryTracer(),
        transferRetrySleep:
            @escaping @Sendable (Duration) async throws -> Void = {
                try await Task.sleep(for: $0)
            }
    ) {
        self.service = service
        self.diagnostics = diagnostics
        self.remoteTelemetryTracer = remoteTelemetryTracer
        self.transferRetrySleep = transferRetrySleep
        self.defaults = defaults
        networkPolicy = Self.loadNetworkPolicy(from: defaults)
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
                let layout = try DownloadStorageLayout.applicationSupport()
                rootURL = layout.rootURL
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
        pausedDownloadIDs = Set(
            records.compactMap {
                $0.manifest.state == .paused
                    ? $0.manifest.downloadID : nil
            }
        )
        await discardInvalidLegacyDownloads()
        let tasks = await session.allTasks
        var currentTasks: [(URLSessionTask, DownloadChunkTaskDescription)] = []
        for task in tasks {
            guard let description = task.taskDescription,
                let descriptor = try? DownloadChunkTaskDescription.decode(
                    description
                ),
                await taskDescriptorIsCurrent(descriptor, storage: storage)
            else {
                task.cancel()
                continue
            }
            let identity = descriptor.identity
            let purpose =
                record(downloadID: identity.downloadID)?.manifest
                .purpose ?? .manual
            currentTasks.append((task, descriptor))
            beginTransferSpan(identity, purpose: purpose)
        }
        let activeTaskKeys = Set(
            currentTasks.map { _, descriptor in
                return AutomaticDownloadTaskKey(descriptor.identity)
            }
        )
        if let storage {
            await reconcileTransfers(
                scope: .allRecords,
                activeTaskKeys: activeTaskKeys,
                storage: storage
            )
        }
        for (task, descriptor) in currentTasks {
            if task.state == .suspended {
                task.resume()
            }
            armTransferInactivityWatchdog(
                for: task,
                identity: descriptor.identity
            )
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

    /// Resumes interrupted, non-paused transfers after connectivity returns.
    ///
    /// Only downloads whose startup plan lookup failed transiently are
    /// retried, so repeated network-path events cannot reschedule transfers
    /// that already have surviving tasks or that the user paused.
    func recoverAfterNetworkChange(
        for accountUpdates: [ServerAccount]
    ) async {
        for account in accountUpdates {
            self.accounts[account.id] = account
        }
        guard !isRecoveringInterruptedTransfers else {
            return
        }
        guard let storage else {
            pendingRecoveryDownloadIDs = []
            pendingRecoveryTaskKeys = []
            return
        }
        for downloadID in Array(pendingRecoveryDownloadIDs) {
            let stillRecoverable: Bool
            if let record = record(downloadID: downloadID),
                record.manifest.state == .downloading
                    || record.manifest.state == .queued
                    || (record.manifest.state == .failed
                        && pendingRecoveryTaskKeys.contains(where: {
                            $0.downloadID == downloadID
                        })),
                !pausedDownloadIDs.contains(downloadID),
                accounts[record.manifest.accountID] != nil {
                stillRecoverable = true
            } else {
                stillRecoverable = false
            }
            if !stillRecoverable {
                pendingRecoveryDownloadIDs.remove(downloadID)
                pendingRecoveryTaskKeys = pendingRecoveryTaskKeys.filter {
                    $0.downloadID != downloadID
                }
            }
        }
        guard !pendingRecoveryDownloadIDs.isEmpty else {
            return
        }
        isRecoveringInterruptedTransfers = true
        defer { isRecoveringInterruptedTransfers = false }
        await diagnostics.record(
            .started(.resumeInterruptedDownloads, category: .download)
        )
        let resumedCount = await reconcileTransfers(
            scope: .interruptedOnly(
                accountIDs: Set(accountUpdates.map(\.id))
            ),
            activeTaskKeys: await activeTransferTaskKeys(),
            storage: storage
        )
        await diagnostics.record(
            .completed(
                .resumeInterruptedDownloads,
                category: .download,
                count: resumedCount
            )
        )
    }

    private enum TransferReconciliationScope {
        case allRecords
        case interruptedOnly(accountIDs: Set<AccountID>)
    }

    /// Schedules missing transfer tasks for persisted non-paused incomplete
    /// downloads. Plan lookups that fail transiently (for example while the
    /// device is offline at launch) defer the download into
    /// `pendingRecoveryDownloadIDs` instead of leaving it permanently stalled;
    /// `recoverAfterNetworkChange(for:)` retries exactly those records later.
    @discardableResult
    private func reconcileTransfers(
        scope: TransferReconciliationScope,
        activeTaskKeys: Set<AutomaticDownloadTaskKey>,
        storage: DownloadStorage
    ) async -> Int {
        var scheduledDownloadCount = 0
        for record in records
        where record.manifest.state == .downloading
            || record.manifest.state == .queued
            || (record.manifest.state == .failed
                && pendingRecoveryTaskKeys.contains(where: {
                    $0.downloadID == record.manifest.downloadID
                }))
        {
            let downloadID = record.manifest.downloadID
            if case .interruptedOnly(let accountIDs) = scope {
                guard pendingRecoveryDownloadIDs.contains(downloadID),
                    accountIDs.contains(record.manifest.accountID)
                else {
                    continue
                }
            }
            guard !pausedDownloadIDs.contains(downloadID),
                let account = accounts[record.manifest.accountID]
            else {
                continue
            }
            do {
                let plan = try await service.downloadPlan(
                    for: account,
                    itemID: record.manifest.itemID
                )
                let missingTracks = plan.tracks.filter { track in
                    guard
                        let entry = record.manifest.entries.first(where: {
                            $0.trackIndex == track.index
                        }), entry.state != .complete,
                        let identity = try? DownloadTaskIdentity(
                            downloadID: downloadID,
                            accountID: record.manifest.accountID,
                            itemID: record.manifest.itemID,
                            track: track
                        )
                    else {
                        return false
                    }
                    let key = AutomaticDownloadTaskKey(identity)
                    if terminalTransferTaskKeys.contains(key) {
                        return false
                    }
                    return !activeTaskKeys.contains(key)
                }
                if !missingTracks.isEmpty {
                    try await schedule(
                        plan: plan,
                        detail: record.detail,
                        account: account,
                        storage: storage,
                        purpose: record.manifest.purpose,
                        tracks: missingTracks,
                        downloadID: downloadID
                    )
                    scheduledDownloadCount += 1
                }
                for track in missingTracks {
                    let key = AutomaticDownloadTaskKey(
                        downloadID: downloadID,
                        trackIndex: track.index
                    )
                    pendingRecoveryTaskKeys.remove(key)
                    transferRetryCounts[key] = nil
                }
                if !pendingRecoveryTaskKeys.contains(where: {
                    $0.downloadID == downloadID
                }) {
                    pendingRecoveryDownloadIDs.remove(downloadID)
                }
            } catch {
                if Self.isTransientRecoveryFailure(error) {
                    pendingRecoveryDownloadIDs.insert(downloadID)
                } else {
                    pendingRecoveryDownloadIDs.remove(downloadID)
                    pendingRecoveryTaskKeys =
                        pendingRecoveryTaskKeys.filter {
                            $0.downloadID != downloadID
                        }
                }
                await diagnostics.record(
                    .failed(
                        .resumeInterruptedDownloads,
                        category: .download,
                        failureCode: Self.reconciliationFailureCode(
                            for: error
                        )
                    )
                )
            }
        }
        await refresh()
        return scheduledDownloadCount
    }

    private func activeTransferTaskKeys() async
        -> Set<AutomaticDownloadTaskKey> {
        var keys: Set<AutomaticDownloadTaskKey> = []
        for task in await session.allTasks {
            guard let description = task.taskDescription,
                let descriptor = try? DownloadChunkTaskDescription.decode(
                    description
                ),
                await taskDescriptorIsCurrent(descriptor, storage: storage)
            else {
                task.cancel()
                continue
            }
            keys.insert(AutomaticDownloadTaskKey(descriptor.identity))
        }
        return keys
    }

    func scheduledTransferDescriptorsForTesting() async
        -> [DownloadChunkTaskDescription] {
        var descriptors: [(key: String, descriptor: DownloadChunkTaskDescription)] =
            []
        for task in await session.allTasks
        where task.state == .running || task.state == .suspended {
            guard let description = task.taskDescription,
                let descriptor = try? DownloadChunkTaskDescription.decode(
                    description
                )
            else {
                continue
            }
            let identity = descriptor.identity
            descriptors.append(
                (
                    "\(identity.accountID.rawValue)|\(identity.itemID.rawValue)|\(identity.trackIndex)",
                    descriptor
                )
            )
        }
        return descriptors.sorted { $0.key < $1.key }.map(\.descriptor)
    }

    func scheduledTransferRequestsForTesting() async -> [URLRequest] {
        await session.allTasks.compactMap { task in
            guard task.state == .running || task.state == .suspended else {
                return nil
            }
            return task.currentRequest ?? task.originalRequest
        }
    }

    var pendingRecoveryDownloadIDsForTesting: Set<DownloadID> {
        pendingRecoveryDownloadIDs
    }

    var transferInactivityWatchdogCountForTesting: Int {
        transferInactivityWatchdogs.count
    }

    func transferRetryCountForTesting(
        _ identity: DownloadTaskIdentity
    ) -> Int {
        transferRetryCounts[AutomaticDownloadTaskKey(identity), default: 0]
    }

    func isWaitingForNetwork(_ record: DownloadedBookRecord) -> Bool {
        if networkPathState.availability == .unavailable {
            return record.manifest.state == .downloading
                || record.manifest.state == .queued
                || pendingRecoveryDownloadIDs.contains(
                    record.manifest.downloadID
                )
        }
        return pendingRecoveryDownloadIDs.contains(
            record.manifest.downloadID
        ) && networkPathState.availability != .satisfied
    }

    func isRetrying(_ record: DownloadedBookRecord) -> Bool {
        pendingRecoveryDownloadIDs.contains(record.manifest.downloadID)
            && networkPathState.availability == .satisfied
    }

    func updateNetworkPathState(_ state: AppNetworkPathState) {
        networkPathState = state
        if state.availability != .satisfied {
            cancelAllTransferInactivityWatchdogs()
        } else if isForegroundActive,
            state.availability == .satisfied
        {
            Task { @MainActor [weak self] in
                await self?.armWatchdogsForActiveTransfers()
            }
        }
    }

    func setForegroundActive(_ active: Bool) {
        isForegroundActive = active
        if active && networkPathState.availability == .satisfied {
            Task { @MainActor [weak self] in
                guard self?.isForegroundActive == true else { return }
                await self?.armWatchdogsForActiveTransfers()
            }
        } else {
            cancelAllTransferInactivityWatchdogs()
        }
    }

    private static func reconciliationFailureCode(
        for error: Error
    ) -> DiagnosticFailureCode {
        guard case .downloadPlan(let planError) = error as? AppServiceError
        else {
            return .mediaUnavailable
        }
        switch planError {
        case .invalidItemID:
            return .invalidInput
        case .routeConstruction:
            return .requestRejected
        case .authenticatedRequest(let requestError):
            switch requestError {
            case .invalidAccountID, .accountOperationInProgress,
                .authenticationEndpoint, .requestDoesNotMatchRoute,
                .authorizationFailed:
                return .requestRejected
            case .credentialsReadFailed, .missingCredentials,
                .missingAccessToken, .missingRefreshToken,
                .credentialPersistenceFailed, .savedLoginCredentialsReadFailed,
                .refreshRejected, .unexpectedRefreshStatus,
                .malformedRefreshResponse, .automaticReauthenticationFailed,
                .retriedRequestUnauthorized:
                return .authenticationRequired
            case .requestCancelled, .refreshCancelled:
                return .requestCancelled
            case .automaticReauthenticationTransportFailed,
                .refreshRequestConstructionFailed, .refreshTransportFailed,
                .requestTransportFailed:
                return .serverUnavailable
            }
        case .unexpectedStatus(let status):
            switch status {
            case 401, 403:
                return .permissionDenied
            case 404:
                return .itemNotFound
            case 500...599:
                return .serverUnavailable
            default:
                return .invalidServerResponse
            }
        case .invalidPlan:
            return .invalidServerResponse
        }
    }

    private static func isTransientRecoveryFailure(_ error: Error) -> Bool {
        guard case .downloadPlan(let planError) = error as? AppServiceError
        else {
            return false
        }
        switch planError {
        case .authenticatedRequest(
            .automaticReauthenticationTransportFailed
        ), .authenticatedRequest(.refreshRequestConstructionFailed),
            .authenticatedRequest(.refreshTransportFailed),
            .authenticatedRequest(.requestTransportFailed),
            .unexpectedStatus(500...599):
            return true
        case .invalidItemID, .routeConstruction,
            .authenticatedRequest(.invalidAccountID),
            .authenticatedRequest(.accountOperationInProgress),
            .authenticatedRequest(.authenticationEndpoint),
            .authenticatedRequest(.requestDoesNotMatchRoute),
            .authenticatedRequest(.authorizationFailed),
            .authenticatedRequest(.credentialsReadFailed),
            .authenticatedRequest(.missingCredentials),
            .authenticatedRequest(.missingAccessToken),
            .authenticatedRequest(.missingRefreshToken),
            .authenticatedRequest(.credentialPersistenceFailed),
            .authenticatedRequest(.savedLoginCredentialsReadFailed),
            .authenticatedRequest(.refreshRejected),
            .authenticatedRequest(.unexpectedRefreshStatus),
            .authenticatedRequest(.malformedRefreshResponse),
            .authenticatedRequest(.automaticReauthenticationFailed),
            .authenticatedRequest(.retriedRequestUnauthorized),
            .authenticatedRequest(.requestCancelled),
            .authenticatedRequest(.refreshCancelled),
            .unexpectedStatus, .invalidPlan:
            return false
        }
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
        guard Self.supportsNetworkPolicySelection else {
            return
        }
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
        networkPolicy = Self.loadNetworkPolicy(from: defaults)
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

    private static func loadNetworkPolicy(
        from defaults: UserDefaults
    ) -> DownloadNetworkPolicy {
        #if os(macOS)
            .allowCellular
        #else
            defaults.string(forKey: "bleat.downloads.networkPolicy.v1")
                .flatMap(DownloadNetworkPolicy.init(rawValue:))
                ?? .wifiOnly
        #endif
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
                _ = try await storage.preflightRemaining(
                    record: record,
                    tracks: tracks
                )
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
            _ = try await storage.preflightRemaining(
                record: record,
                tracks: tracks
            )
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
                let pinned = pinnedAutomaticCacheTrackIndexes(
                    for: existing.manifest.downloadID
                )
                let deferredIndexes = completedIndexes.intersection(pinned)
                if !deferredIndexes.isEmpty {
                    deferAutomaticCacheCleanup(
                        .tracks(deferredIndexes),
                        for: existing.manifest.downloadID
                    )
                }
                let removableIndexes = completedIndexes.subtracting(pinned)
                if !removableIndexes.isEmpty {
                    record = try await storage.removeCompletedTracks(
                        from: existing,
                        trackIndexes: removableIndexes
                    )
                }
            }

            let existingStates = Dictionary(
                uniqueKeysWithValues:
                    record?.manifest.entries.map {
                        ($0.trackIndex, $0.state)
                    } ?? []
            )
            // Known accepted behavior for #77: fresh playback activity may
            // restart a user-paused automatic cache. Revisit if automatic
            // pauses need to become sticky scheduler vetoes.
            let tracks = plan.tracks.filter {
                targets.contains($0.index)
                    && existingStates[$0.index] != .complete
                    && existingStates[$0.index] != .downloading
            }
            guard !tracks.isEmpty else {
                await refresh()
                return
            }
            if let record {
                _ = try await storage.preflightRemaining(
                    record: record,
                    tracks: tracks
                )
            } else {
                _ = try await storage.preflight(tracks: tracks)
            }
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
            await removeAutomatically(record)
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
                await removeAutomatically(record)
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
            await removeAutomatically(record)
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

    private func discardInvalidLegacyDownloads() async {
        guard let storage else {
            return
        }
        let legacyRecords = records.filter {
            $0.manifest.isLegacyAutomaticCache
                && $0.manifest.state != .complete
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
            finishTransferSpan(identity, outcome: .cancelled)
            cancelTransferInactivityWatchdog(for: identity)
        }
        for record in legacyRecords {
            try? await storage.remove(record)
            progress[record.manifest.downloadID] = nil
            transferredBytesByTrack[record.manifest.downloadID] = nil
            displayedDownloadedBytes[record.manifest.downloadID] = nil
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
            supersededAutomaticTasks.insert(description)
            task.cancel()
            finishTransferSpan(identity, outcome: .cancelled)
            if states[identity.trackIndex] == .downloading {
                _ = try? await storage.removeTrackFiles(identity)
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
            try await scheduleChunk(
                identity: identity,
                account: account,
                purpose: purpose,
                storage: storage
            )
        }
    }

    private func scheduleChunk(
        identity: DownloadTaskIdentity,
        account: ServerAccount,
        purpose: DownloadPurpose,
        storage: DownloadStorage
    ) async throws {
        cancelledDownloadIDs.remove(identity.downloadID)
        let committed = try await storage.partialByteLength(identity)
        guard
            let range = try DownloadByteRange.next(
                committedByteLength: committed,
                expectedByteLength: identity.expectedByteLength,
                chunkByteLength: Self.rangeChunkByteLength
            )
        else {
            return
        }
        let validator = record(downloadID: identity.downloadID)?
            .manifest.entries.first(where: {
                $0.trackIndex == identity.trackIndex
            })?.validator
        var request = try await service.authorizedDownloadRequest(
            for: account,
            identity: identity
        )
        request = DownloadRangeRequest.applying(
            range: range,
            validator: validator,
            to: request
        )
        if purpose == .automaticCache {
            request.networkServiceType = .background
        }
        let taskDescription = try DownloadChunkTaskDescription(
            identity: identity,
            range: range,
            validator: validator
        ).encode()
        let task = session.downloadTask(
            with: networkPolicy.applying(to: request)
        )
        task.taskDescription = taskDescription
        task.priority =
            purpose == .automaticCache
            ? URLSessionTask.lowPriority : URLSessionTask.defaultPriority
        beginTransferSpan(identity, purpose: purpose)
        _ = try await storage.markDownloading(
            identity,
            observedByteLength: committed,
            validator: validator
        )
        let currentContext = transferContext(
            for: identity,
            taskDescription: taskDescription
        )
        guard !currentContext.isPaused,
            !currentContext.isCancelled,
            !currentContext.isDeleting,
            !currentContext.isSuperseded
        else {
            task.cancel()
            if currentContext.isPaused {
                _ = try? await storage.markPaused(
                    identity,
                    observedByteLength: committed
                )
            } else if currentContext.isCancelled {
                try? await storage.removeTrackFiles(identity)
                _ = try? await storage.markFailed(identity)
            } else if currentContext.isSuperseded {
                try? await storage.removeTrackFiles(identity)
                _ = try? await storage.markQueued(identity)
            }
            return
        }
        let key = AutomaticDownloadKey(
            accountID: identity.accountID,
            itemID: identity.itemID
        )
        if purpose == .automaticCache,
            playbackBlockedAutomaticDownloads.contains(key)
        {
            playbackSuspendedDownloadIDs.insert(identity.downloadID)
        } else {
            task.resume()
            armTransferInactivityWatchdog(for: task, identity: identity)
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
            finishTransferSpan(identity, outcome: .cancelled)
            cancelTransferInactivityWatchdog(for: identity)
        }
        do {
            try await storage.remove(record)
            automaticCachePins[record.manifest.downloadID] = nil
            deferredAutomaticCacheCleanup[record.manifest.downloadID] = nil
            progress[record.manifest.downloadID] = nil
            transferredBytesByTrack[record.manifest.downloadID] = nil
            displayedDownloadedBytes[record.manifest.downloadID] = nil
            pausedDownloadIDs.remove(record.manifest.downloadID)
            pendingRecoveryDownloadIDs.remove(record.manifest.downloadID)
            pendingRecoveryTaskKeys = pendingRecoveryTaskKeys.filter {
                $0.downloadID != record.manifest.downloadID
            }
            resetTransferRetryBudget(for: record.manifest.downloadID)
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

    /// Removes every downloaded book and reports whether the filesystem and
    /// persisted manifests were both cleared. Reset must not continue when a
    /// download remains, because it would otherwise claim to have erased all
    /// local data.
    func removeAllForLocalDataReset() async -> Bool {
        let removableRecords = records
        for record in removableRecords {
            guard await remove(record) else {
                return false
            }
        }
        return true
    }

    func cancel(_ record: DownloadedBookRecord) async {
        await diagnostics.record(
            .started(.cancelDownload, category: .download)
        )
        cancelledDownloadIDs.insert(record.manifest.downloadID)
        resetTransferRetryBudget(for: record.manifest.downloadID)
        pendingRecoveryDownloadIDs.remove(record.manifest.downloadID)
        pendingRecoveryTaskKeys = pendingRecoveryTaskKeys.filter {
            $0.downloadID != record.manifest.downloadID
        }
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
            finishTransferSpan(identity, outcome: .cancelled)
            cancelTransferInactivityWatchdog(for: identity)
        }
        if let storage {
            for entry in record.manifest.entries where entry.state != .complete
            {
                guard let identity = Self.identity(for: entry, record: record)
                else { continue }
                try? await storage.discardPartial(identity)
                _ = try? await storage.markQueued(identity)
                _ = try? await storage.markFailed(identity)
            }
        }
        failure = nil
        transferredBytesByTrack[record.manifest.downloadID] = nil
        displayedDownloadedBytes[record.manifest.downloadID] = nil
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
        guard let storage else {
            failure = .storageUnavailable
            return
        }
        pausedDownloadIDs.insert(record.manifest.downloadID)
        resetTransferRetryBudget(for: record.manifest.downloadID)
        pendingRecoveryDownloadIDs.remove(record.manifest.downloadID)
        pendingRecoveryTaskKeys = pendingRecoveryTaskKeys.filter {
            $0.downloadID != record.manifest.downloadID
        }
        let tasks = await session.allTasks
        for entry in record.manifest.entries where entry.state != .complete {
            guard let identity = Self.identity(for: entry, record: record)
            else { continue }
            let committed =
                (try? await storage.partialByteLength(identity)) ?? 0
            _ = try? await storage.markPaused(
                identity,
                observedByteLength: committed
            )
        }
        for task in tasks {
            guard let description = task.taskDescription,
                let identity =
                    try? DownloadTaskIdentity
                    .decodeTaskDescription(description),
                identity.downloadID == record.manifest.downloadID
            else { continue }
            task.cancel()
            finishTransferSpan(identity, outcome: .cancelled)
            cancelTransferInactivityWatchdog(for: identity)
            clearTransferredBytes(for: identity)
        }
        await refresh()
        await diagnostics.record(
            .completed(.pauseDownload, category: .download)
        )
    }

    func continueDownload(_ record: DownloadedBookRecord) async {
        await diagnostics.record(
            .started(.resumeDownload, category: .download)
        )
        guard let account = accounts[record.manifest.accountID] else {
            failure = .permissionDenied
            return
        }
        pausedDownloadIDs.remove(record.manifest.downloadID)
        resetTransferRetryBudget(for: record.manifest.downloadID)
        await repair(record, account: account)
        await diagnostics.record(
            .completed(.resumeDownload, category: .download)
        )
    }

    func resume(_ record: DownloadedBookRecord) async {
        await continueDownload(record)
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
        resetTransferRetryBudget(for: record.manifest.downloadID)
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
            _ = try await storage.preflightRemaining(
                record: record,
                tracks: tracks
            )
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
            finishTransferSpan(identity, outcome: .cancelled)
        }
        let accountRecords = records.filter {
            $0.manifest.accountID == accountID
        }
        for record in accountRecords {
            await remove(record)
        }
        accounts[accountID] = nil
    }

    func removeOrphanedDownloads(
        retaining accountIDs: Set<AccountID>
    ) async {
        let orphanedAccountIDs = Set(
            records.compactMap { record in
                accountIDs.contains(record.manifest.accountID)
                    ? nil : record.manifest.accountID
            }
        )
        for accountID in orphanedAccountIDs {
            await removeAll(for: accountID)
        }
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
                    cancelTransferInactivityWatchdog(for: identity)
                    playbackSuspendedDownloadIDs.insert(
                        identity.downloadID
                    )
                }
            } else if playbackSuspendedDownloadIDs.contains(
                identity.downloadID
            ) && !pausedDownloadIDs.contains(identity.downloadID) {
                task.resume()
                armTransferInactivityWatchdog(for: task, identity: identity)
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

    func displayedDownloadedByteLength(
        for record: DownloadedBookRecord
    ) -> Int64 {
        let current = downloadedByteLength(for: record)
        return min(
            max(
                current,
                displayedDownloadedBytes[record.manifest.downloadID] ?? 0
            ),
            max(expectedByteLength(for: record), 0)
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

    func pinAutomaticCacheTracks(
        for record: DownloadedBookRecord,
        trackIndexes: Set<Int>
    ) -> AutomaticCachePin? {
        guard record.manifest.purpose == .automaticCache,
            !trackIndexes.isEmpty,
            let current = self.record(
                accountID: record.manifest.accountID,
                itemID: record.manifest.itemID
            ),
            current.manifest.downloadID == record.manifest.downloadID,
            trackIndexes.isSubset(
                of: Set(current.manifest.entries.map(\.trackIndex))
            )
        else {
            return nil
        }
        let pin = AutomaticCachePin(
            id: UUID(),
            downloadID: current.manifest.downloadID
        )
        automaticCachePins[pin.downloadID, default: [:]][pin.id] =
            trackIndexes
        return pin
    }

    func releaseAutomaticCachePin(_ pin: AutomaticCachePin?) {
        guard let pin else {
            return
        }
        automaticCachePins[pin.downloadID]?[pin.id] = nil
        if automaticCachePins[pin.downloadID]?.isEmpty == true {
            automaticCachePins[pin.downloadID] = nil
        }
        guard deferredAutomaticCacheCleanup[pin.downloadID] != nil else {
            return
        }
        Task { @MainActor [weak self] in
            await self?.performDeferredAutomaticCacheCleanup(
                for: pin.downloadID
            )
        }
    }

    func automaticCachedPlaybackWindow(
        for record: DownloadedBookRecord,
        containing wholeBookTime: Double
    ) async -> AutomaticCachedPlaybackWindow? {
        guard record.manifest.purpose == .automaticCache,
            wholeBookTime.isFinite,
            wholeBookTime >= 0,
            let targetIndexes = record.manifest.automaticTargetTrackIndexes,
            !targetIndexes.isEmpty
        else {
            return nil
        }

        let eligible = record.manifest.entries
            .compactMap { entry -> TimedAutomaticCacheEntry? in
                guard targetIndexes.contains(entry.trackIndex),
                    entry.state == .complete,
                    entry.placement == .finalized,
                    entry.observedByteLength == entry.expectedByteLength
                else {
                    return nil
                }
                if let startOffset = entry.startOffset,
                    let duration = entry.duration,
                    startOffset.isFinite,
                    startOffset >= 0,
                    duration.isFinite,
                    duration > 0
                {
                    return TimedAutomaticCacheEntry(
                        entry: entry,
                        startOffset: startOffset,
                        duration: duration
                    )
                }
                guard record.manifest.entries.count == 1,
                    targetIndexes == [entry.trackIndex],
                    record.detail.audioFileCount == 1,
                    record.detail.duration.isFinite,
                    record.detail.duration > 0
                else {
                    return nil
                }
                return TimedAutomaticCacheEntry(
                    entry: entry,
                    startOffset: 0,
                    duration: record.detail.duration
                )
            }
            .sorted {
                ($0.startOffset, $0.entry.trackIndex)
                    < ($1.startOffset, $1.entry.trackIndex)
            }
        guard
            let containingIndex = eligible.lastIndex(where: { timed in
                timed.startOffset <= wholeBookTime
                    && wholeBookTime < timed.startOffset + timed.duration
            })
        else {
            return nil
        }

        var selected = [eligible[containingIndex]]
        var expectedStart =
            eligible[containingIndex].startOffset
            + eligible[containingIndex].duration
        for timed in eligible.dropFirst(containingIndex + 1) {
            guard abs(timed.startOffset - expectedStart) <= 0.25 else {
                break
            }
            selected.append(timed)
            expectedStart = timed.startOffset + timed.duration
        }

        let selectedIndexes = Set(selected.map(\.entry.trackIndex))
        guard
            let pin = pinAutomaticCacheTracks(
                for: record,
                trackIndexes: selectedIndexes
            )
        else {
            return nil
        }
        do {
            let urls = try await localTrackURLs(
                for: record,
                trackIndexes: selectedIndexes
            )
            let tracks = try selected.map { timed in
                guard let url = urls[timed.entry.trackIndex] else {
                    throw DownloadModelFailure.transferFailed
                }
                return AppPlaybackTrack(
                    url: url,
                    startOffset: timed.startOffset,
                    duration: timed.duration,
                    title: "Track \(timed.entry.trackIndex + 1)"
                )
            }
            return AutomaticCachedPlaybackWindow(
                downloadID: record.manifest.downloadID,
                tracks: tracks,
                trackIndexes: selectedIndexes,
                pin: pin
            )
        } catch {
            releaseAutomaticCachePin(pin)
            return nil
        }
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

    func localTrackURLs(
        for record: DownloadedBookRecord,
        trackIndexes: Set<Int>
    ) async throws(DownloadModelFailure) -> [Int: URL] {
        guard let storage else {
            throw .storageUnavailable
        }
        do {
            return try await storage.localTrackURLs(
                for: record,
                trackIndexes: trackIndexes
            )
        } catch {
            await refresh()
            throw .transferFailed
        }
    }

    private func pinnedAutomaticCacheTrackIndexes(
        for downloadID: DownloadID
    ) -> Set<Int> {
        automaticCachePins[downloadID]?.values.reduce(into: []) {
            $0.formUnion($1)
        } ?? []
    }

    private func deferAutomaticCacheCleanup(
        _ cleanup: DeferredAutomaticCacheCleanup,
        for downloadID: DownloadID
    ) {
        switch (deferredAutomaticCacheCleanup[downloadID], cleanup) {
        case (.record, _), (_, .record):
            deferredAutomaticCacheCleanup[downloadID] = .record
        case (.tracks(let existing), .tracks(let additional)):
            deferredAutomaticCacheCleanup[downloadID] =
                .tracks(existing.union(additional))
        case (nil, .tracks(let indexes)):
            deferredAutomaticCacheCleanup[downloadID] = .tracks(indexes)
        }
    }

    private func removeAutomatically(
        _ record: DownloadedBookRecord
    ) async {
        guard automaticCachePins[record.manifest.downloadID]?.isEmpty != false
        else {
            deferAutomaticCacheCleanup(
                .record,
                for: record.manifest.downloadID
            )
            return
        }
        _ = await remove(record)
    }

    private func performDeferredAutomaticCacheCleanup(
        for downloadID: DownloadID
    ) async {
        guard
            let cleanup = deferredAutomaticCacheCleanup.removeValue(
                forKey: downloadID
            ),
            let record = record(downloadID: downloadID),
            record.manifest.purpose == .automaticCache
        else {
            return
        }
        switch cleanup {
        case .record:
            await removeAutomatically(record)
        case .tracks(let trackIndexes):
            let pinned = pinnedAutomaticCacheTrackIndexes(for: downloadID)
            let deferredIndexes = trackIndexes.intersection(pinned)
            if !deferredIndexes.isEmpty {
                deferAutomaticCacheCleanup(
                    .tracks(deferredIndexes),
                    for: downloadID
                )
            }
            let removableIndexes = trackIndexes.subtracting(pinned)
            guard !removableIndexes.isEmpty, let storage else {
                return
            }
            do {
                _ = try await storage.removeCompletedTracks(
                    from: record,
                    trackIndexes: removableIndexes
                )
                await refresh()
            } catch {
                failure = .transferFailed
            }
        }
    }

    private func refresh() async {
        guard let storage else {
            failure = .storageUnavailable
            return
        }
        do {
            records = try await storage.records()
            pausedDownloadIDs = Set(
                records.compactMap {
                    $0.manifest.state == .paused
                        ? $0.manifest.downloadID : nil
                }
            )
            let currentIDs = Set(records.map(\.manifest.downloadID))
            for downloadID in Array(progress.keys)
            where !currentIDs.contains(downloadID) {
                progress[downloadID] = nil
                displayedDownloadedBytes[downloadID] = nil
            }
            for record in records {
                updateProgress(for: record.manifest.downloadID)
            }
        } catch {
            failure = .storageUnavailable
        }
    }

    private func reconcileTransfer(
        identity: DownloadTaskIdentity,
        taskDescription: String,
        outcome: DownloadTransferOutcome
    ) async {
        guard let storage else {
            failure = .storageUnavailable
            return
        }
        var context = transferContext(
            for: identity,
            taskDescription: taskDescription
        )

        if context.isDeleting {
            try? await storage.removeTrackFiles(identity)
            finishTransferSpan(identity, outcome: .cancelled)
            clearTransferredBytes(for: identity)
            return
        }

        if context.isSuperseded {
            if case .chunkStored = outcome {
                try? await storage.removeTrackFiles(identity)
                _ = try? await storage.markQueued(identity)
                await refresh()
            }
            supersededAutomaticTasks.remove(taskDescription)
            finishTransferSpan(identity, outcome: .cancelled)
            clearTransferredBytes(for: identity)
            return
        }

        switch outcome {
        case .chunkStored(
            let committedByteLength,
            let validator,
            let finalized
        ):
            if context.isCancelled {
                try? await storage.removeTrackFiles(identity)
                _ = try? await storage.markFailed(identity)
                finishTransferSpan(identity, outcome: .cancelled)
                clearTransferredBytes(for: identity)
                await refresh()
                return
            }
            do {
                _ = try await storage.recordCommittedChunk(
                    identity,
                    committedByteLength: committedByteLength,
                    validator: validator,
                    finalized: finalized
                )
                transferRetryCounts[AutomaticDownloadTaskKey(identity)] = nil
                terminalTransferTaskKeys.remove(
                    AutomaticDownloadTaskKey(identity)
                )
                clearTransferredBytes(for: identity)
                await refresh()
                context = transferContext(
                    for: identity,
                    taskDescription: taskDescription
                )
                if context.isDeleting {
                    try? await storage.removeTrackFiles(identity)
                    finishTransferSpan(identity, outcome: .cancelled)
                    clearTransferredBytes(for: identity)
                    return
                }
                if context.isCancelled {
                    try? await storage.removeTrackFiles(identity)
                    _ = try? await storage.markFailed(identity)
                    finishTransferSpan(identity, outcome: .cancelled)
                    clearTransferredBytes(for: identity)
                    await refresh()
                    return
                }
                if context.isSuperseded {
                    try? await storage.removeTrackFiles(identity)
                    _ = try? await storage.markQueued(identity)
                    supersededAutomaticTasks.remove(taskDescription)
                    finishTransferSpan(identity, outcome: .cancelled)
                    clearTransferredBytes(for: identity)
                    await refresh()
                    return
                }
                let nextAction = DownloadTransferReconciler.nextAction(
                    after: .chunkStored(finalized: finalized),
                    context: context
                )
                if context.isPaused {
                    if !finalized {
                        _ = try await storage.markPaused(
                            identity,
                            observedByteLength: committedByteLength
                        )
                        await refresh()
                    } else {
                        finishTransferSpan(identity, outcome: .succeeded)
                    }
                    return
                }
                if finalized {
                    if let current = record(
                        downloadID: identity.downloadID
                    ), !current.manifest.entries.contains(where: {
                        $0.state != .complete
                    }) {
                        pendingRecoveryDownloadIDs.remove(
                            identity.downloadID
                        )
                        pendingRecoveryTaskKeys =
                            pendingRecoveryTaskKeys.filter {
                                $0.downloadID != identity.downloadID
                            }
                    }
                    finishTransferSpan(identity, outcome: .succeeded)
                    await diagnostics.record(
                        .completed(.completeDownload, category: .download)
                    )
                    if nextAction == .advanceAutomaticDownload {
                        await advanceAutomaticDownload(after: identity)
                    }
                    return
                }
                guard nextAction == .continueChunk else { return }
                guard let account = accounts[identity.accountID],
                    let currentRecord = record(
                        downloadID: identity.downloadID
                    )
                else {
                    throw DownloadModelFailure.permissionDenied
                }
                try await scheduleChunk(
                    identity: identity,
                    account: account,
                    purpose: currentRecord.manifest.purpose,
                    storage: storage
                )
                await refresh()
            } catch {
                finishTransferSpan(identity, outcome: .failed(.localStorage))
                _ = try? await storage.markFailed(identity)
                failure = .transferFailed
                await refresh()
            }

        case .placementRejected:
            guard !context.isPaused,
                !context.isSuperseded,
                !context.isCancelled
            else {
                finishTransferSpan(identity, outcome: .cancelled)
                clearTransferredBytes(for: identity)
                return
            }
            finishTransferSpan(identity, outcome: .failed(.media))
            _ = try? await storage.markFailed(identity)
            clearTransferredBytes(for: identity)
            failure = .transferFailed
            await refresh()

        case .transportFailed(let rejectedRequest):
            guard
                await recordFailedTransferForReconciliation(
                    identity,
                    taskDescription: taskDescription,
                    result: .retryableFailure,
                    category: .transport,
                    retryDisposition: .afterNetworkChange,
                    storage: storage
                ) == .retry
            else { return }
            await recoverRetryableTransfer(
                rejectedRequest,
                taskDescription: taskDescription,
                identity: identity,
                terminalFailure: .transportUnavailable,
                category: .transport,
                storage: storage
            )
        case .unauthorized(let rejectedRequest):
            guard
                await recordFailedTransferForReconciliation(
                    identity,
                    taskDescription: taskDescription,
                    result: .retryableFailure,
                    category: .authentication,
                    retryDisposition: .immediate,
                    storage: storage
                ) == .retry
            else { return }
            guard let account = accounts[identity.accountID] else {
                failure = .permissionDenied
                return
            }
            do {
                let replacement =
                    try await service
                    .replacementDownloadRequest(
                        for: account,
                        identity: identity,
                        rejectedRequest: rejectedRequest
                    )
                _ = await scheduleReconciledReplacement(
                    replacement,
                    taskDescription: taskDescription,
                    identity: identity,
                    retryCount: 1
                )
            } catch {
                _ = try? await storage.markFailed(identity)
                failure = .transferFailed
                await refresh()
            }

        case .requestRejected(let statusCode, let rejectedRequest):
            let category = Self.remoteTelemetryFailureCategory(
                statusCode: statusCode,
                hasTransportError: false
            )
            if Self.isRetryableTransferStatus(statusCode) {
                guard
                    await recordFailedTransferForReconciliation(
                        identity,
                        taskDescription: taskDescription,
                        result: .retryableFailure,
                        category: category,
                        retryDisposition: .afterNetworkChange,
                        storage: storage
                    ) == .retry
                else { return }
                await recoverRetryableTransfer(
                    rejectedRequest,
                    taskDescription: taskDescription,
                    identity: identity,
                    terminalFailure: .requestRejected(
                        statusCode: statusCode
                    ),
                    category: category,
                    storage: storage
                )
                return
            }
            _ = await recordFailedTransferForReconciliation(
                identity,
                taskDescription: taskDescription,
                result: .terminalFailure,
                category: category,
                retryDisposition: .immediate,
                storage: storage
            )
            failure = .requestRejected(statusCode: statusCode)
        }
    }

    private func recordFailedTransferForReconciliation(
        _ identity: DownloadTaskIdentity,
        taskDescription: String,
        result: DownloadTransferResult,
        category: RemoteTelemetryFailureCategory,
        retryDisposition: DownloadRetryDisposition,
        storage: DownloadStorage
    ) async -> DownloadTransferNextAction {
        let context = transferContext(
            for: identity,
            taskDescription: taskDescription
        )
        let nextAction = DownloadTransferReconciler.nextAction(
            after: result,
            context: context
        )
        guard nextAction != .stop else {
            finishTransferSpan(identity, outcome: .cancelled)
            clearTransferredBytes(for: identity)
            return .stop
        }
        finishTransferSpan(identity, outcome: .failed(category))
        clearTransferredBytes(for: identity)
        if result == .retryableFailure {
            if retryDisposition == .afterNetworkChange {
                pendingRecoveryDownloadIDs.insert(identity.downloadID)
                pendingRecoveryTaskKeys.insert(
                    AutomaticDownloadTaskKey(identity)
                )
            }
            await refresh()
            return nextAction
        }
        pendingRecoveryTaskKeys.remove(AutomaticDownloadTaskKey(identity))
        terminalTransferTaskKeys.insert(AutomaticDownloadTaskKey(identity))
        if !pendingRecoveryTaskKeys.contains(where: {
            $0.downloadID == identity.downloadID
        }) {
            pendingRecoveryDownloadIDs.remove(identity.downloadID)
        }
        _ = try? await storage.markFailed(identity)
        failure = .transferFailed
        await refresh()
        guard record(downloadID: identity.downloadID) != nil else {
            return .fail
        }
        return nextAction
    }

    private func recoverRetryableTransfer(
        _ rejectedRequest: URLRequest?,
        taskDescription: String,
        identity: DownloadTaskIdentity,
        terminalFailure: DownloadModelFailure,
        category: RemoteTelemetryFailureCategory,
        storage: DownloadStorage
    ) async {
        let key = AutomaticDownloadTaskKey(identity)
        guard let rejectedRequest,
            pendingRecoveryTaskKeys.contains(key)
        else { return }

        if let rejectedURL = rejectedRequest.url,
            let fallbackRequest =
                await service.primaryFallbackDownloadRequest(
                    for: rejectedRequest
                ),
            fallbackRequest.url != rejectedURL,
            pendingRecoveryTaskKeys.contains(key),
            await scheduleReconciledReplacement(
                fallbackRequest,
                taskDescription: taskDescription,
                identity: identity,
                retryCount: 1
            )
        {
            resolvePendingRecovery(for: identity)
            return
        }

        guard networkPathState.availability == .satisfied else {
            return
        }
        let retryCount = transferRetryCounts[key, default: 0]
        guard retryCount < Self.maximumTransferRetries else {
            _ = await recordFailedTransferForReconciliation(
                identity,
                taskDescription: taskDescription,
                result: .terminalFailure,
                category: category,
                retryDisposition: .immediate,
                storage: storage
            )
            failure = terminalFailure
            return
        }
        let nextRetryCount = retryCount + 1
        transferRetryCounts[key] = nextRetryCount
        do {
            try await transferRetrySleep(
                .seconds(1 << (nextRetryCount - 1))
            )
        } catch {
            return
        }
        guard pendingRecoveryTaskKeys.contains(key),
            networkPathState.availability == .satisfied
        else {
            return
        }
        if await scheduleReconciledReplacement(
            rejectedRequest,
            taskDescription: taskDescription,
            identity: identity,
            retryCount: nextRetryCount
        ) {
            resolvePendingRecovery(for: identity)
        }
    }

    private func resolvePendingRecovery(for identity: DownloadTaskIdentity) {
        pendingRecoveryTaskKeys.remove(AutomaticDownloadTaskKey(identity))
        if !pendingRecoveryTaskKeys.contains(where: {
            $0.downloadID == identity.downloadID
        }) {
            pendingRecoveryDownloadIDs.remove(identity.downloadID)
        }
    }

    private func advanceAutomaticDownload(
        after identity: DownloadTaskIdentity
    ) async {
        guard
            record(downloadID: identity.downloadID)?.manifest.purpose
                == .automaticCache
        else { return }
        let key = AutomaticDownloadKey(
            accountID: identity.accountID,
            itemID: identity.itemID
        )
        guard let activity = latestAutomaticProgress[key],
            !playbackBlockedAutomaticDownloads.contains(key)
        else { return }
        await handleAutomaticPlaybackActivity(activity)
    }

    private func recordCompletionOutcome(
        task: URLSessionTask,
        error: (any Error)?
    ) async {
        guard let description = task.taskDescription,
            let descriptor = try? DownloadChunkTaskDescription.decode(
                description
            )
        else {
            return
        }
        let identity = descriptor.identity
        cancelTransferInactivityWatchdog(for: identity)
        if error != nil {
            await reconcileTransfer(
                identity: identity,
                taskDescription: description,
                outcome: .transportFailed(
                    rejectedRequest:
                        task.currentRequest ?? task.originalRequest
                )
            )
            return
        }
        guard let response = task.response as? HTTPURLResponse else {
            return
        }
        switch Self.transferHTTPDisposition(statusCode: response.statusCode) {
        case .retryableFailure, .terminalFailure:
            await reconcileTransfer(
                identity: identity,
                taskDescription: description,
                outcome: .requestRejected(
                    statusCode: response.statusCode,
                    rejectedRequest:
                        task.currentRequest ?? task.originalRequest
                )
            )
            return
        case .success:
            if let url = response.url ?? task.currentRequest?.url
                ?? task.originalRequest?.url
            {
                await service.recordServerActivity(
                    url: url,
                    purpose: .download
                )
            }
            return
        case .unauthorized:
            guard let request = task.originalRequest else {
                await reconcileTransfer(
                    identity: identity,
                    taskDescription: description,
                    outcome: .requestRejected(
                        statusCode: response.statusCode,
                        rejectedRequest: task.currentRequest
                    )
                )
                return
            }
            await reconcileTransfer(
                identity: identity,
                taskDescription: description,
                outcome: .unauthorized(rejectedRequest: request)
            )
            return
        }
    }

    static func transferHTTPDisposition(
        statusCode: Int
    ) -> DownloadTransferHTTPDisposition {
        if statusCode == 206 {
            return .success
        }
        if statusCode == 401 {
            return .unauthorized
        }
        if isRetryableTransferStatus(statusCode) {
            return .retryableFailure
        }
        return .terminalFailure
    }

    private func scheduleReconciledReplacement(
        _ request: URLRequest,
        taskDescription: String,
        identity: DownloadTaskIdentity,
        retryCount: Int
    ) async -> Bool {
        let initialContext = transferContext(
            for: identity,
            taskDescription: taskDescription
        )
        guard let storage,
            !initialContext.isPaused,
            !initialContext.isCancelled,
            !initialContext.isDeleting,
            !initialContext.isSuperseded,
            let currentRecord = record(downloadID: identity.downloadID),
            currentRecord.manifest.state != .paused
        else { return false }
        do {
            let committed = try await storage.partialByteLength(identity)
            _ = try await storage.markDownloading(
                identity,
                observedByteLength: committed,
                validator: currentRecord.manifest.entries.first(where: {
                    $0.trackIndex == identity.trackIndex
                })?.validator
            )
            failure = nil
        } catch {
            failure = .transferFailed
            return false
        }
        let currentContext = transferContext(
            for: identity,
            taskDescription: taskDescription
        )
        guard !currentContext.isPaused,
            !currentContext.isCancelled,
            !currentContext.isDeleting,
            !currentContext.isSuperseded
        else {
            if currentContext.isPaused {
                let committed =
                    (try? await storage.partialByteLength(identity))
                    ?? 0
                _ = try? await storage.markPaused(
                    identity,
                    observedByteLength: committed
                )
            } else if currentContext.isCancelled {
                try? await storage.removeTrackFiles(identity)
                _ = try? await storage.markFailed(identity)
            } else if currentContext.isSuperseded {
                try? await storage.removeTrackFiles(identity)
                _ = try? await storage.markQueued(identity)
            }
            return false
        }
        var replacement = request
        let automatic =
            record(downloadID: identity.downloadID)?
            .manifest.purpose == .automaticCache
        if automatic {
            replacement.networkServiceType = .background
        }
        let replacementTask = session.downloadTask(
            with: networkPolicy.applying(to: replacement)
        )
        replacementTask.taskDescription = taskDescription
        replacementTask.priority =
            automatic
            ? URLSessionTask.lowPriority
            : URLSessionTask.defaultPriority
        beginTransferSpan(
            identity,
            purpose: automatic ? .automaticCache : .manual,
            retryCount: retryCount
        )
        clearTransferredBytes(for: identity)
        if let record = record(downloadID: identity.downloadID),
            automaticDownloadIsBlocked(record)
        {
            playbackSuspendedDownloadIDs.insert(identity.downloadID)
        } else {
            replacementTask.resume()
            armTransferInactivityWatchdog(
                for: replacementTask,
                identity: identity
            )
        }
        return true
    }

    private func beginTransferSpan(
        _ identity: DownloadTaskIdentity,
        purpose: DownloadPurpose,
        retryCount: Int = 0
    ) {
        let key = AutomaticDownloadTaskKey(identity)
        guard transferSpans[key] == nil else { return }
        transferSpans[key] = remoteTelemetryTracer.beginSpan(
            operation: .downloadTransfer,
            source: purpose == .automaticCache ? .cache : .remote,
            retryBucket: RemoteTelemetryRetryBucket(
                retryCount: retryCount
            )
        )
    }

    private func finishTransferSpan(
        _ identity: DownloadTaskIdentity,
        outcome: RemoteTelemetryOutcome
    ) {
        let span = transferSpans.removeValue(
            forKey: AutomaticDownloadTaskKey(identity)
        )
        span?.end(outcome)
    }

    private static func remoteTelemetryFailureCategory(
        statusCode: Int,
        hasTransportError: Bool
    ) -> RemoteTelemetryFailureCategory {
        if hasTransportError { return .transport }
        switch statusCode {
        case 401: return .authentication
        case 403: return .authorization
        case 408: return .timeout
        case 429: return .rateLimited
        case 500...599: return .serverRejected
        default: return .serverRejected
        }
    }

    static func isRetryableTransferStatus(_ statusCode: Int) -> Bool {
        switch statusCode {
        case 200, 408, 425, 429, 500...599:
            true
        default:
            false
        }
    }

    private func armTransferInactivityWatchdog(
        for task: URLSessionTask,
        identity: DownloadTaskIdentity
    ) {
        guard isForegroundActive,
            networkPathState.availability == .satisfied,
            task.state == .running
        else { return }
        let key = AutomaticDownloadTaskKey(identity)
        transferInactivityWatchdogs[key]?.timer.cancel()
        let taskIdentifier = task.taskIdentifier
        let timer = Task { @MainActor [weak self, weak task] in
            try? await Task.sleep(
                for: .seconds(Self.transferInactivityTimeoutSeconds)
            )
            guard !Task.isCancelled,
                let self,
                self.transferInactivityWatchdogs[key]?.taskIdentifier
                    == taskIdentifier
            else { return }
            self.transferInactivityWatchdogs[key] = nil
            task?.cancel()
        }
        transferInactivityWatchdogs[key] = TransferInactivityWatchdog(
            taskIdentifier: taskIdentifier,
            timer: timer
        )
    }

    private func cancelTransferInactivityWatchdog(
        for identity: DownloadTaskIdentity
    ) {
        let key = AutomaticDownloadTaskKey(identity)
        transferInactivityWatchdogs.removeValue(forKey: key)?.timer.cancel()
    }

    private func cancelAllTransferInactivityWatchdogs() {
        for watchdog in transferInactivityWatchdogs.values {
            watchdog.timer.cancel()
        }
        transferInactivityWatchdogs = [:]
    }

    private func armWatchdogsForActiveTransfers() async {
        for task in await session.allTasks where task.state == .running {
            guard let description = task.taskDescription,
                let identity = try? DownloadTaskIdentity
                    .decodeTaskDescription(description)
            else { continue }
            armTransferInactivityWatchdog(for: task, identity: identity)
        }
    }

    private func resetTransferRetryBudget(for downloadID: DownloadID) {
        transferRetryCounts = transferRetryCounts.filter {
            $0.key.downloadID != downloadID
        }
        terminalTransferTaskKeys = terminalTransferTaskKeys.filter {
            $0.downloadID != downloadID
        }
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
        let displayedBytes = min(
            max(
                downloadedByteLength(for: record),
                displayedDownloadedBytes[downloadID] ?? 0
            ),
            expected
        )
        displayedDownloadedBytes[downloadID] = displayedBytes
        progress[downloadID] = min(
            max(
                Double(displayedBytes)
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

    private static func identity(
        for entry: DownloadManifestEntry,
        record: DownloadedBookRecord
    ) -> DownloadTaskIdentity? {
        guard let inode = entry.inode,
            let safeExtension = SafeAudioExtension(
                rawValue: URL(fileURLWithPath: entry.destinationEntry)
                    .pathExtension
            )
        else {
            return nil
        }
        return try? DownloadTaskIdentity(
            downloadID: record.manifest.downloadID,
            accountID: record.manifest.accountID,
            itemID: record.manifest.itemID,
            track: DownloadTrackPlan(
                index: entry.trackIndex,
                inode: inode,
                expectedByteLength: entry.expectedByteLength,
                mimeType: "stored",
                safeExtension: safeExtension,
                destinationEntry: entry.destinationEntry,
                startOffset: entry.startOffset,
                duration: entry.duration
            )
        )
    }

    private func taskDescriptorIsCurrent(
        _ descriptor: DownloadChunkTaskDescription,
        storage: DownloadStorage?
    ) async -> Bool {
        let identity = descriptor.identity
        guard let storage,
            let record = record(downloadID: identity.downloadID),
            record.manifest.accountID == identity.accountID,
            record.manifest.itemID == identity.itemID,
            record.manifest.state != .paused,
            record.manifest.state != .deleting,
            let entry = record.manifest.entries.first(where: {
                $0.trackIndex == identity.trackIndex
            }),
            entry.state != .complete,
            entry.inode == identity.inode,
            entry.expectedByteLength == identity.expectedByteLength,
            entry.destinationEntry == identity.destinationEntry,
            entry.validator == descriptor.validator,
            let committed = try? await storage.partialByteLength(identity),
            let expectedRange = try? DownloadByteRange.next(
                committedByteLength: committed,
                expectedByteLength: identity.expectedByteLength,
                chunkByteLength: Self.rangeChunkByteLength
            ),
            expectedRange == descriptor.range
        else {
            return false
        }
        return true
    }

    private func transferContext(
        for identity: DownloadTaskIdentity,
        taskDescription: String
    ) -> DownloadTransferContext {
        let currentRecord = record(downloadID: identity.downloadID)
        let noLongerAutomaticTarget =
            currentRecord?.manifest.purpose == .automaticCache
            && currentRecord?.manifest.automaticTargetTrackIndexes?.contains(
                identity.trackIndex
            ) == false
        return DownloadTransferContext(
            isPaused: pausedDownloadIDs.contains(identity.downloadID)
                || currentRecord?.manifest.state == .paused,
            isCancelled: cancelledDownloadIDs.contains(identity.downloadID),
            isDeleting: deletingDownloadIDs.contains(identity.downloadID),
            isSuperseded: supersededAutomaticTasks.contains(taskDescription)
                || noLongerAutomaticTarget,
            isAutomatic: currentRecord?.manifest.purpose == .automaticCache
        )
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response as? HTTPURLResponse,
            let description = downloadTask.taskDescription,
            let descriptor = try? DownloadChunkTaskDescription.decode(
                description
            ),
            let layout
        else {
            return
        }
        guard response.statusCode == 206 else {
            return
        }
        let identity = descriptor.identity
        let result = Result {
            try DownloadRangeResponseValidator.validate(
                statusCode: response.statusCode,
                contentRangeHeader: response.value(
                    forHTTPHeaderField: "Content-Range"
                ),
                requestedRange: descriptor.range,
                expectedTotalByteLength: identity.expectedByteLength
            )
            let validator =
                descriptor.validator
                ?? DownloadRangeResponseValidator.validator(
                    etag: response.value(forHTTPHeaderField: "ETag"),
                    lastModified: response.value(
                        forHTTPHeaderField: "Last-Modified"
                    )
                )
            let committed = try layout.appendChunk(
                from: location,
                identity: identity,
                expectedOffset: descriptor.range.start,
                expectedChunkLength: descriptor.range.length
            )
            let finalized = committed == identity.expectedByteLength
            if finalized {
                _ = try layout.finalizePartial(identity)
            }
            return (committed, validator, finalized)
        }
        Task { @MainActor [weak self] in
            switch result {
            case .success(let placement):
                await self?.reconcileTransfer(
                    identity: identity,
                    taskDescription: description,
                    outcome: .chunkStored(
                        committedByteLength: placement.0,
                        validator: placement.1,
                        finalized: placement.2
                    )
                )
            case .failure:
                await self?.reconcileTransfer(
                    identity: identity,
                    taskDescription: description,
                    outcome: .placementRejected
                )
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            await self?.recordCompletionOutcome(task: task, error: error)
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
                ) == false,
                self?.cancelledDownloadIDs.contains(
                    identity.downloadID
                ) == false
            else {
                return
            }
            self?.updateTransferredBytes(
                totalBytesWritten,
                for: identity
            )
            self?.armTransferInactivityWatchdog(
                for: downloadTask,
                identity: identity
            )
        }
    }

    nonisolated func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession
    ) {
        #if os(iOS)
            Task { @MainActor in
                let completion =
                    BleatAppDelegate.backgroundDownloadCompletion
                BleatAppDelegate.backgroundDownloadCompletion = nil
                completion?()
            }
        #endif
    }
}
