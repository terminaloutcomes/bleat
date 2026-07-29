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
    private nonisolated let layout: DownloadStorageLayout?
    private let storage: DownloadStorage?
    private var accounts: [AccountID: ServerAccount] = [:]
    private var deletingDownloadIDs: Set<DownloadID> = []
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

    private func schedule(
        plan: DownloadPlan,
        detail: LibraryBookDetail,
        account: ServerAccount,
        storage: DownloadStorage
    ) async throws {
        let downloadID = DownloadID(
            rawValue: UUID().uuidString.lowercased()
        )
        _ = try await storage.create(
            downloadID: downloadID,
            accountID: account.id,
            plan: plan,
            detail: detail
        )
        for track in plan.tracks {
            let identity = try DownloadTaskIdentity(
                downloadID: downloadID,
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
