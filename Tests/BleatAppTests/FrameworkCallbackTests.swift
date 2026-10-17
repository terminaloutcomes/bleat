import AVFoundation
import BleatCore
import MediaPlayer
import Synchronization
import XCTest
import dnssd

@testable import Bleat

@MainActor
final class FrameworkCallbackTests: XCTestCase {
    func testRemotePlayAdmitsBootstrapSelectionAndClearInvalidatesIt() async {
        let coordinator = NowPlayingCoordinator(registersRemoteCommands: false)
        var commands: [PlaybackRemoteCommand] = []
        coordinator.setCommandHandler {
            commands.append($0)
            return .accepted
        }
        let play = coordinator.makeRemoteCommandCallback { (_: Void) in
            PlaybackRemoteCommand.play
        }
        let pause = coordinator.makeRemoteCommandCallback { (_: Void) in
            PlaybackRemoteCommand.pause
        }
        XCTAssertEqual(play(()), .noSuchContent)
        coordinator.setResumableSelectionAvailable(true)
        let callbackBaseline =
            coordinator.remoteCommandCallbackProcessingSequenceForTesting
        XCTAssertEqual(play(()), .success)
        XCTAssertEqual(pause(()), .noSuchContent)
        coordinator.clear()
        XCTAssertEqual(play(()), .noSuchContent)
        let callbackProcessed = await waitUntil(timeout: .seconds(30)) {
            coordinator.remoteCommandCallbackProcessingSequenceForTesting
                > callbackBaseline
        }
        XCTAssertTrue(
            callbackProcessed, "Queued bootstrap callback did not drain")
        XCTAssertTrue(commands.isEmpty)
    }

    func testRetiringBootstrapAdmissionRejectsQueuedCommandsAfterReplacement()
        async
    {
        let coordinator = NowPlayingCoordinator(registersRemoteCommands: false)
        var commands: [PlaybackRemoteCommand] = []
        coordinator.setCommandHandler {
            commands.append($0)
            return .accepted
        }
        let play = coordinator.makeRemoteCommandCallback { (_: Void) in
            PlaybackRemoteCommand.play
        }
        coordinator.setResumableSelectionAvailable(true)
        let callbackBaseline =
            coordinator.remoteCommandCallbackProcessingSequenceForTesting
        XCTAssertEqual(play(()), .success)
        coordinator.setResumableSelectionAvailable(false)
        XCTAssertEqual(play(()), .noSuchContent)
        // Replacement playback cannot revive a command for a discarded
        // selection.
        coordinator.publish(snapshot())
        let callbackProcessed = await waitUntil(timeout: .seconds(30)) {
            coordinator.remoteCommandCallbackProcessingSequenceForTesting
                > callbackBaseline
        }
        XCTAssertTrue(
            callbackProcessed, "Retired bootstrap callback did not drain")
        XCTAssertTrue(commands.isEmpty)
        // Retiring the bootstrap flag preserves valid prepared-playback
        // commands.
        coordinator.setResumableSelectionAvailable(false)
        let pause = coordinator.makeRemoteCommandCallback { (_: Void) in
            PlaybackRemoteCommand.pause
        }
        XCTAssertEqual(pause(()), .success)
    }

    func testRemoteCommandAcknowledgesWithoutInlineMainActorDelivery() async {
        let coordinator = NowPlayingCoordinator(registersRemoteCommands: false)
        let delivered = expectation(
            description: "Command delivered asynchronously")
        var commands: [PlaybackRemoteCommand] = []
        coordinator.setCommandHandler {
            commands.append($0)
            delivered.fulfill()
            return .accepted
        }
        coordinator.publish(snapshot())
        let callback = coordinator.makeRemoteCommandCallback { (_: Void) in
            .pause
        }
        XCTAssertEqual(callback(()), .success)
        XCTAssertTrue(commands.isEmpty)
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(commands, [.pause])
    }

    func testRemoteCommandCallbackRunsOffMainActor() async {
        let coordinator = NowPlayingCoordinator(registersRemoteCommands: false)
        let delivered = expectation(description: "Background command delivered")
        coordinator.setCommandHandler { command in
            MainActor.assertIsolated()
            XCTAssertEqual(command, .pause)
            delivered.fulfill()
            return .accepted
        }
        coordinator.publish(snapshot())
        let callback = coordinator.makeRemoteCommandCallback { (_: Void) in
            .pause
        }
        let status = await Task.detached { callback(()) }
            .value
        XCTAssertEqual(status, .success)
        await fulfillment(of: [delivered], timeout: 2)
    }

    func testClearRejectsQueuedCommandsAndLateCallbacks() async {
        let coordinator = NowPlayingCoordinator(registersRemoteCommands: false)
        var commands: [PlaybackRemoteCommand] = []
        coordinator.setCommandHandler {
            commands.append($0)
            return .accepted
        }
        coordinator.publish(snapshot())
        let callbackBaseline =
            coordinator.remoteCommandCallbackProcessingSequenceForTesting
        let callback = coordinator.makeRemoteCommandCallback { (_: Void) in
            .pause
        }
        XCTAssertEqual(callback(()), .success)
        coordinator.clear()
        XCTAssertEqual(callback(()), .noSuchContent)
        // Replace playback before the queued command can run. A fresh snapshot
        // must not resurrect the command admitted for the retired playback.
        coordinator.publish(snapshot())
        let callbackProcessed = await waitUntil(timeout: .seconds(30)) {
            coordinator.remoteCommandCallbackProcessingSequenceForTesting
                > callbackBaseline
        }
        XCTAssertTrue(
            callbackProcessed, "Retired playback callback did not drain")
        XCTAssertTrue(commands.isEmpty)
    }

    func testRemoteCommandRejectsInvalidEventAndPosition() {
        let coordinator = NowPlayingCoordinator(registersRemoteCommands: false)
        coordinator.setCommandHandler { _ in
            XCTFail("Invalid command delivered")
            return .accepted
        }
        coordinator.publish(snapshot())
        let invalidEvent = coordinator.makeRemoteCommandCallback { (_: Void) in
            nil
        }
        XCTAssertEqual(invalidEvent(()), .commandFailed)
        for position in [Double.nan, -1, 101] {
            let callback = coordinator.makeRemoteCommandCallback { (_: Void) in
                .seek(position)
            }
            XCTAssertEqual(callback(()), .commandFailed)
        }
    }

    func testActualPlayerKVOCallbackRunsOffMainActor() async {
        let player = AVPlayer()
        let delivered = expectation(
            description: "Off-thread KVO reaches main actor")
        let callback:
            @Sendable (AVPlayer, NSKeyValueObservedChange<Float>) -> Void =
                PlaybackObservation.handler { observed in
                    MainActor.assertIsolated()
                    XCTAssertTrue(observed === player)
                    delivered.fulfill()
                }
        let observation = player.observe(
            \.volume, options: [.new], changeHandler: callback)
        await Task.detached { player.volume = 0.25 }.value
        await fulfillment(of: [delivered], timeout: 2)
        observation.invalidate()
    }

    func testBonjourCancellationDeallocatesOnceAfterCallbackReturns()
        async throws
    {
        let queue = DispatchQueue(label: "BonjourCancellationTests.callback")
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)
        let deallocated = expectation(
            description: "Deallocated on callback queue")
        let completed = expectation(
            description: "Both cancellation completions")
        completed.expectedFulfillmentCount = 2
        let insideCallback = Mutex(false)
        let calls = Mutex(0)
        let reference = try XCTUnwrap(OpaquePointer(bitPattern: 1))
        let lifetime = BonjourDNSServiceLifetime(
            reference: reference, queue: queue
        ) { _ in
            XCTAssertEqual(DispatchQueue.getSpecific(key: key), true)
            XCTAssertFalse(insideCallback.withLock { $0 })
            calls.withLock { $0 += 1 }
            deallocated.fulfill()
        }
        queue.async {
            insideCallback.withLock { $0 = true }
            lifetime.close { completed.fulfill() }
            lifetime.close { completed.fulfill() }
            insideCallback.withLock { $0 = false }
        }
        await fulfillment(of: [deallocated, completed], timeout: 2)
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    private func snapshot() -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            accountID: nil, itemID: LibraryItemID(rawValue: "callback-test"),
            title: "Book", author: "", narrator: "", coverURL: nil,
            coverLoadPolicy: .allowNetwork, currentTime: 0, duration: 100,
            rate: 1,
            isPlaying: true, isPlaybackRequested: true,
            isPlaybackAvailable: true,
            canPerformPreviousCommand: false, canPerformNextCommand: false,
            currentChapterIndex: nil, currentChapterTitle: nil, chapterCount: 0
        )
    }

    private func waitUntil(
        timeout: Duration,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            guard !Task.isCancelled else { return false }
            if condition() { return true }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return false
            }
        }
        return condition()
    }
}
