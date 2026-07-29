import Foundation

public struct LibrarySearchContext: Hashable, Sendable {
    public let accountID: AccountID
    public let libraryID: LibraryID

    public init(
        accountID: AccountID,
        libraryID: LibraryID
    ) {
        self.accountID = accountID
        self.libraryID = libraryID
    }
}

public enum LibrarySearchCoordinatorError:
    Error,
    Equatable,
    Sendable
{
    case superseded
    case cancelled
    case repository(LibraryRepositoryError)
}

private enum LibrarySearchTaskResult: Sendable {
    case success(
        LibraryRepositoryResult<[LibraryBookSummary]>
    )
    case repositoryFailure(LibraryRepositoryError)
    case cancelled
}

public actor LibrarySearchCoordinator {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias Operation = @Sendable (
        LibrarySearchContext,
        LibrarySearchRequest
    ) async throws(LibraryRepositoryError)
        -> LibraryRepositoryResult<[LibraryBookSummary]>

    private let debounceDuration: Duration
    private let sleep: Sleep
    private var generation: UInt64 = 0
    private var activeTask: Task<LibrarySearchTaskResult, Never>?

    public init(
        debounceDuration: Duration = .milliseconds(300),
        sleep: @escaping Sleep = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.debounceDuration = debounceDuration
        self.sleep = sleep
    }

    public func search(
        context: LibrarySearchContext,
        request: LibrarySearchRequest,
        operation: @escaping Operation
    ) async throws(LibrarySearchCoordinatorError)
        -> LibraryRepositoryResult<[LibraryBookSummary]>
    {
        generation &+= 1
        let operationGeneration = generation
        activeTask?.cancel()

        let debounceDuration = debounceDuration
        let sleep = sleep
        let task: Task<LibrarySearchTaskResult, Never> = Task {
            do {
                try await sleep(debounceDuration)
            } catch {
                return .cancelled
            }
            guard !Task.isCancelled else {
                return .cancelled
            }
            do {
                let result = try await operation(context, request)
                guard !Task.isCancelled else {
                    return .cancelled
                }
                return .success(result)
            } catch let error as LibraryRepositoryError {
                return .repositoryFailure(error)
            } catch {
                return .cancelled
            }
        }
        activeTask = task

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard generation == operationGeneration else {
            throw .superseded
        }
        activeTask = nil

        switch result {
        case let .success(value):
            return value
        case let .repositoryFailure(error):
            if error == .cancelled {
                throw .cancelled
            }
            throw .repository(error)
        case .cancelled:
            throw .cancelled
        }
    }
}
