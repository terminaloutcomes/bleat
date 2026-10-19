import Foundation
import Testing

@testable import BleatCore

@Suite(.serialized)
final class LibrarySearchCoordinatorTests {
    @Test
    func testDefaultSleeperRunsZeroDurationSearch() async throws {
        let service = SearchTestService()
        let coordinator = LibrarySearchCoordinator(debounceDuration: .zero)
        let context = Self.context(account: "a", library: "one")
        let request = try LibrarySearchRequest(query: "book")
        let completed = BoundedTestCounter()
        let task = Task {
            await performSearchForTest(
                coordinator: coordinator, context: context, request: request,
                service: service, completion: completed)
        }
        try await withTestCleanup {
            task.cancel()
            await service.resumeBlockedCall()
        } operation: {
            let completionWait = await completed.wait(untilAtLeast: 1)
            #expect(
                completionWait.reached,
                "zero-duration search returning: elapsed \(completionWait.elapsed), limit \(completionWait.timeout)"
            )
            guard completionWait.reached else { return }
            let result = try await task.value.get()
            #expect(result.source == .remote)
        }
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

        let completed = BoundedTestCounter()
        let task = Task {
            await performSearchForTest(
                coordinator: coordinator, context: context, request: request,
                service: service, completion: completed)
        }
        try await withTestCleanup {
            task.cancel()
            await sleeper.retireAll()
            await service.resumeBlockedCall()
        } operation: {
            let sleepWait = await sleeper.waitForSleepCount(1)
            #expect(
                sleepWait.reached,
                "first debounce registration timed out after \(sleepWait.elapsed), limit \(sleepWait.timeout)"
            )
            guard sleepWait.reached else { return }
            let initialCallCount = await service.callCount()
            let requestedDurations = await sleeper.requestedDurations()
            #expect(initialCallCount == 0)
            #expect(requestedDurations == [.milliseconds(300)])

            await sleeper.resumeAll()
            let completionWait = await completed.wait(untilAtLeast: 1)
            #expect(
                completionWait.reached,
                "search caller returning: elapsed \(completionWait.elapsed), limit \(completionWait.timeout)"
            )
            guard completionWait.reached else { return }
            let result = try await task.value.get()
            let finalCallCount = await service.callCount()
            #expect(result.source == .remote)
            #expect(finalCallCount == 1)
        }
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

        let firstCompleted = BoundedTestCounter()
        let first = Task.detached {
            await performSearchForTest(
                coordinator: coordinator,
                context: context,
                request: firstRequest,
                service: service,
                completion: firstCompleted
            )
        }
        var tasks = [first]
        try await withTestCleanup {
            for task in tasks { task.cancel() }
            await sleeper.retireAll()
            await service.resumeBlockedCall()
        } operation: {
            let firstSleepWait = await sleeper.waitForSleepCount(1)
            #expect(
                firstSleepWait.reached,
                "first debounce registration timed out after \(firstSleepWait.elapsed), limit \(firstSleepWait.timeout)"
            )
            guard firstSleepWait.reached else { return }
            let secondCompleted = BoundedTestCounter()
            let second = Task.detached {
                await performSearchForTest(
                    coordinator: coordinator,
                    context: context,
                    request: secondRequest,
                    service: service,
                    completion: secondCompleted
                )
            }
            tasks.append(second)
            let secondSleepWait = await sleeper.waitForSleepCount(2)
            #expect(
                secondSleepWait.reached,
                "replacement debounce registration timed out after \(secondSleepWait.elapsed), limit \(secondSleepWait.timeout)"
            )
            guard secondSleepWait.reached else { return }
            let firstCompletionWait = await firstCompleted.wait(untilAtLeast: 1)
            #expect(
                firstCompletionWait.reached,
                "first search returning: elapsed \(firstCompletionWait.elapsed), limit \(firstCompletionWait.timeout)"
            )
            guard firstCompletionWait.reached else { return }
            let firstResult = await first.value
            #expect(await sleeper.pendingCount() == 1)
            await sleeper.resumeAll()

            let secondCompletionWait = await secondCompleted.wait(
                untilAtLeast: 1)
            #expect(
                secondCompletionWait.reached,
                "second search returning: elapsed \(secondCompletionWait.elapsed), limit \(secondCompletionWait.timeout)"
            )
            guard secondCompletionWait.reached else { return }
            let secondResult = await second.value
            Self.assertFailure(firstResult, equals: .superseded)
            guard case .success = secondResult else {
                Issue.record("Expected second search to succeed")
                return
            }
            let calls = await service.calls()
            #expect(calls.map(\.request.query) == ["second"])
        }
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

        let firstCompleted = BoundedTestCounter()
        let first = Task.detached {
            await performSearchForTest(
                coordinator: coordinator,
                context: firstContext,
                request: request,
                service: service,
                completion: firstCompleted
            )
        }
        var tasks = [first]
        try await withTestCleanup {
            for task in tasks { task.cancel() }
            await sleeper.retireAll()
            await service.resumeBlockedCall()
        } operation: {
            let firstSleepWait = await sleeper.waitForSleepCount(1)
            #expect(
                firstSleepWait.reached,
                "first debounce registration timed out after \(firstSleepWait.elapsed), limit \(firstSleepWait.timeout)"
            )
            guard firstSleepWait.reached else { return }
            await sleeper.resumeAll()
            let firstCallWait = await service.waitForFirstCall()
            #expect(
                firstCallWait.reached,
                "first repository call timed out after \(firstCallWait.elapsed), limit \(firstCallWait.timeout)"
            )
            guard firstCallWait.reached else { return }
            let blockedWait = await service.waitForBlockedCall()
            #expect(
                blockedWait.reached,
                "held repository registration: elapsed \(blockedWait.elapsed), limit \(blockedWait.timeout)"
            )
            guard blockedWait.reached else { return }

            let secondCompleted = BoundedTestCounter()
            let second = Task.detached {
                await performSearchForTest(
                    coordinator: coordinator,
                    context: secondContext,
                    request: request,
                    service: service,
                    completion: secondCompleted
                )
            }
            tasks.append(second)
            let secondSleepWait = await sleeper.waitForSleepCount(2)
            #expect(
                secondSleepWait.reached,
                "replacement debounce registration timed out after \(secondSleepWait.elapsed), limit \(secondSleepWait.timeout)"
            )
            guard secondSleepWait.reached else { return }
            await sleeper.resumeAll()

            let firstCompletionWait = await firstCompleted.wait(untilAtLeast: 1)
            #expect(
                firstCompletionWait.reached,
                "first search returning: elapsed \(firstCompletionWait.elapsed), limit \(firstCompletionWait.timeout)"
            )
            guard firstCompletionWait.reached else { return }
            let firstResult = await first.value
            let secondCompletionWait = await secondCompleted.wait(
                untilAtLeast: 1)
            #expect(
                secondCompletionWait.reached,
                "second search returning: elapsed \(secondCompletionWait.elapsed), limit \(secondCompletionWait.timeout)"
            )
            guard secondCompletionWait.reached else { return }
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

        let completed = BoundedTestCounter()
        let task = Task.detached {
            await performSearchForTest(
                coordinator: coordinator,
                context: context,
                request: request,
                service: service,
                completion: completed
            )
        }
        try await withTestCleanup {
            task.cancel()
            await sleeper.retireAll()
            await service.resumeBlockedCall()
        } operation: {
            let sleepWait = await sleeper.waitForSleepCount(1)
            #expect(
                sleepWait.reached,
                "debounce registration timed out after \(sleepWait.elapsed), limit \(sleepWait.timeout)"
            )
            guard sleepWait.reached else { return }
            task.cancel()

            let completionWait = await completed.wait(untilAtLeast: 1)
            #expect(
                completionWait.reached,
                "search caller returning: elapsed \(completionWait.elapsed), limit \(completionWait.timeout)"
            )
            guard completionWait.reached else { return }
            let result = await task.value
            let callCount = await service.callCount()
            Self.assertFailure(result, equals: .cancelled)
            #expect(callCount == 0)
        }
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
        let completed = BoundedTestCounter()
        let task = Task.detached {
            await performSearchForTest(
                coordinator: coordinator,
                context: context,
                request: request,
                service: service,
                completion: completed
            )
        }
        try await withTestCleanup {
            task.cancel()
            await sleeper.retireAll()
            await service.resumeBlockedCall()
        } operation: {
            let firstSleepWait = await sleeper.waitForSleepCount(1)
            #expect(
                firstSleepWait.reached,
                "first debounce registration timed out after \(firstSleepWait.elapsed), limit \(firstSleepWait.timeout)"
            )
            guard firstSleepWait.reached else { return }
            await sleeper.resumeAll()
            let firstCallWait = await service.waitForFirstCall()
            #expect(
                firstCallWait.reached,
                "first repository call timed out after \(firstCallWait.elapsed), limit \(firstCallWait.timeout)"
            )
            guard firstCallWait.reached else { return }
            let blockedWait = await service.waitForBlockedCall()
            #expect(
                blockedWait.reached,
                "held repository registration: elapsed \(blockedWait.elapsed), limit \(blockedWait.timeout)"
            )
            guard blockedWait.reached else { return }

            task.cancel()
            await service.resumeBlockedCall()

            let completionWait = await completed.wait(untilAtLeast: 1)
            #expect(
                completionWait.reached,
                "search caller returning: elapsed \(completionWait.elapsed), limit \(completionWait.timeout)"
            )
            guard completionWait.reached else { return }
            let result = await task.value
            Self.assertFailure(result, equals: .cancelled)
        }
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
        try await withTestCleanup {
            task.cancel()
            await service.resumeBlockedCall()
        } operation: {
            let callWait = await service.waitForFirstCall()
            #expect(
                callWait.reached,
                "repository call timed out after \(callWait.elapsed), limit \(callWait.timeout)"
            )
            guard callWait.reached else {
                return
            }
            let blockedWait = await service.waitForBlockedCall()
            #expect(
                blockedWait.reached,
                "blocked-call registration timed out after \(blockedWait.elapsed), limit \(blockedWait.timeout)"
            )
            guard blockedWait.reached else {
                return
            }

            let completionWait = await completion.wait(untilAtLeast: 1)
            #expect(
                completionWait.reached,
                "released repository call timed out after \(completionWait.elapsed), limit \(completionWait.timeout)"
            )
            guard completionWait.reached else { return }
            let result = await task.value

            guard case .success(let value) = result else {
                Issue.record(
                    "Expected the cancellation-ignoring call to succeed")
                return
            }
            #expect(value.source == .remote)
            await service.resumeBlockedCall()
            #expect(await service.callCount() == 1)
        }
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
        try await withTestCleanup {
            task.cancel()
            await service.resumeBlockedCall()
        } operation: {
            let callWait = await service.waitForFirstCall()
            #expect(
                callWait.reached,
                "repository call timed out after \(callWait.elapsed), limit \(callWait.timeout)"
            )
            guard callWait.reached else {
                return
            }
            let blockedWait = await service.waitForBlockedCall()
            #expect(
                blockedWait.reached,
                "blocked-call registration timed out after \(blockedWait.elapsed), limit \(blockedWait.timeout)"
            )
            guard blockedWait.reached else {
                return
            }

            await service.resumeBlockedCall()
            await service.resumeBlockedCall()
            let completionWait = await completion.wait(untilAtLeast: 1)
            #expect(
                completionWait.reached,
                "released repository call timed out after \(completionWait.elapsed), limit \(completionWait.timeout)"
            )
            guard completionWait.reached else { return }
            let result = try await task.value
            #expect(result.source == .remote)
            #expect(await service.callCount() == 1)
        }
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

        let completed = BoundedTestCounter()
        let task = Task.detached {
            await performSearchForTest(
                coordinator: coordinator,
                context: context,
                request: request,
                service: service,
                completion: completed
            )
        }
        try await withTestCleanup {
            task.cancel()
            await sleeper.retireAll()
            await service.resumeBlockedCall()
        } operation: {
            let sleepWait = await sleeper.waitForSleepCount(1)
            #expect(
                sleepWait.reached,
                "debounce registration timed out after \(sleepWait.elapsed), limit \(sleepWait.timeout)"
            )
            guard sleepWait.reached else { return }
            await sleeper.resumeAll()

            let completionWait = await completed.wait(untilAtLeast: 1)
            #expect(
                completionWait.reached,
                "search caller returning: elapsed \(completionWait.elapsed), limit \(completionWait.timeout)"
            )
            guard completionWait.reached else { return }
            let result = await task.value
            Self.assertFailure(
                result,
                equals: .repository(.remote(remoteError))
            )
        }
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
        let completed = BoundedTestCounter()
        let task = Task.detached {
            await performSearchForTest(
                coordinator: coordinator,
                context: context,
                request: request,
                service: service,
                completion: completed
            )
        }
        try await withTestCleanup {
            task.cancel()
            await sleeper.retireAll()
            await service.resumeBlockedCall()
        } operation: {
            let sleepWait = await sleeper.waitForSleepCount(1)
            #expect(
                sleepWait.reached,
                "debounce registration timed out after \(sleepWait.elapsed), limit \(sleepWait.timeout)"
            )
            guard sleepWait.reached else { return }
            await sleeper.resumeAll()

            let completionWait = await completed.wait(untilAtLeast: 1)
            #expect(
                completionWait.reached,
                "search caller returning: elapsed \(completionWait.elapsed), limit \(completionWait.timeout)"
            )
            guard completionWait.reached else { return }
            let result = await task.value
            Self.assertFailure(result, equals: .cancelled)
        }
    }

    @Test(arguments: SearchFixtureScenario.allCases)
    fileprivate func testSearchSleeperCancellationAndRetirement(
        scenario: SearchFixtureScenario
    ) async throws {
        let sleeper = SearchTestSleeper()
        let start = AuthTelemetryTestSignal()
        let completed = BoundedTestCounter()
        let task = Task {
            guard
                await requireAuthTelemetrySignal(
                    start, stage: "private sleeper entry allowed")
            else { return Result<Void, any Error>.failure(CancellationError()) }
            let result: Result<Void, any Error>
            do {
                try await sleeper.sleep(for: .milliseconds(300))
                result = .success(())
            } catch { result = .failure(error) }
            await completed.increment()
            return result
        }
        try await withTestCleanup {
            task.cancel()
            await start.signal()
            await sleeper.retireAll()
        } operation: {
            if scenario.beforeEntry {
                if scenario.cancelsCaller {
                    task.cancel()
                    task.cancel()
                } else {
                    await sleeper.retireAll()
                    await sleeper.retireAll()
                    await sleeper.resumeAll()
                }
            }
            await start.signal()
            if !scenario.beforeEntry {
                let registration = await sleeper.waitForSleepCount(1)
                #expect(
                    registration.reached,
                    "private sleep registration: elapsed \(registration.elapsed), limit \(registration.timeout)"
                )
                guard registration.reached else { return }
                #expect(await sleeper.pendingCount() == 1)
                if scenario.cancelsCaller {
                    task.cancel()
                    task.cancel()
                } else {
                    await sleeper.retireAll()
                    await sleeper.retireAll()
                }
            }
            let completion = await completed.wait(untilAtLeast: 1)
            #expect(
                completion.reached,
                "private sleep returning: elapsed \(completion.elapsed), limit \(completion.timeout)"
            )
            guard completion.reached else { return }
            let result = await task.value
            switch result {
            case .failure(let error): #expect(error is CancellationError)
            case .success: Issue.record("Expected cancelled or retired sleep")
            }
            #expect(await sleeper.pendingCount() == 0)
            await sleeper.retireAll()
            await sleeper.retireAll()
            await sleeper.resumeAll()
            #expect(await sleeper.pendingCount() == 0)
        }
    }

    @Test(arguments: SearchFixtureScenario.allCases)
    fileprivate func testCancellableRepositoryHoldCancellationAndRelease(
        scenario: SearchFixtureScenario
    ) async throws {
        let service = SearchTestService(blockFirstCall: true)
        let start = AuthTelemetryTestSignal()
        let completed = BoundedTestCounter()
        let context = Self.context(account: "a", library: "one")
        let request = try LibrarySearchRequest(query: "book")
        let task = Task {
            guard
                await requireAuthTelemetrySignal(
                    start, stage: "private repository entry allowed")
            else {
                return Result<
                    LibraryRepositoryResult<LibrarySearchResults>,
                    LibraryRepositoryError
                >.failure(.cancelled)
            }
            let result:
                Result<
                    LibraryRepositoryResult<LibrarySearchResults>,
                    LibraryRepositoryError
                >
            do throws(LibraryRepositoryError) {
                result = .success(
                    try await service.search(context: context, request: request)
                )
            } catch { result = .failure(error) }
            await completed.increment()
            return result
        }
        try await withTestCleanup {
            task.cancel()
            await start.signal()
            await service.resumeBlockedCall()
        } operation: {
            if scenario.beforeEntry {
                if scenario.cancelsCaller {
                    task.cancel()
                    task.cancel()
                } else {
                    await service.resumeBlockedCall()
                    await service.resumeBlockedCall()
                }
            }
            await start.signal()
            if !scenario.beforeEntry {
                let registration = await service.waitForBlockedCall()
                #expect(
                    registration.reached,
                    "private held-call registration: elapsed \(registration.elapsed), limit \(registration.timeout)"
                )
                guard registration.reached else { return }
                #expect(await service.pendingCallCount() == 1)
                if scenario.cancelsCaller {
                    task.cancel()
                    task.cancel()
                } else {
                    await service.resumeBlockedCall()
                    await service.resumeBlockedCall()
                }
            }
            let completion = await completed.wait(untilAtLeast: 1)
            #expect(
                completion.reached,
                "private held call returning: elapsed \(completion.elapsed), limit \(completion.timeout)"
            )
            guard completion.reached else { return }
            let result = await task.value
            switch result {
            case .failure(let error):
                #expect(scenario.cancelsCaller)
                #expect(error == .cancelled)
            case .success(let value):
                #expect(!scenario.cancelsCaller)
                #expect(value.source == .remote)
            }
            #expect(await service.callCount() == 1)
            #expect(
                await service.cancelledCallCount()
                    == (scenario.cancelsCaller ? 1 : 0))
            #expect(await service.pendingCallCount() == 0)
            await service.resumeBlockedCall()
            await service.resumeBlockedCall()
            #expect(await service.pendingCallCount() == 0)
        }
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

private enum SearchFixtureScenario: CaseIterable, Sendable {
    case cancelBeforeEntry
    case cancelAfterRegistration
    case cleanupBeforeEntry
    case cleanupAfterRegistration

    var beforeEntry: Bool {
        switch self {
        case .cancelBeforeEntry, .cleanupBeforeEntry: true
        case .cancelAfterRegistration, .cleanupAfterRegistration: false
        }
    }

    var cancelsCaller: Bool {
        switch self {
        case .cancelBeforeEntry, .cancelAfterRegistration: true
        case .cleanupBeforeEntry, .cleanupAfterRegistration: false
        }
    }
}

private func performSearchForTest(
    coordinator: LibrarySearchCoordinator,
    context: LibrarySearchContext,
    request: LibrarySearchRequest,
    service: SearchTestService,
    completion: BoundedTestCounter
) async -> Result<
    LibraryRepositoryResult<LibrarySearchResults>,
    LibrarySearchCoordinatorError
> {
    let result:
        Result<
            LibraryRepositoryResult<LibrarySearchResults>,
            LibrarySearchCoordinatorError
        >
    do {
        result = .success(
            try await coordinator.search(
                context: context,
                request: request,
                operation: service.search
            )
        )
    } catch let error {
        result = .failure(error)
    }
    await completion.increment()
    return result
}

private actor SearchTestSleeper {
    private var continuations: [UUID: CheckedContinuation<Void, any Error>] =
        [:]
    private var durations: [Duration] = []
    private var retired = false
    private let sleepRegistrations = BoundedTestCounter()

    func waitForSleepCount(_ count: Int) async -> BoundedTestWaitResult {
        await sleepRegistrations.wait(untilAtLeast: count)
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard !retired, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
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
        let pending = Array(continuations.values)
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func retireAll() {
        retired = true
        let pending = Array(continuations.values)
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(throwing: CancellationError())
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
    private enum CancellableCallState {
        case notRegistered
        case waiting(CheckedContinuation<Void, any Error>)
        case released
        case cancelled
    }

    private var cancellableCallState = CancellableCallState.notRegistered
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
                try await waitForCancellableCallRelease()
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

    private func waitForCancellableCallRelease() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                switch cancellableCallState {
                case .notRegistered:
                    cancellableCallState = .waiting(continuation)
                    Task { await blockedCallRegistrations.increment() }
                case .waiting, .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .released:
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { await self.cancelCancellableCall() }
        }
    }

    private func cancelCancellableCall() {
        switch cancellableCallState {
        case .notRegistered:
            cancellableCallState = .cancelled
        case .waiting(let continuation):
            cancellableCallState = .cancelled
            continuation.resume(throwing: CancellationError())
        case .released, .cancelled:
            break
        }
    }

    func pendingCallCount() -> Int {
        var count = 0
        if case .waiting = blockedCallState { count += 1 }
        if case .waiting = cancellableCallState { count += 1 }
        return count
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
        switch cancellableCallState {
        case .notRegistered:
            cancellableCallState = .released
        case .waiting(let continuation):
            cancellableCallState = .released
            continuation.resume()
        case .released, .cancelled:
            break
        }
    }
}
