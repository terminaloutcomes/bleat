import Foundation
import Testing

@testable import BleatCore

@Suite(.serialized)
final class LibrarySearchCoordinatorTests {
    @Test
    func testDefaultSleeperRunsZeroDurationSearch() async throws {
        let service = SearchTestService()
        let coordinator = LibrarySearchCoordinator(
            debounceDuration: .zero
        )

        let result = try await coordinator.search(
            context: Self.context(account: "a", library: "one"),
            request: try LibrarySearchRequest(query: "book"),
            operation: service.search
        )

        #expect(result.source == .remote)
    }

    @Test
    func testDebouncesForConfiguredDurationBeforeSearching()
        async throws
    {
        let sleeper = SearchTestSleeper()
        let service = SearchTestService()
        let coordinator = LibrarySearchCoordinator(
            debounceDuration: .milliseconds(300),
            sleep: { duration in
                try await sleeper.sleep(for: duration)
            }
        )
        let context = Self.context(account: "a", library: "one")
        let request = try LibrarySearchRequest(query: "book")

        let task = Task {
            try await coordinator.search(
                context: context,
                request: request,
                operation: service.search
            )
        }
        await sleeper.waitForSleepCount(1)
        let initialCallCount = await service.callCount()
        let requestedDurations = await sleeper.requestedDurations()
        #expect(initialCallCount == 0)
        #expect(requestedDurations == [.milliseconds(300)])

        await sleeper.resumeAll()
        let result = try await task.value
        let finalCallCount = await service.callCount()
        #expect(result.source == .remote)
        #expect(finalCallCount == 1)
    }

    @Test
    func testNewQuerySupersedesPendingDebounce() async throws {
        let sleeper = SearchTestSleeper()
        let service = SearchTestService()
        let coordinator = LibrarySearchCoordinator(
            sleep: { duration in
                try await sleeper.sleep(for: duration)
            }
        )
        let context = Self.context(account: "a", library: "one")
        let firstRequest = try LibrarySearchRequest(query: "first")
        let secondRequest = try LibrarySearchRequest(query: "second")

        let first = Task.detached {
            await performSearchForTest(
                coordinator: coordinator,
                context: context,
                request: firstRequest,
                service: service
            )
        }
        await sleeper.waitForSleepCount(1)
        let second = Task.detached {
            await performSearchForTest(
                coordinator: coordinator,
                context: context,
                request: secondRequest,
                service: service
            )
        }
        await sleeper.waitForSleepCount(2)
        let firstResult = await first.value
        #expect(await sleeper.pendingCount() == 1)
        await sleeper.resumeAll()

        let secondResult = await second.value
        Self.assertFailure(firstResult, equals: .superseded)
        guard case .success = secondResult else {
            Issue.record("Expected second search to succeed")
            return
        }
        let calls = await service.calls()
        #expect(calls.map(\.request.query) == ["second"])
    }

    @Test
    func testAccountAndLibraryChangeCancelsInFlightSearch()
        async throws
    {
        let sleeper = SearchTestSleeper()
        let service = SearchTestService(blockFirstCall: true)
        let coordinator = LibrarySearchCoordinator(
            sleep: { duration in
                try await sleeper.sleep(for: duration)
            }
        )
        let firstContext = Self.context(
            account: "first-account",
            library: "first-library"
        )
        let secondContext = Self.context(
            account: "second-account",
            library: "second-library"
        )
        let request = try LibrarySearchRequest(query: "book")

        let first = Task.detached {
            await performSearchForTest(
                coordinator: coordinator,
                context: firstContext,
                request: request,
                service: service
            )
        }
        await sleeper.waitForSleepCount(1)
        await sleeper.resumeAll()
        await service.waitForFirstCall()

        let second = Task.detached {
            await performSearchForTest(
                coordinator: coordinator,
                context: secondContext,
                request: request,
                service: service
            )
        }
        await sleeper.waitForSleepCount(2)
        await sleeper.resumeAll()

        let firstResult = await first.value
        let secondResult = await second.value
        Self.assertFailure(firstResult, equals: .superseded)
        guard case .success = secondResult else {
            Issue.record("Expected replacement search to succeed")
            return
        }
        let calls = await service.calls()
        let cancelledCallCount =
            await service.cancelledCallCount()
        #expect(calls.map(\.context) == [firstContext, secondContext])
        #expect(cancelledCallCount == 1)
    }

    @Test
    func testCallerCancellationStopsPendingDebounce() async throws {
        let sleeper = SearchTestSleeper()
        let service = SearchTestService()
        let coordinator = LibrarySearchCoordinator(
            sleep: { duration in
                try await sleeper.sleep(for: duration)
            }
        )
        let request = try LibrarySearchRequest(query: "book")
        let context = Self.context(account: "a", library: "one")

        let task = Task.detached {
            await performSearchForTest(
                coordinator: coordinator,
                context: context,
                request: request,
                service: service
            )
        }
        await sleeper.waitForSleepCount(1)
        task.cancel()

        let result = await task.value
        let callCount = await service.callCount()
        Self.assertFailure(result, equals: .cancelled)
        #expect(callCount == 0)
    }

    @Test
    func testCancelledOperationCannotPublishWhenDependencyIgnoresIt()
        async throws
    {
        let sleeper = SearchTestSleeper()
        let service = SearchTestService(
            ignoreCancellationOnFirstCall: true
        )
        let coordinator = LibrarySearchCoordinator(
            sleep: { duration in
                try await sleeper.sleep(for: duration)
            }
        )
        let request = try LibrarySearchRequest(query: "book")
        let context = Self.context(account: "a", library: "one")
        let task = Task.detached {
            await performSearchForTest(
                coordinator: coordinator,
                context: context,
                request: request,
                service: service
            )
        }
        await sleeper.waitForSleepCount(1)
        await sleeper.resumeAll()
        await service.waitForFirstCall()

        task.cancel()
        await service.resumeBlockedCall()

        let result = await task.value
        Self.assertFailure(result, equals: .cancelled)
    }

    @Test
    func testRepositoryFailuresRemainTyped() async throws {
        let sleeper = SearchTestSleeper()
        let remoteError = AudiobookshelfAPIError.unexpectedStatus(503)
        let service = SearchTestService(
            failure: .remote(remoteError)
        )
        let coordinator = LibrarySearchCoordinator(
            sleep: { duration in
                try await sleeper.sleep(for: duration)
            }
        )
        let request = try LibrarySearchRequest(query: "book")
        let context = Self.context(account: "a", library: "one")

        let task = Task.detached {
            await performSearchForTest(
                coordinator: coordinator,
                context: context,
                request: request,
                service: service
            )
        }
        await sleeper.waitForSleepCount(1)
        await sleeper.resumeAll()

        let result = await task.value
        Self.assertFailure(
            result,
            equals: .repository(.remote(remoteError))
        )
    }

    @Test
    func testRepositoryCancellationMapsToCoordinatorCancellation()
        async throws
    {
        let sleeper = SearchTestSleeper()
        let service = SearchTestService(failure: .cancelled)
        let coordinator = LibrarySearchCoordinator(
            sleep: { duration in
                try await sleeper.sleep(for: duration)
            }
        )
        let request = try LibrarySearchRequest(query: "book")
        let context = Self.context(account: "a", library: "one")
        let task = Task.detached {
            await performSearchForTest(
                coordinator: coordinator,
                context: context,
                request: request,
                service: service
            )
        }
        await sleeper.waitForSleepCount(1)
        await sleeper.resumeAll()

        let result = await task.value
        Self.assertFailure(result, equals: .cancelled)
    }

    private static func context(
        account: String,
        library: String
    ) -> LibrarySearchContext {
        LibrarySearchContext(
            accountID: AccountID(rawValue: account),
            libraryID: LibraryID(rawValue: library)
        )
    }

    private static func assertFailure(
        _ result: Result<
            LibraryRepositoryResult<LibrarySearchResults>,
            LibrarySearchCoordinatorError
        >,
        equals expected: LibrarySearchCoordinatorError,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .failure(let error) = result else {
            Issue.record(
                "Expected failure \(expected)", sourceLocation: sourceLocation)
            return
        }
        #expect(error == expected, sourceLocation: sourceLocation)
    }
}

private func performSearchForTest(
    coordinator: LibrarySearchCoordinator,
    context: LibrarySearchContext,
    request: LibrarySearchRequest,
    service: SearchTestService
) async -> Result<
    LibraryRepositoryResult<LibrarySearchResults>,
    LibrarySearchCoordinatorError
> {
    do {
        return .success(
            try await coordinator.search(
                context: context,
                request: request,
                operation: service.search
            )
        )
    } catch let error {
        return .failure(error)
    }
}

private actor SearchTestSleeper {
    private var continuations: [UUID: CheckedContinuation<Void, any Error>] =
        [:]
    private var durations: [Duration] = []
    private var sleepWaiters:
        [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func waitForSleepCount(_ count: Int) async {
        guard durations.count < count else { return }
        await withCheckedContinuation { continuation in
            sleepWaiters.append((count, continuation))
        }
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[id] = continuation
                durations.append(duration)
                let ready = sleepWaiters.filter { $0.count <= durations.count }
                sleepWaiters.removeAll { $0.count <= durations.count }
                for waiter in ready {
                    waiter.continuation.resume()
                }
            }
        } onCancel: {
            Task {
                await self.cancel(id)
            }
        }
    }

    func pendingCount() -> Int {
        continuations.count
    }

    func requestedDurations() -> [Duration] {
        durations
    }

    func resumeAll() {
        let pending = continuations.values
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        continuations.removeValue(forKey: id)?
            .resume(throwing: CancellationError())
    }
}

private actor SearchTestService {
    struct Call: Equatable, Sendable {
        let context: LibrarySearchContext
        let request: LibrarySearchRequest
    }

    private let blockFirstCall: Bool
    private let ignoreCancellationOnFirstCall: Bool
    private let failure: LibraryRepositoryError?
    private var recordedCalls: [Call] = []
    private var cancelledCalls = 0
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var firstCallWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForFirstCall() async {
        guard recordedCalls.isEmpty else { return }
        await withCheckedContinuation { continuation in
            firstCallWaiters.append(continuation)
        }
    }

    init(
        blockFirstCall: Bool = false,
        ignoreCancellationOnFirstCall: Bool = false,
        failure: LibraryRepositoryError? = nil
    ) {
        self.blockFirstCall = blockFirstCall
        self.ignoreCancellationOnFirstCall =
            ignoreCancellationOnFirstCall
        self.failure = failure
    }

    func search(
        context: LibrarySearchContext,
        request: LibrarySearchRequest
    ) async throws(LibraryRepositoryError)
        -> LibraryRepositoryResult<LibrarySearchResults>
    {
        recordedCalls.append(
            Call(
                context: context,
                request: request
            ))
        let waiters = firstCallWaiters
        firstCallWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if blockFirstCall, recordedCalls.count == 1 {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelledCalls += 1
                throw .cancelled
            }
        }
        if ignoreCancellationOnFirstCall,
            recordedCalls.count == 1
        {
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        }
        if let failure {
            throw failure
        }
        return LibraryRepositoryResult(
            value: LibrarySearchResults(books: []),
            source: .remote,
            refreshedAt: Date(timeIntervalSince1970: 1),
            correlationID: nil
        )
    }

    func callCount() -> Int {
        recordedCalls.count
    }

    func calls() -> [Call] {
        recordedCalls
    }

    func cancelledCallCount() -> Int {
        cancelledCalls
    }

    func resumeBlockedCall() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}
