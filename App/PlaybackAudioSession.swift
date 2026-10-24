import AVFoundation
import BleatCore
import Foundation
import Synchronization

struct AudioSessionFailure: Error, Equatable, Sendable, Codable {
    enum Operation: String, Sendable, Codable {
        case configuration, activation, deactivation
    }
    enum Cause: Equatable, Sendable, Codable {
        case rejected
        case cancelled
        case native(domain: DiagnosticNativeErrorDomain, code: Int)
    }
    let operation: Operation
    let cause: Cause

    init(operation: Operation, cause: Cause) {
        self.operation = operation
        self.cause = cause
    }

    init(operation: Operation, error: NSError) {
        let domain: DiagnosticNativeErrorDomain
        switch error.domain {
        case NSOSStatusErrorDomain: domain = .osStatus
        case AVFoundationErrorDomain: domain = .avFoundation
        case NSCocoaErrorDomain: domain = .cocoa
        default: domain = .unrecognized
        }
        self.init(
            operation: operation,
            cause: .native(domain: domain, code: error.code))
    }

    var diagnosticStage: DiagnosticStage {
        switch operation {
        case .configuration: .audioSessionConfiguration
        case .activation: .audioSessionActivation
        case .deactivation: .audioSessionDeactivation
        }
    }
    var diagnosticFailureCode: DiagnosticFailureCode {
        switch cause {
        case .rejected: .audioSessionRejected
        case .cancelled: .audioSessionCancelled
        case .native: .audioSessionNativeFailure
        }
    }
    var nativeDomain: DiagnosticNativeErrorDomain? {
        if case .native(let domain, _) = cause { domain } else { nil }
    }
    var nativeCode: Int? {
        if case .native(_, let code) = cause { code } else { nil }
    }
    var diagnosticsCodes: [String] {
        var codes = [
            "audio_session.\(operation.rawValue).\(diagnosticFailureCode.rawValue)"
        ]
        if let nativeDomain, let nativeCode {
            codes.append(
                "audio_session.\(operation.rawValue).\(nativeDomain.rawValue).\(nativeCode)"
            )
        }
        return codes
    }
    var presentationTitle: String {
        switch operation {
        case .configuration: "Audio setup unavailable"
        case .activation: "Audio session unavailable"
        case .deactivation: "Audio session could not close"
        }
    }
    var presentationMessage: String {
        switch (operation, cause) {
        case (_, .cancelled): "The audio request was cancelled."
        case (.configuration, .rejected):
            "The system rejected the audio category configuration."
        case (.activation, .rejected):
            "The system rejected the audio activation request. Try Play again."
        case (.deactivation, .rejected):
            "Playback stopped, but the system rejected the audio release request."
        case (.configuration, .native):
            "The audio system could not configure spoken-audio playback."
        case (.activation, .native):
            "The audio system could not activate playback. Try Play again."
        case (.deactivation, .native):
            "Playback stopped, but the audio system could not release the session."
        }
    }
    func diagnosticEvent(_ operation: DiagnosticOperation) -> DiagnosticEvent {
        .failed(
            operation, category: .playback, failureCode: diagnosticFailureCode,
            stage: diagnosticStage, nativeErrorDomain: nativeDomain,
            nativeErrorCode: nativeCode)
    }
}

/// The session is process-wide. Every native operation owns and awaits its
/// predecessor, including after caller cancellation; the framework has no
/// cancellation API that proves activation has retired.
struct AudioSessionLease: Equatable, Sendable {
    fileprivate let id: UUID
}

@MainActor
final class PlaybackAudioSession {
    typealias Action =
        @MainActor @Sendable () async throws(AudioSessionFailure) -> Void
    static let system = PlaybackAudioSession(
        activate: SystemPlaybackAudioSession.activate,
        deactivate: SystemPlaybackAudioSession.deactivate)

    private let activation: Action
    private let deactivation: Action
    private var tail: Task<Result<Void, AudioSessionFailure>, Never>?
    private var tailID: UUID?

    init(activate: @escaping Action, deactivate: @escaping Action) {
        activation = activate
        deactivation = deactivate
    }

    private var latestActivation: AudioSessionLease?

    @discardableResult
    func activate() async throws(AudioSessionFailure) -> AudioSessionLease {
        guard !Task.isCancelled else {
            throw AudioSessionFailure(operation: .activation, cause: .cancelled)
        }
        let lease = AudioSessionLease(id: UUID())
        latestActivation = lease
        let (id, task) = schedule(activation)
        let result = await task.value
        retire(id)
        try result.get()
        return lease
    }

    func deactivate(ifCurrent lease: AudioSessionLease? = nil)
        async throws(AudioSessionFailure)
    {
        if let lease, latestActivation != lease { return }
        latestActivation = nil
        // Reservation and scheduling are synchronous: a newer activation cannot
        // slip ahead of this release between an ownership check and an await.
        let (id, task) = schedule(deactivation)
        let result = await task.value
        retire(id)
        try result.get()
    }

    private func schedule(_ action: @escaping Action) -> (
        UUID, Task<Result<Void, AudioSessionFailure>, Never>
    ) {
        let predecessor = tail
        let id = UUID()
        let task = Task { @MainActor () -> Result<Void, AudioSessionFailure> in
            _ = await predecessor?.value
            do throws(AudioSessionFailure) {
                try await action()
                return .success(())
            } catch { return .failure(error) }
        }
        tail = task
        tailID = id
        return (id, task)
    }

    private func retire(_ id: UUID) {
        if tailID == id {
            tail = nil
            tailID = nil
        }
    }

    nonisolated static func awaitNative(
        _ operation: AudioSessionFailure.Operation,
        start: @Sendable (@escaping @Sendable (Bool, NSError?) -> Void) -> Void
    ) async throws(AudioSessionFailure) {
        let result = await withCheckedContinuation {
            (
                continuation: CheckedContinuation<
                    Result<Void, AudioSessionFailure>, Never
                >
            ) in
            let completion = AudioSessionCompletion(continuation)
            start { @Sendable succeeded, error in
                let result: Result<Void, AudioSessionFailure>
                if let error {
                    result = .failure(
                        AudioSessionFailure(operation: operation, error: error))
                } else if succeeded {
                    result = .success(())
                } else {
                    result = .failure(
                        AudioSessionFailure(
                            operation: operation, cause: .rejected))
                }
                completion.resolve(result)
            }
        }
        try result.get()
    }
}

private final class AudioSessionCompletion: Sendable {
    private let continuation:
        Mutex<CheckedContinuation<Result<Void, AudioSessionFailure>, Never>?>
    init(
        _ continuation: CheckedContinuation<
            Result<Void, AudioSessionFailure>, Never
        >
    ) {
        self.continuation = Mutex(continuation)
    }
    func resolve(_ result: Result<Void, AudioSessionFailure>) {
        let continuation = continuation.withLock { stored in
            let current = stored
            stored = nil
            return current
        }
        continuation?.resume(returning: result)
    }
}

@MainActor
private enum SystemPlaybackAudioSession {
    static func activate() async throws(AudioSessionFailure) {
        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            // Approved unavoidable boundary: Apple has no async category API.
            // Do not reconfigure an already-correct active session.
            if session.category != .playback || session.mode != .spokenAudio {
                do {
                    try session.setCategory(.playback, mode: .spokenAudio)
                } catch {
                    throw AudioSessionFailure(
                        operation: .configuration, error: error as NSError)
                }
            }
            if #available(iOS 27.0, *) {
                try await PlaybackAudioSession.awaitNative(.activation) {
                    completion in
                    BleatActivateAudioSession { @Sendable succeeded, error in
                        completion(succeeded, error.map { $0 as NSError })
                    }
                }
            } else {
                // User-approved iOS 26 boundary; no native async activation exists.
                do { try session.setActive(true) } catch {
                    throw AudioSessionFailure(
                        operation: .activation, error: error as NSError)
                }
            }
        #endif
    }

    static func deactivate() async throws(AudioSessionFailure) {
        #if os(iOS)
            if #available(iOS 27.0, *) {
                try await PlaybackAudioSession.awaitNative(.deactivation) {
                    completion in
                    BleatDeactivateAudioSession { @Sendable succeeded, error in
                        completion(succeeded, error.map { $0 as NSError })
                    }
                }
            } else {
                // User-approved iOS 26 boundary; no native async deactivation exists.
                do {
                    try AVAudioSession.sharedInstance().setActive(
                        false, options: .notifyOthersOnDeactivation)
                } catch {
                    throw AudioSessionFailure(
                        operation: .deactivation, error: error as NSError)
                }
            }
        #endif
    }
}
