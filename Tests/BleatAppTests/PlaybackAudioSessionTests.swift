import BleatCore
import Foundation
import Synchronization
import XCTest

@testable import Bleat

@MainActor
final class PlaybackAudioSessionTests: XCTestCase {
    func testNativeInlineDuplicateCompletionPreservesFirstTypedResult()
        async throws
    {
        for operation in [
            AudioSessionFailure.Operation.configuration, .activation,
            .deactivation,
        ] {
            do {
                try await PlaybackAudioSession.awaitNative(operation) {
                    completion in
                    completion(
                        false,
                        NSError(
                            domain: NSOSStatusErrorDomain, code: -50,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "private-token-and-path"
                            ]))
                    completion(true, nil)
                }
                XCTFail("Expected native failure for \(operation)")
            } catch {
                XCTAssertEqual(
                    error,
                    AudioSessionFailure(
                        operation: operation,
                        cause: .native(domain: .osStatus, code: -50)))
                let event = error.diagnosticEvent(.activateAudioSession)
                XCTAssertEqual(event.stage, error.diagnosticStage)
                XCTAssertEqual(event.nativeErrorDomain, .osStatus)
                XCTAssertEqual(event.nativeErrorCode, -50)
                let encoded = try JSONEncoder().encode(event)
                XCTAssertFalse(
                    String(decoding: encoded, as: UTF8.self).contains(
                        "private-token-and-path"))
                let decoded = try JSONDecoder().decode(
                    DiagnosticEvent.self, from: encoded)
                XCTAssertEqual(decoded.nativeErrorCode, -50)
                XCTAssertEqual(decoded.stage, event.stage)
                XCTAssertEqual(
                    AppFailure(.openPlayback, .audioSession(error))
                        .diagnosticFailureCode,
                    .audioSessionNativeFailure)
            }
        }
    }

    func testNativeOffActorLateCompletionAndRejection() async throws {
        let delivery = NativeAudioCompletionDelivery()
        let operation = Task { () -> Result<Void, AudioSessionFailure> in
            do throws(AudioSessionFailure) {
                try await PlaybackAudioSession.awaitNative(.activation) {
                    completion in
                    delivery.install(completion)
                }
                return .success(())
            } catch { return .failure(error) }
        }
        await assertEventually(
            "native completion registration", timeout: .seconds(2),
            observed: { "installed=\(delivery.isInstalled)" },
            condition: { delivery.isInstalled })
        await Task.detached {
            delivery.complete(false, nil)
            delivery.complete(
                false, NSError(domain: NSCocoaErrorDomain, code: 99))
        }.value
        switch await operation.value {
        case .success: XCTFail("Expected rejection")
        case .failure(let failure):
            XCTAssertEqual(
                failure,
                AudioSessionFailure(operation: .activation, cause: .rejected))
        }
    }

    func testCancelledActivationDrainsBeforeQueuedDeactivation() async throws {
        let probe = AudioLifecycleProbe()
        let gate = AsyncGate()
        let session = PlaybackAudioSession(
            activate: {
                probe.events.append("activate-start")
                await gate.enterAndWait()
                probe.events.append("activate-end")
            }, deactivate: { probe.events.append("deactivate") })
        let activation = Task { try await session.activate() }
        await gate.waitUntilEntered()
        activation.cancel()
        let release = Task {
            probe.releaseRequested = true
            try await session.deactivate()
        }
        await assertEventually(
            "release admission", timeout: .seconds(2),
            observed: { "events=\(probe.events)" },
            condition: { probe.releaseRequested })
        await gate.release()
        _ = try await activation.value
        try await release.value
        XCTAssertEqual(
            probe.events, ["activate-start", "activate-end", "deactivate"])
    }

    func testRetiredActivationLeaseCannotReleaseNewerActivation() async throws {
        let probe = AudioLifecycleProbe()
        let gate = AsyncGate()
        let session = PlaybackAudioSession(
            activate: {
                probe.activations += 1
                probe.events.append("activate-\(probe.activations)")
                if probe.activations == 2 { await gate.enterAndWait() }
            }, deactivate: { probe.events.append("deactivate") })
        let old = try await session.activate()
        let replacement = Task { try await session.activate() }
        await gate.waitUntilEntered()
        try await session.deactivate(ifCurrent: old)
        await gate.release()
        let current = try await replacement.value
        XCTAssertEqual(probe.events, ["activate-1", "activate-2"])
        try await session.deactivate(ifCurrent: current)
        XCTAssertEqual(
            probe.events, ["activate-1", "activate-2", "deactivate"])
    }

    func testCancelledBeforeAdmissionDoesNotActivate() async {
        let probe = AudioLifecycleProbe()
        let session = PlaybackAudioSession(
            activate: { probe.activations += 1 }, deactivate: {})
        let operation = Task { () -> AudioSessionFailure? in
            withUnsafeCurrentTask { $0?.cancel() }
            do throws(AudioSessionFailure) {
                _ = try await session.activate()
                return nil
            } catch { return error }
        }
        let failure = await operation.value
        XCTAssertEqual(
            failure,
            AudioSessionFailure(operation: .activation, cause: .cancelled))
        XCTAssertEqual(probe.activations, 0)
    }

    func testFailedDeactivationDoesNotPoisonNextActivation() async throws {
        let probe = AudioLifecycleProbe()
        let session = PlaybackAudioSession(
            activate: { probe.activations += 1 },
            deactivate: { () async throws(AudioSessionFailure) in
                throw AudioSessionFailure(
                    operation: .deactivation, cause: .rejected)
            })
        _ = try await session.activate()
        do throws(AudioSessionFailure) {
            try await session.deactivate()
            XCTFail("Expected rejected release")
        } catch {
            XCTAssertEqual(
                error,
                AudioSessionFailure(operation: .deactivation, cause: .rejected))
        }
        _ = try await session.activate()
        XCTAssertEqual(probe.activations, 2)
    }

    func testSystemAudioSessionCompletesActivationAndDeactivation() async throws
    {
        let lease = try await PlaybackAudioSession.system.activate()
        try await PlaybackAudioSession.system.deactivate(ifCurrent: lease)
    }
}

@MainActor
private final class AudioLifecycleProbe {
    var events: [String] = []
    var activations = 0
    var releaseRequested = false
}

private final class NativeAudioCompletionDelivery: Sendable {
    typealias Completion = @Sendable (Bool, NSError?) -> Void
    private let callback = Mutex<Completion?>(nil)
    var isInstalled: Bool { callback.withLock { $0 != nil } }
    func install(_ completion: @escaping Completion) {
        callback.withLock { $0 = completion }
    }
    func complete(_ succeeded: Bool, _ error: NSError?) {
        let completion = callback.withLock { $0 }
        completion?(succeeded, error)
    }
}
