import BleatCore
import Foundation

struct RecordedRemoteTelemetrySpan: Equatable {
    let operation: RemoteTelemetryOperation
    let source: RemoteTelemetrySource?
    let retryBucket: RemoteTelemetryRetryBucket
    var outcome: RemoteTelemetryOutcome?
}

final class RecordingRemoteTelemetryTracer: RemoteTelemetryTracing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var records: [UUID: RecordedRemoteTelemetrySpan] = [:]
    private var order: [UUID] = []

    var spans: [RecordedRemoteTelemetrySpan] {
        lock.withLock {
            order.compactMap { records[$0] }
        }
    }

    func beginSpan(
        operation: RemoteTelemetryOperation,
        source: RemoteTelemetrySource?,
        retryBucket: RemoteTelemetryRetryBucket
    ) -> RemoteTelemetrySpan {
        let id = UUID()
        lock.withLock {
            order.append(id)
            records[id] = RecordedRemoteTelemetrySpan(
                operation: operation,
                source: source,
                retryBucket: retryBucket,
                outcome: nil
            )
        }
        return RemoteTelemetrySpan { [weak self] outcome in
            self?.lock.withLock {
                self?.records[id]?.outcome = outcome
            }
        }
    }
}

final class RecordingRemoteTelemetryDownloadLogger:
    RemoteTelemetryDownloadLogging, @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedEvents: [RemoteDownloadTransferEvent] = []

    var events: [RemoteDownloadTransferEvent] {
        lock.withLock { recordedEvents }
    }

    func recordDownloadEvent(
        _ event: RemoteDownloadTransferEvent,
        span: RemoteTelemetrySpan?
    ) {
        lock.withLock {
            recordedEvents.append(event)
        }
    }
}
