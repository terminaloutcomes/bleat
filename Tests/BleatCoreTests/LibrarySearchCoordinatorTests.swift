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
        let sleepWait = await sleeper.waitForSleepCount(1)
        #expect(
            sleepWait.reached,
            "first debounce registration timed out after \(sleepWait.elapsed), limit \(sleepWait.timeout)"
        )
        guard sleepWait.reached else {
            task.cancel()
            _ = await task.result
            return
        }
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
        let firstSleepWait = await sleeper.waitForSleepCount(1)
        #expect(
            firstSleepWait.reached,
            "first debounce registration timed out after \(firstSleepWait.elapsed), limit \(firstSleepWait.timeout)"
        )
        guard firstSleepWait.reached else {
            first.cancel()
            _ = await first.result
            return
        }
        let second = Task.detached {
            await performSearchForTest(
                coordinator: coordinator,
                context: context,
                request: secondRequest,
                service: service
            )
        }
        let secondSleepWait = await sleeper.waitForSleepCount(2)
        #expect(
            secondSleepWait.reached,
            "replacement debounce registration timed out after \(secondSleepWait.elapsed), limit \(secondSleepWait.timeout)"
        )
        guard secondSleepWait.reached else {
            first.cancel()
            second.cancel()
            _ = await first.result
            _ = await second.result
            return
        }
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
        let firstSleepWait = await sleeper.waitForSleepCount(1)
        #expect(
            firstSleepWait.reached,
            "first debounce registration timed out after \(firstSleepWait.elapsed), limit \(firstSleepWait.timeout)"
        )
        guard firstSleepWait.reached else {
            first.cancel()
            _ = await first.result
            return
        }
        await sleeper.resumeAll()
        let firstCallWait = await service.waitForFirstCall()
        #expect(
            firstCallWait.reached,
            "first repository call timed out after \(firstCallWait.elapsed), limit \(firstCallWait.timeout)"
        )
        guard firstCallWait.reached else {
            first.cancel()
            _ = await first.result
            return
        }

        let second = Task.detached {
            await performSearchForTest(
                coordinator: coordinator,
                context: secondContext,
                request: request,
                service: service
            )
        }
        let secondSleepWait = await sleeper.waitForSleepCount(2)
        #expect(
            secondSleepWait.reached,
            "replacement debounce registration timed out after \(secondSleepWait.elapsed), limit \(secondSleepWait.timeout)"
        )
        guard secondSleepWait.reached else {
            first.cancel()
            second.cancel()
            await service.resumeBlockedCall()
            _ = await first.result
            _ = await second.result
            return
        }
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
        let sleepWait = await sleeper.waitForSleepCount(1)
        #expect(
            sleepWait.reached,
            "debounce registration timed out after \(sleepWait.elapsed), limit \(sleepWait.timeout)"
        )
        guard sleepWait.reached else {
            task.cancel()
            _ = await task.result
            return
        }
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
        let firstSleepWait = await sleeper.waitForSleepCount(1)
        #expect(
            firstSleepWait.reached,
            "first debounce registration timed out after \(firstSleepWait.elapsed), limit \(firstSleepWait.timeout)"
        )
        guard firstSleepWait.reached else {
            task.cancel()
            _ = await task.result
            return
        }
        await sleeper.resumeAll()
        let firstCallWait = await service.waitForFirstCall()
        #expect(
            firstCallWait.reached,
            "first repository call timed out after \(firstCallWait.elapsed), limit \(firstCallWait.timeout)"
        )
        guard firstCallWait.reached else {
            task.cancel()
            await service.resumeBlockedCall()
            _ = await task.result
            return
        }

        task.cancel()
        await service.resumeBlockedCall()

        let result = await task.value
        Self.assertFailure(result, equals: .cancelled)
    }

    @Test
    func testEarlyAndRepeatedReleaseDoesNotStrandCancellationIgnoringCall()
        async throws
    {
        let service = SearchTestService(ignoreCancellationOnFirstCall: true)
        let completion = BoundedTestCounter()
        let context = Self.context(account: "a", library: "one")
        let request = try LibrarySearchRequest(query: "book")
        await service.resumeBlockedCall()
        await service.resumeBlockedCall()

        let task = Task {
            let result:
                Result<
                    LibraryRepositoryResult<LibrarySearchResults>,
                    LibraryRepositoryError
                >
            do throws(LibraryRepositoryError) {
                result = .success(
                    try await service.search(
                        context: context,
                        request: request
                    ))
            } catch let error {
                result = .failure(error)
            }
            await completion.increment()
            return result
        }
        let callWait = await service.waitForFirstCall()
        #expect(
            callWait.reached,
            "repository call timed out after \(callWait.elapsed), limit \(callWait.timeout)"
        )
        guard callWait.reached else {
            task.cancel()
            await service.resumeBlockedCall()
            _ = await task.result
            return
        }
        let blockedWait = await service.waitForBlockedCall()
        #expect(
            blockedWait.reached,
            "blocked-call registration timed out after \(blockedWait.elapsed), limit \(blockedWait.timeout)"
        )
        guard blockedWait.reached else {
            task.cancel()
            await service.resumeBlockedCall()
            _ = await task.result
            return
        }

        let completionWait = await completion.wait(untilAtLeast: 1)
        #expect(
            completionWait.reached,
            "released repository call timed out after \(completionWait.elapsed), limit \(completionWait.timeout)"
        )
        if !completionWait.reached {
            task.cancel()
            await service.resumeBlockedCall()
        }
        let result = await task.value

        guard case .success(let value) = result else {
            Issue.record("Expected the cancellation-ignoring call to succeed")
            return
        }
        #expect(value.source == .remote)
        await service.resumeBlockedCall()
        #expect(await service.callCount() == 1)
    }

    @Test
    func testRepeatedReleaseAfterCallRegistrationCompletesBlockedCall()
        async throws
    {
        let service = SearchTestService(ignoreCancellationOnFirstCall: true)
        let completion = BoundedTestCounter()
        let context = Self.context(account: "a", library: "one")
        let request = try LibrarySearchRequest(query: "book")
        let task = Task {
            let result = try await service.search(
                context: context,
                request: request
            )
            await completion.increment()
            return result
        }
        let callWait = await service.waitForFirstCall()
        #expect(
            callWait.reached,
            "repository call timed out after \(callWait.elapsed), limit \(callWait.timeout)"
        )
        guard callWait.reached else {
            task.cancel()
            await service.resumeBlockedCall()
            _ = await task.result
            return
        }
        let blockedWait = await service.waitForBlockedCall()
        #expect(
            blockedWait.reached,
            "blocked-call registration timed out after \(blockedWait.elapsed), limit \(blockedWait.timeout)"
        )
        guard blockedWait.reached else {
            task.cancel()
            await service.resumeBlockedCall()
            _ = await task.result
            return
        }

        await service.resumeBlockedCall()
        await service.resumeBlockedCall()
        let completionWait = await completion.wait(untilAtLeast: 1)
        #expect(
            completionWait.reached,
            "released repository call timed out after \(completionWait.elapsed), limit \(completionWait.timeout)"
        )
        if !completionWait.reached {
            task.cancel()
            await service.resumeBlockedCall()
        }
        _ = await task.result
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
        let sleepWait = await sleeper.waitForSleepCount(1)
        #expect(
            sleepWait.reached,
            "debounce registration timed out after \(sleepWait.elapsed), limit \(sleepWait.timeout)"
        )
        guard sleepWait.reached else {
            task.cancel()
            _ = await task.result
            return
        }
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
        let sleepWait = await sleeper.waitForSleepCount(1)
        #expect(
            sleepWait.reached,
            "debounce registration timed out after \(sleepWait.elapsed), limit \(sleepWait.timeout)"
        )
        guard sleepWait.reached else {
            task.cancel()
            _ = await task.result
            return
        }
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
    private let sleepRegistrations = BoundedTestCounter()

    func waitForSleepCount(_ count: Int) async -> BoundedTestWaitResult {
        await sleepRegistrations.wait(untilAtLeast: count)
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[id] = continuation
                durations.append(duration)
                Task {
                    await sleepRegistrations.increment()
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
    private enum BlockedCallState {
        case notRegistered
        case waiting(CheckedContinuation<Void, Never>)
        case released
    }

    private var blockedCallState = BlockedCallState.notRegistered
    private let callRegistrations = BoundedTestCounter()
    private let blockedCallRegistrations = BoundedTestCounter()

    func waitForFirstCall() async -> BoundedTestWaitResult {
        await callRegistrations.wait(untilAtLeast: 1)
    }

    func waitForBlockedCall() async -> BoundedTestWaitResult {
        await blockedCallRegistrations.wait(untilAtLeast: 1)
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
        let isFirstCall = recordedCalls.count == 1
        await callRegistrations.increment()
        if blockFirstCall, isFirstCall {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelledCalls += 1
                throw .cancelled
            }
        }
        if ignoreCancellationOnFirstCall, isFirstCall {
            await withCheckedContinuation { continuation in
                switch blockedCallState {
                case .notRegistered:
                    blockedCallState = .waiting(continuation)
                    Task {
                        await blockedCallRegistrations.increment()
                    }
                case .waiting:
                    continuation.resume()
                    Task {
                        await blockedCallRegistrations.increment()
                    }
                case .released:
                    Task {
                        await blockedCallRegistrations.increment()
                    }
                    continuation.resume()
                }
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
        switch blockedCallState {
        case .notRegistered:
            blockedCallState = .released
        case .waiting(let continuation):
            blockedCallState = .released
            continuation.resume()
        case .released:
            break
        }
    }
}
