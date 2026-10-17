import Foundation
import Testing

enum AuthTelemetryTestWaitResult: Equatable, Sendable {
    case signalled
    case timedOut(Duration)
}

enum AuthTelemetryTestCompletionResult<Value: Sendable>: Sendable {
    case completed(Value)
    case timedOut(Duration)
}

actor AuthTelemetryTestCompletion<Value: Sendable> {
    private struct Waiter {
        let continuation:
            CheckedContinuation<
                AuthTelemetryTestCompletionResult<Value>, Never
            >
        let startedAt: ContinuousClock.Instant
        var timeoutTask: Task<Void, Never>?
    }

    private var value: Value?
    private var waiter: Waiter?

    func complete(_ value: Value) {
        guard self.value == nil else { return }
        self.value = value
        guard let waiter else { return }
        self.waiter = nil
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(returning: .completed(value))
    }

    func wait(timeout: Duration = .seconds(10)) async
        -> AuthTelemetryTestCompletionResult<Value>
    {
        if let value { return .completed(value) }
        return await withCheckedContinuation { continuation in
            let startedAt = ContinuousClock.now
            waiter = Waiter(continuation: continuation, startedAt: startedAt)
            waiter?.timeoutTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self.timeOut()
            }
        }
    }

    private func timeOut() {
        guard let waiter else { return }
        self.waiter = nil
        waiter.continuation.resume(
            returning: .timedOut(waiter.startedAt.duration(to: .now))
        )
    }
}

func requireAuthTelemetryCompletion<Value: Sendable>(
    _ completion: AuthTelemetryTestCompletion<Value>,
    stage: String,
    timeout: Duration = .seconds(10),
    sourceLocation: SourceLocation = #_sourceLocation
) async -> Value? {
    switch await completion.wait(timeout: timeout) {
    case .completed(let value):
        return value
    case .timedOut(let elapsed):
        Issue.record(
            "Timed out waiting for \(stage) after \(elapsed).",
            sourceLocation: sourceLocation
        )
        return nil
    }
}

/// A reusable, bounded event for auth and telemetry test fakes.
actor AuthTelemetryTestSignal {
    private struct Waiter {
        let continuation:
            CheckedContinuation<AuthTelemetryTestWaitResult, Never>
        let startedAt: ContinuousClock.Instant
        var timeoutTask: Task<Void, Never>?
    }

    private var hasSignalled = false
    private var waiters: [UUID: Waiter] = [:]

    func signal() {
        hasSignalled = true
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting.values {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(returning: .signalled)
        }
    }

    func wait(timeout: Duration = .seconds(10)) async
        -> AuthTelemetryTestWaitResult
    {
        guard !hasSignalled else { return .signalled }
        let id = UUID()
        let startedAt = ContinuousClock.now
        return await withCheckedContinuation { continuation in
            waiters[id] = Waiter(
                continuation: continuation,
                startedAt: startedAt
            )
            waiters[id]?.timeoutTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self.timeOut(id)
            }
        }
    }

    private func timeOut(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(
            returning: .timedOut(waiter.startedAt.duration(to: .now))
        )
    }
}

@discardableResult
func requireAuthTelemetrySignal(
    _ signal: AuthTelemetryTestSignal,
    stage: String,
    timeout: Duration = .seconds(10),
    sourceLocation: SourceLocation = #_sourceLocation
) async -> Bool {
    switch await signal.wait(timeout: timeout) {
    case .signalled:
        return true
    case .timedOut(let elapsed):
        Issue.record(
            "Timed out waiting for \(stage) after \(elapsed).",
            sourceLocation: sourceLocation
        )
        return false
    }
}

@discardableResult
func requireAuthTelemetryCondition(
    stage: String,
    timeout: Duration = .seconds(10),
    sourceLocation: SourceLocation = #_sourceLocation,
    condition: @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let startedAt = clock.now
    let deadline = startedAt.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        do {
            try await Task.sleep(for: .milliseconds(10))
        } catch {
            Issue.record(
                "Cancelled while waiting for \(stage) after \(startedAt.duration(to: clock.now)).",
                sourceLocation: sourceLocation
            )
            return false
        }
    }
    Issue.record(
        "Timed out waiting for \(stage) after \(startedAt.duration(to: clock.now)).",
        sourceLocation: sourceLocation
    )
    return false
}
