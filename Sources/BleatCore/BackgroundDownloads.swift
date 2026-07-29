import Foundation

public let bleatBackgroundDownloadSessionIdentifier =
    "app.bleat.background-downloads.v1"

public struct BackgroundDownloadTaskSnapshot: Sendable {
    public let taskIdentifier: Int
    public let taskDescription: String?
    public let originalRequest: URLRequest?

    public init(
        taskIdentifier: Int,
        taskDescription: String?,
        originalRequest: URLRequest?
    ) {
        self.taskIdentifier = taskIdentifier
        self.taskDescription = taskDescription
        self.originalRequest = originalRequest
    }
}

public protocol BackgroundDownloadScheduling: Sendable {
    func schedule(
        request: URLRequest,
        taskDescription: String
    ) async throws -> Int

    func taskSnapshots() async -> [BackgroundDownloadTaskSnapshot]
}

public actor SystemBackgroundDownloadScheduler:
    BackgroundDownloadScheduling
{
    public static let defaultMaximumConnectionsPerHost = 3

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: bleatBackgroundDownloadSessionIdentifier
        )
        configuration.httpMaximumConnectionsPerHost =
            Self.defaultMaximumConnectionsPerHost
        session = URLSession(configuration: configuration)
    }

    public func schedule(
        request: URLRequest,
        taskDescription: String
    ) -> Int {
        let task = session.downloadTask(with: request)
        task.taskDescription = taskDescription
        task.resume()
        return task.taskIdentifier
    }

    public func taskSnapshots() async -> [BackgroundDownloadTaskSnapshot] {
        await session.allTasks.map {
            BackgroundDownloadTaskSnapshot(
                taskIdentifier: $0.taskIdentifier,
                taskDescription: $0.taskDescription,
                originalRequest: $0.originalRequest
            )
        }
    }
}

public protocol DownloadRequestAuthorizing: Sendable {
    func makeAuthorizedDownloadRequest(
        identity: DownloadTaskIdentity,
        server: NormalizedServerURL
    ) async throws -> URLRequest

    func makeReplacementDownloadRequest(
        identity: DownloadTaskIdentity,
        server: NormalizedServerURL,
        rejectedRequest: URLRequest
    ) async throws -> URLRequest
}

public enum RestoredDownloadTaskState: Equatable, Sendable {
    case restored(DownloadTaskIdentity)
    case missingDescription
    case invalidDescription
}

public struct RestoredDownloadTask: Equatable, Sendable {
    public let taskIdentifier: Int
    public let state: RestoredDownloadTaskState
}

public struct ScheduledDownload: Equatable, Sendable {
    public let systemTaskIdentifier: Int
    public let identity: DownloadTaskIdentity
}

public actor DownloadCoordinator<
    Scheduler: BackgroundDownloadScheduling,
    Authorizer: DownloadRequestAuthorizing
> {
    private let scheduler: Scheduler
    private let authorizer: Authorizer

    public init(scheduler: Scheduler, authorizer: Authorizer) {
        self.scheduler = scheduler
        self.authorizer = authorizer
    }

    public func schedule(
        plan: DownloadPlan,
        accountID: AccountID,
        server: NormalizedServerURL,
        downloadID: DownloadID = DownloadID(
            rawValue: UUID().uuidString.lowercased()
        )
    ) async throws -> [ScheduledDownload] {
        var scheduled: [ScheduledDownload] = []
        scheduled.reserveCapacity(plan.tracks.count)
        for track in plan.tracks {
            let identity = try DownloadTaskIdentity(
                downloadID: downloadID,
                accountID: accountID,
                itemID: plan.itemID,
                track: track
            )
            let request = try await authorizer
                .makeAuthorizedDownloadRequest(
                    identity: identity,
                    server: server
                )
            let taskIdentifier = try await scheduler.schedule(
                request: request,
                taskDescription: identity.taskDescription()
            )
            scheduled.append(ScheduledDownload(
                systemTaskIdentifier: taskIdentifier,
                identity: identity
            ))
        }
        return scheduled
    }

    public func restoreTasks() async -> [RestoredDownloadTask] {
        await scheduler.taskSnapshots().map { snapshot in
            guard let description = snapshot.taskDescription else {
                return RestoredDownloadTask(
                    taskIdentifier: snapshot.taskIdentifier,
                    state: .missingDescription
                )
            }
            do {
                return RestoredDownloadTask(
                    taskIdentifier: snapshot.taskIdentifier,
                    state: .restored(
                        try DownloadTaskIdentity.decodeTaskDescription(
                            description
                        )
                    )
                )
            } catch {
                return RestoredDownloadTask(
                    taskIdentifier: snapshot.taskIdentifier,
                    state: .invalidDescription
                )
            }
        }
    }

    public func replaceUnauthorizedTask(
        identity: DownloadTaskIdentity,
        server: NormalizedServerURL,
        rejectedRequest: URLRequest
    ) async throws -> ScheduledDownload {
        let replacement = try await authorizer
            .makeReplacementDownloadRequest(
                identity: identity,
                server: server,
                rejectedRequest: rejectedRequest
            )
        let taskIdentifier = try await scheduler.schedule(
            request: replacement,
            taskDescription: identity.taskDescription()
        )
        return ScheduledDownload(
            systemTaskIdentifier: taskIdentifier,
            identity: identity
        )
    }
}
