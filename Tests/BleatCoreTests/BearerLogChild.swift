import Darwin
import Dispatch
import Foundation

/// Test-only supervisor for the bearer-log scenario. Never redirects parent descriptors.
enum BearerLogChild {
    static let selection = "testBearerNeverAppearsInCapturedProcessLogs"
    static let suite = "BleatCoreTests.AuthenticatedOtlpSpanExporterTests"
    static let name = selection + "()"
    static let environmentKey = "BLEAT_BEARER_LOG_CHILD"
    static let secret = "captured-private-bearer-material"

    enum Mode: String, Sendable {
        case exporter, failure, hang, flood, leak, incompleteReport
    }

    enum Failure: Error, Equatable, Sendable {
        case setupDirectory, pipeCreation, launch, writerClose, timeout,
            cancelled, outputOverflow, outputIncomplete
        case reportOverflow, reportIncomplete, childFailed
        case reportRejected(ReportFailure)
        case missingSentinel, secretInOutput
    }

    enum CleanupFailure: String, Sendable {
        case readerClose, writerClose, kill, deadline, reportRemoval
    }

    struct Result: Sendable {
        let failure: Failure?
        let cleanupFailures: [CleanupFailure]
        let reaped: Bool
        let readersClosed: Bool
        let writersClosed: Bool
        let reportRemoved: Bool
        let privacyFailure: Failure?
        let capturedByteCount: Int
        let elapsed: Duration
        let timeout: Duration
    }

    private static func checkPrivacy(_ output: Data) -> Failure? {
        let text = String(decoding: output, as: UTF8.self)
        guard !text.contains(secret), !text.contains("Bearer \(secret)") else {
            return .secretInOutput
        }
        guard text.contains("stdout capture sentinel"),
            text.contains("stderr capture sentinel")
        else { return .missingSentinel }
        return nil
    }

    private enum Event: Sendable {
        case exited(Int32)
        case outputClosed, reportClosed
        case failed(Failure)
        case cleanupFailed(CleanupFailure)
        case deadline, cleanupDeadline, cancelled
    }

    /// DispatchIO is the native asynchronous descriptor API: no blocking EOF
    /// read, FileHandle readability callback, worker thread, or queue-wrapped read.
    /// The callback retains at most `limit` bytes and signals overflow once.
    private final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private var complete = false
        private var closed = false
        private var failed = false
        private let channel: DispatchIO

        init(
            descriptor: Int32, limit: Int, overflow: Failure,
            incomplete: Failure, closedEvent: Event,
            events: AsyncStream<Event>.Continuation
        ) {
            let queue = DispatchQueue(label: "bleat.bearer-child.reader")
            // close(2) only releases the owned descriptor; it performs no read.
            channel = DispatchIO(
                type: .stream, fileDescriptor: descriptor, queue: queue
            ) { @Sendable error in
                let closeResult = Darwin.close(descriptor)
                if error != 0 || closeResult != 0 {
                    events.yield(.cleanupFailed(.readerClose))
                }
                events.yield(closedEvent)
            }
            channel.setLimit(lowWater: 1)
            channel.setLimit(highWater: 16 * 1024)
            channel.read(offset: 0, length: .max, queue: queue) {
                @Sendable [self] done, data, error in
                let failure: Failure? = lock.withLock {
                    if let data, !failed {
                        if data.count > limit - bytes.count {
                            failed = true
                            return overflow
                        }
                        bytes.append(contentsOf: data)
                    }
                    if error != 0, !failed {
                        failed = true
                        return incomplete
                    }
                    if done { complete = error == 0 && !failed }
                    return nil
                }
                if let failure { events.yield(.failed(failure)) }
                if done { channel.close() }
            }
        }

        func stop() { channel.close(flags: .stop) }
        func markClosed() { lock.withLock { closed = true } }
        var snapshot: (bytes: Data, complete: Bool, closed: Bool) {
            lock.withLock { (bytes, complete, closed) }
        }
    }

    /// 20s covers helper startup plus a two-second exporter deadline, including
    /// instrumented signed-host runs. 5s separately bounds SIGKILL/reap and IO
    /// cleanup. 1MiB output and 64KiB XML are far above this single test's needs.
    static func run(
        mode: Mode = .exporter, timeout: Duration = .seconds(20),
        outputLimit: Int = 1024 * 1024,
        executable: URL? = nil,
        launched: BoundedTestCounter? = nil
    ) async -> Result {
        let events = AsyncStream<Event>.makeStream()
        // AsyncStream iteration in a cancelled task ends immediately. Keep its
        // consumer independent of caller cancellation, then explicitly join it.
        // The cancellation event requests teardown; it never cancels observation.
        let supervisor = Task.detached {
            await supervise(
                mode: mode, timeout: timeout, outputLimit: outputLimit,
                executable: executable, launched: launched, events: events)
        }
        return await withTaskCancellationHandler {
            await supervisor.value
        } onCancel: {
            events.continuation.yield(.cancelled)
        }
    }

    private static func supervise(
        mode: Mode, timeout: Duration, outputLimit: Int,
        executable: URL?, launched: BoundedTestCounter?,
        events: (
            stream: AsyncStream<Event>,
            continuation: AsyncStream<Event>.Continuation
        )
    ) async -> Result {
        let began = ContinuousClock.now
        let process = Process()
        process.terminationHandler = { @Sendable child in
            events.continuation.yield(.exited(child.terminationStatus))
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bleat-bearer-child-\(UUID().uuidString)")
        let reportURL = directory.appendingPathComponent("child.xml")
        var primary: Failure?
        var cleanupFailures: [CleanupFailure] = []
        var output: Reader?
        var report: Reader?
        var writer: FileHandle?
        var writersClosed = true
        var started = false
        var reaped = false
        var status: Int32?
        var timer: Task<Void, Never>?
        var cleanupTimer: Task<Void, Never>?

        var launchStage = Failure.setupDirectory
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            var descriptors: [Int32] = [-1, -1]
            guard Darwin.pipe(&descriptors) == 0 else {
                throw Failure.pipeCreation
            }
            output = Reader(
                descriptor: descriptors[0], limit: outputLimit,
                overflow: .outputOverflow, incomplete: .outputIncomplete,
                closedEvent: .outputClosed, events: events.continuation)
            writer = FileHandle(
                fileDescriptor: descriptors[1], closeOnDealloc: true)
            writersClosed = false
            process.executableURL =
                executable ?? URL(fileURLWithPath: CommandLine.arguments[0])
            var arguments: [String] = []
            if let index = CommandLine.arguments.firstIndex(
                of: "--test-bundle-path"),
                CommandLine.arguments.indices.contains(index + 1)
            {
                arguments += [
                    "--test-bundle-path", CommandLine.arguments[index + 1],
                    "--testing-library", "swift-testing",
                ]
            }
            arguments += [
                "--no-parallel", "--filter", "\(suite).\(name)",
                "--xunit-output", reportURL.path,
            ]
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment[environmentKey] = mode.rawValue
            if environment["LLVM_PROFILE_FILE"]?.contains("%p") != true {
                environment["LLVM_PROFILE_FILE"] =
                    directory.appendingPathComponent("coverage-%p.profraw").path
            }
            process.environment = environment
            process.standardOutput = writer
            process.standardError = writer
            launchStage = .launch
            try process.run()
            started = true
            launchStage = .writerClose
            try writer?.close()
            writersClosed = true
            await launched?.increment()
        } catch {
            primary = (error as? Failure) ?? launchStage
            do {
                try writer?.close()
                writersClosed = true
            } catch { cleanupFailures.append(.writerClose) }
            output?.stop()
        }

        if let primary { events.continuation.yield(.failed(primary)) }
        timer = Task.detached {
            do { try await Task.sleep(for: timeout) } catch { return }
            events.continuation.yield(.deadline)
        }

        for await event in events.stream {
            switch event {
            case .exited(let exitStatus):
                reaped = true
                status = exitStatus
                if primary == nil {
                    if exitStatus != 0 {
                        primary = .childFailed
                    } else {
                        let fd = Darwin.open(
                            reportURL.path, O_RDONLY | O_NONBLOCK)
                        if fd < 0 {
                            primary = .reportIncomplete
                        } else {
                            report = Reader(
                                descriptor: fd, limit: 64 * 1024,
                                overflow: .reportOverflow,
                                incomplete: .reportIncomplete,
                                closedEvent: .reportClosed,
                                events: events.continuation)
                        }
                    }
                }
            case .outputClosed: output?.markClosed()
            case .reportClosed: report?.markClosed()
            case .failed(let failure):
                if primary == nil { primary = failure }
            case .cleanupFailed(let failure):
                cleanupFailures.append(failure)
            case .deadline:
                if primary == nil { primary = .timeout }
            case .cancelled:
                if primary == nil { primary = .cancelled }
            case .cleanupDeadline:
                cleanupFailures.append(.deadline)
                break
            }
            if case .cleanupDeadline = event { break }
            if primary != nil, cleanupTimer == nil {
                // SIGKILL cannot be ignored by a hung test. Process's
                // termination callback observes Foundation's waitpid/reap.
                if started, !reaped, process.isRunning {
                    if Darwin.kill(process.processIdentifier, SIGKILL) != 0,
                        errno != ESRCH
                    {
                        cleanupFailures.append(.kill)
                    }
                }
                output?.stop()
                report?.stop()
                cleanupTimer = Task.detached {
                    do { try await Task.sleep(for: .seconds(5)) } catch {
                        return
                    }
                    events.continuation.yield(.cleanupDeadline)
                }
            }
            if !started || reaped,
                output?.snapshot.closed != false,
                report?.snapshot.closed != false
            {
                break
            }
        }
        timer?.cancel()
        cleanupTimer?.cancel()
        await timer?.value
        await cleanupTimer?.value
        events.continuation.finish()
        process.terminationHandler = nil

        let captured = output?.snapshot
        if primary == nil {
            if captured?.complete != true {
                primary = .outputIncomplete
            } else if report?.snapshot.complete != true {
                primary = .reportIncomplete
            } else if let failure = reportFailure(
                report?.snapshot.bytes ?? Data())
            {
                primary = .reportRejected(failure)
            } else if status != 0 {
                primary = .childFailed
            }
        }
        var removed = false
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            removed = true
        } catch { cleanupFailures.append(.reportRemoval) }
        return Result(
            failure: primary, cleanupFailures: cleanupFailures,
            reaped: started && reaped && !process.isRunning,
            readersClosed: output?.snapshot.closed != false
                && report?.snapshot.closed != false,
            writersClosed: writersClosed, reportRemoved: removed,
            privacyFailure: checkPrivacy(captured?.bytes ?? Data()),
            capturedByteCount: captured?.bytes.count ?? 0,
            elapsed: began.duration(to: .now), timeout: timeout)
    }

    enum ReportFailure: String, Sendable {
        case malformed, summary, missingIdentity, duplicateIdentity
        case unexpectedIdentity, skipped, failed, unknownOutcome, incomplete
    }

    static func reportFailure(_ data: Data) -> ReportFailure? {
        let delegate = ReportParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { return .malformed }
        if let failure = delegate.failure { return failure }
        guard delegate.cases > 0 else { return .missingIdentity }
        guard delegate.cases == 1 else { return .duplicateIdentity }
        guard delegate.suites == 1, delegate.rootClosed else {
            return .incomplete
        }
        return nil
    }

    private final class ReportParser: NSObject, XMLParserDelegate {
        var failure: ReportFailure?
        var cases = 0
        var suites = 0
        var rootClosed = false
        private var stack: [String] = []

        private func reject(_ cause: ReportFailure) {
            if failure == nil { failure = cause }
        }

        func parser(
            _ parser: XMLParser, didStartElement name: String,
            namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            switch name {
            case "testsuites":
                if !stack.isEmpty { reject(.incomplete) }
            case "testsuite":
                suites += 1
                if stack != ["testsuites"] { reject(.incomplete) }
                if attributes["tests"] != "1" || attributes["failures"] != "0"
                    || attributes["errors"] != "0"
                    || attributes["skipped"] != "0"
                {
                    reject(.summary)
                }
            case "testcase":
                cases += 1
                if stack != ["testsuites", "testsuite"] { reject(.incomplete) }
                if attributes["classname"] != suite
                    || attributes["name"] != BearerLogChild.name
                {
                    reject(.unexpectedIdentity)
                }
                if attributes["time"].flatMap(Double.init).map({
                    $0.isFinite && $0 >= 0
                }) != true {
                    reject(.incomplete)
                }
                if attributes["status"] != nil || attributes["result"] != nil {
                    reject(.unknownOutcome)
                }
            case "skipped": reject(.skipped)
            case "failure", "error": reject(.failed)
            default: reject(.unknownOutcome)
            }
            stack.append(name)
        }

        func parser(
            _ parser: XMLParser, didEndElement name: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            if name == "testsuites" { rootClosed = true }
            _ = stack.popLast()
        }
    }
}
