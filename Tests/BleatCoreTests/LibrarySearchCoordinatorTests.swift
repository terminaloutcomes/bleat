import Foundation
import XCTest

@testable import BleatCore

final class LibrarySearchCoordinatorTests: XCTestCase {
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

        XCTAssertEqual(result.source, .remote)
    }

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
        try await waitUntil {
            await sleeper.pendingCount() == 1
        }
        let initialCallCount = await service.callCount()
        let requestedDurations = await sleeper.requestedDurations()
        XCTAssertEqual(initialCallCount, 0)
        XCTAssertEqual(requestedDurations, [.milliseconds(300)])

        await sleeper.resumeAll()
        let result = try await task.value
        let finalCallCount = await service.callCount()
        XCTAssertEqual(result.source, .remote)
        XCTAssertEqual(finalCallCount, 1)
    }

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
        try await waitUntil {
            await sleeper.pendingCount() == 1
        }
        let second = Task.detached {
            await performSearchForTest(
                coordinator: coordinator,
                context: context,
                request: secondRequest,
                service: service
            )
        }
        try await waitUntil {
            let durationCount =
                await sleeper.requestedDurations().count
            let pendingCount = await sleeper.pendingCount()
            return durationCount == 2 && pendingCount == 1
        }
        await sleeper.resumeAll()

        let firstResult = await first.value
        let secondResult = await second.value
        Self.assertFailure(firstResult, equals: .superseded)
        guard case .success = secondResult else {
            return XCTFail("Expected second search to succeed")
        }
        let calls = await service.calls()
        XCTAssertEqual(calls.map(\.request.query), ["second"])
    }

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
        try await waitUntil {
            await sleeper.pendingCount() == 1
        }
        await sleeper.resumeAll()
        try await waitUntil {
            await service.callCount() == 1
        }

        let second = Task.detached {
            await performSearchForTest(
                coordinator: coordinator,
                context: secondContext,
                request: request,
                service: service
            )
        }
        try await waitUntil {
            await sleeper.pendingCount() == 1
        }
        await sleeper.resumeAll()

        let firstResult = await first.value
        let secondResult = await second.value
        Self.assertFailure(firstResult, equals: .superseded)
        guard case .success = secondResult else {
            return XCTFail("Expected replacement search to succeed")
        }
        let calls = await service.calls()
        let cancelledCallCount =
            await service.cancelledCallCount()
        XCTAssertEqual(
            calls.map(\.context),
            [firstContext, secondContext]
        )
        XCTAssertEqual(cancelledCallCount, 1)
    }

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
        try await waitUntil {
            await sleeper.pendingCount() == 1
        }
        task.cancel()

        let result = await task.value
        let callCount = await service.callCount()
        Self.assertFailure(result, equals: .cancelled)
        XCTAssertEqual(callCount, 0)
    }

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
        try await waitUntil {
            await sleeper.pendingCount() == 1
        }
        await sleeper.resumeAll()
        try await waitUntil {
            await service.callCount() == 1
        }

        task.cancel()
        await service.resumeBlockedCall()

        let result = await task.value
        Self.assertFailure(result, equals: .cancelled)
    }

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
        try await waitUntil {
            await sleeper.pendingCount() == 1
        }
        await sleeper.resumeAll()

        let result = await task.value
        Self.assertFailure(
            result,
            equals: .repository(.remote(remoteError))
        )
    }

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
        try await waitUntil {
            await sleeper.pendingCount() == 1
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
            LibraryRepositoryResult<[LibraryBookSummary]>,
            LibrarySearchCoordinatorError
        >,
        equals expected: LibrarySearchCoordinatorError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .failure(error) = result else {
            return XCTFail(
                "Expected failure \(expected)",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(error, expected, file: file, line: line)
    }

    private func waitUntil(
        _ condition: () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0 ..< 1_000 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail(
            "Timed out waiting for asynchronous condition",
            file: file,
            line: line
        )
        throw SearchTestError.timeout
    }
}

private func performSearchForTest(
    coordinator: LibrarySearchCoordinator,
    context: LibrarySearchContext,
    request: LibrarySearchRequest,
    service: SearchTestService
) async -> Result<
    LibraryRepositoryResult<[LibraryBookSummary]>,
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
    private var continuations: [
        UUID: CheckedContinuation<Void, any Error>
    ] = [:]
    private var durations: [Duration] = []

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        durations.append(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[id] = continuation
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
        pending.forEach {
            $0.resume()
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
        -> LibraryRepositoryResult<[LibraryBookSummary]>
    {
        recordedCalls.append(Call(
            context: context,
            request: request
        ))
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
            value: [],
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

private enum SearchTestError: Error {
    case timeout
}
