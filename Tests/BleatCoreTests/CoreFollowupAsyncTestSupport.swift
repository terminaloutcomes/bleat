import Foundation

struct BoundedTestWaitResult: Sendable {
    let reached: Bool
    let elapsed: Duration
    let timeout: Duration
}

actor BoundedTestCounter {
    private struct Waiter {
        let target: Int
        let startedAt: ContinuousClock.Instant
        let timeout: Duration
        let continuation: CheckedContinuation<BoundedTestWaitResult, Never>
        var timeoutTask: Task<Void, Never>?
    }

    private var value = 0
    private var waiters: [UUID: Waiter] = [:]

    func increment() {
        value += 1
        let readyIDs = waiters.compactMap { id, waiter in
            value >= waiter.target ? id : nil
        }
        for id in readyIDs {
            guard let waiter = waiters.removeValue(forKey: id) else {
                continue
            }
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(
                returning: BoundedTestWaitResult(
                    reached: true,
                    elapsed: waiter.startedAt.duration(to: .now),
                    timeout: waiter.timeout
                ))
        }
    }

    func wait(
        untilAtLeast target: Int,
        timeout: Duration = .seconds(5)
    ) async -> BoundedTestWaitResult {
        let startedAt = ContinuousClock.now
        if value >= target {
            return BoundedTestWaitResult(
                reached: true,
                elapsed: .zero,
                timeout: timeout
            )
        }

        return await withCheckedContinuation { continuation in
            let id = UUID()
            waiters[id] = Waiter(
                target: target,
                startedAt: startedAt,
                timeout: timeout,
                continuation: continuation
            )
            waiters[id]?.timeoutTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self.expireWaiter(id)
            }
        }
    }

    private func expireWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(
            returning: BoundedTestWaitResult(
                reached: false,
                elapsed: waiter.startedAt.duration(to: .now),
                timeout: waiter.timeout
            ))
    }
}

enum BoundedAsyncStreamRead<Element: Sendable>: Sendable {
    case element(Element)
    case finished
    case timedOut(timeout: Duration, elapsed: Duration)
}

private final class AsyncStreamIteration<Element: Sendable>: @unchecked Sendable
{
    private var iterator: AsyncStream<Element>.Iterator

    init(_ stream: AsyncStream<Element>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> Element? {
        await iterator.next()
    }
}

actor BoundedAsyncStreamReader<Element: Sendable> {
    private let iteration: AsyncStreamIteration<Element>

    init(_ stream: AsyncStream<Element>) {
        iteration = AsyncStreamIteration(stream)
    }

    func next(
        timeout: Duration = .seconds(5)
    ) async -> BoundedAsyncStreamRead<Element> {
        let startedAt = ContinuousClock.now
        let outcome = await withTaskGroup(
            of: BoundedAsyncStreamRead<Element>.self
        ) { group in
            group.addTask {
                guard let element = await self.iteration.next() else {
                    return .finished
                }
                return .element(element)
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return .finished
                }
                return .timedOut(timeout: timeout, elapsed: .zero)
            }
            let result = await group.next() ?? .finished
            group.cancelAll()
            return result
        }

        if case .timedOut(let limit, _) = outcome {
            return .timedOut(
                timeout: limit,
                elapsed: startedAt.duration(to: .now)
            )
        }
        return outcome
    }
}

final class ControlledDeadlineClock: @unchecked Sendable {
    private enum SleepSetup {
        case cancelled
        case completed
        case registered
    }

    private struct Sleeper {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var sleepers: [UUID: Sleeper] = [:]
    private let sleepRegistrations = BoundedTestCounter()

    func now() -> ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let setup = lock.withLock { () -> SleepSetup in
                    guard !Task.isCancelled else { return .cancelled }
                    guard duration > .zero else { return .completed }
                    let deadline = instant.advanced(by: duration)
                    sleepers[id] = Sleeper(
                        deadline: deadline,
                        continuation: continuation
                    )
                    return .registered
                }
                switch setup {
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .completed:
                    continuation.resume()
                case .registered:
                    Task { await sleepRegistrations.increment() }
                }
            }
        } onCancel: {
            cancel(id)
        }
    }

    func advance(by duration: Duration) {
        let ready = lock.withLock { () -> [Sleeper] in
            instant = instant.advanced(by: duration)
            let readyIDs = sleepers.compactMap { id, sleeper in
                sleeper.deadline <= instant ? id : nil
            }
            return readyIDs.compactMap { sleepers.removeValue(forKey: $0) }
        }
        for sleeper in ready {
            sleeper.continuation.resume()
        }
    }

    func waitForSleepCount(_ count: Int) async -> BoundedTestWaitResult {
        await sleepRegistrations.wait(untilAtLeast: count)
    }

    private func cancel(_ id: UUID) {
        let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
        sleeper?.continuation.resume(throwing: CancellationError())
    }
}
