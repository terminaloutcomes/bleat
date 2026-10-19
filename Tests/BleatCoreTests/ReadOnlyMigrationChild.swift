import CloudKit
import Darwin
import Dispatch
import Foundation
import SwiftData
import Testing

@testable import BleatCore

/// Scenario-specific process boundary. No parent descriptors are redirected.
/// Foundation has no asynchronous Process.run: the deadline starts before launch,
/// but cannot interrupt that synchronous call. It bounds supervision after return.
/// Bounded JSON/XML parsing and owned filesystem metadata/cleanup are synchronous
/// Foundation boundaries; process observation and all descriptor IO are native async.
enum ReadOnlyMigrationChild {
    static let suite = "BleatCoreTests.PrivateCloudPersistenceTests"
    static let name = "failedMigrationSaveRetainsLegacyPreferences()"
    static let environmentKey = "BLEAT_READ_ONLY_MIGRATION_CHILD_V1"
    static let outputLimit = 1024 * 1024
    static let xmlLimit = 64 * 1024
    static let typedLimit = 16 * 1024

    enum Mode: String, Codable, Sendable, CaseIterable {
        case migration, assertion, thrown, skip, knownIssue, zeroSelection
        case hang, signal, missingResult, malformedResult, oversizedResult
        case wrongNonce, invalidVersion, partialMarker, flood, oversizedXML,
            duplicateResult
    }
    enum Phase: Equatable, Sendable {
        case beforeLaunch, afterLaunch, teardown, beforeValidation,
            beforeCleanup
    }
    enum ReportFault: Equatable, Sendable {
        case none, missingXML, malformedXML, duplicateXML, oversizedXML
    }
    enum DiagnosticFault: Sendable {
        case none, stallCompletion, stallCompletionAndLoseCloseAcknowledgment
    }
    struct Options: Sendable {
        var mode: Mode = .migration
        var timeout: Duration = .seconds(20)
        var teardownTimeout: Duration = .seconds(5)
        var diagnosticTimeout: Duration = .seconds(1)
        var diagnosticDrainTimeout: Duration = .seconds(1)
        var diagnosticFault: DiagnosticFault = .none
        var executable: URL?
        var reportFault: ReportFault = .none
        var suppressExitEvent = false
        var suppressOutputCloseEvent = false
        var injectXMLCloseError = false
        var injectCancellationDuringLaunch = false
        var removeRootFirst = false
        var failSetupAfterPipe = false
        var hook: @Sendable (Phase) async -> Void = { _ in }
    }
    enum ExitReason: String, Sendable { case normal, signal, unknown }
    struct Exit: Equatable, Sendable {
        let reason: ExitReason
        let status: Int32
    }
    enum Liveness: Equatable, Sendable {
        case notLaunched
        case running
        case exited(Exit)
        case uncertain
        var permitsCleanup: Bool {
            switch self {
            case .notLaunched, .exited: true
            case .running, .uncertain: false
            }
        }
    }
    enum IO: String, Sendable { case output, xml, typed }
    enum TypedFailure: String, Sendable {
        case missing, malformed, version, nonce, scenario, mode, outcome,
            preferences, knownIssue
    }
    enum Failure: Equatable, Sendable {
        case setup(Native)
        case launch(Native)
        case cancelled, deadline
        case signal(Int32)
        case exitStatus(Int32)
        case unknownTermination
        case ioOverflow(IO)
        case ioIncomplete(IO)
        case ioRead(IO, Int32)
        case xml(ReportFailure)
        case typed(TypedFailure)
        case childReported(Cause)
    }
    struct Native: Error, Equatable, Codable, Sendable {
        let domain: String
        let code: Int
        init(_ error: Error) {
            let value = error as NSError
            // Domains are identifiers, never userInfo/descriptions or paths.
            domain =
                value.domain.count <= 128 && !value.domain.contains("/")
                ? value.domain : "unrepresentable-native-domain"
            code = value.code
        }
    }
    enum CleanupFailure: Equatable, Sendable {
        case readerClose(IO, Int32)
        case writerClose(Native)
        case kill(Int32)
        case exitUnconfirmed, ioUnconfirmed
        case diagnosticWrite(Native)
        case diagnosticClose(Native)
        case diagnosticDeadline, diagnosticCancelled, diagnosticUnconfirmed
        case rootRemoval(Native)
        case defaultsRemoval, rootStillPresent
    }
    enum Cause: String, Codable, Sendable {
        case metadataWriteFailed, unexpectedSuccess, unexpectedFailure
        case injectedAssertion, injectedThrow, injectedSkip, injectedKnownIssue
    }
    enum Stage: String, Codable, Sendable {
        case control, prepareStorage, verifyPersistence
    }
    struct Report: Codable, Equatable, Sendable {
        var version = 1
        var nonce: UUID
        var scenario = "read-only-migration"
        var mode: Mode
        var stage: Stage
        var cause: Cause
        var native: Native?
        var archiveEqual: Bool?
        var migrationComplete: Bool?
        var preferencesVisible: Bool
        var knownIssues = 0
    }
    struct Configuration: Codable, Sendable {
        var version = 1
        let nonce: UUID
        let root: URL
        let dataDomain: String
        let configurationDomain: String
        var mode: Mode
    }
    enum ConfigurationFailure: Error {
        case malformed, version, identity, preferences
    }
    enum InjectedError: Error, Equatable { case thrown, knownIssue }

    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var flag: Bool
        init(_ cancelled: Bool) { flag = cancelled }
        func cancel() { lock.withLock { flag = true } }
        var value: Bool { lock.withLock { flag } }
    }
    final class ExitProof: @unchecked Sendable {
        private let lock = NSLock()
        private var exit: Exit?
        private var owner: Process?
        func retain(_ process: Process) { lock.withLock { owner = process } }
        func release() { lock.withLock { owner = nil } }
        func record(_ value: Exit) {
            lock.withLock {
                exit = value
                owner = nil
            }
        }
        var value: Exit? { lock.withLock { exit } }
    }
    /// Parent owns these exact identities before launch. Never remove on uncertain liveness.
    final class Resources: @unchecked Sendable, CustomTestStringConvertible {
        var testDescription: String {
            "private parent-owned migration resources"
        }
        let configuration: Configuration
        let xml: URL
        let typed: URL
        let coverage: URL
        private var rootOwned = false
        init(mode: Mode) {
            let nonce = UUID()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("bleat-migration-\(nonce.uuidString)")
            configuration = Configuration(
                nonce: nonce, root: root,
                dataDomain: "bleat-migration-data-\(nonce.uuidString)",
                configurationDomain:
                    "bleat-migration-config-\(nonce.uuidString)", mode: mode)
            xml = root.appendingPathComponent("child.xml")
            typed = root.appendingPathComponent("result.json")
            // Preserve the owning host gate's product prefix and merge glob, but
            // give each child a nonce/PID profile outside the removed fixture root.
            if let inherited = ProcessInfo.processInfo.environment[
                "LLVM_PROFILE_FILE"],
                inherited.contains("%p"), inherited.hasPrefix("/"),
                !inherited.hasPrefix(root.path + "/")
            {
                coverage = URL(
                    fileURLWithPath: inherited.replacingOccurrences(
                        of: "%p", with: "migration-\(nonce.uuidString)-%p"))
            } else {
                coverage = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "bleat-migration-coverage-\(nonce.uuidString)-%p.profraw"
                    )
            }

        }
        func prepare() throws {
            try FileManager.default.createDirectory(
                at: configuration.root, withIntermediateDirectories: false)
            rootOwned = true
            for name in domains {
                guard let defaults = UserDefaults(suiteName: name) else {
                    throw ConfigurationFailure.preferences
                }
                defaults.set(
                    configuration.nonce.uuidString, forKey: "parent-owner")
                guard defaults.synchronize() else {
                    throw ConfigurationFailure.preferences
                }
            }
        }
        var domains: [String] {
            [configuration.dataDomain, configuration.configurationDomain]
        }
        var childPreferencesVisible: Bool {
            domains.allSatisfy {
                guard let observer = UserDefaults(suiteName: $0),
                    observer.synchronize()
                else { return false }
                return observer.string(forKey: "child-observed")
                    == configuration.nonce.uuidString
            }
        }
        var domainsAbsent: Bool {
            domains.allSatisfy {
                guard let observer = UserDefaults(suiteName: $0),
                    observer.synchronize()
                else { return false }
                return observer.persistentDomain(forName: $0) == nil
            }
        }
        func cleanup(removeFirst: Bool = false) -> [CleanupFailure] {
            var failures: [CleanupFailure] = []
            guard rootOwned else { return failures }
            if removeFirst {
                do {
                    try FileManager.default.removeItem(at: configuration.root)
                } catch { failures.append(.rootRemoval(Native(error))) }
            }
            do {
                try FileManager.default.removeItem(at: configuration.root)
            } catch { failures.append(.rootRemoval(Native(error))) }
            if FileManager.default.fileExists(atPath: configuration.root.path) {
                failures.append(.rootStillPresent)
            }
            for name in domains {
                UserDefaults().removePersistentDomain(forName: name)
                _ = UserDefaults(suiteName: name)?.synchronize()
            }
            if !domainsAbsent { failures.append(.defaultsRemoval) }
            return failures
        }
    }
    struct Result: Sendable, CustomTestStringConvertible {
        var testDescription: String {
            "Migration child: failures=\(failures), cleanup=\(cleanupFailures), state=\(state), readersClosed=\(readersClosed), writersClosed=\(writersClosed), resourcesRemoved=\(resourcesRemoved)"
        }
        let failures: [Failure]
        let cleanupFailures: [CleanupFailure]
        let state: Liveness
        let readersClosed: Bool
        let writersClosed: Bool
        let resourcesRemoved: Bool
        let preferencesVerified: Bool
        let report: Report?
        let resources: Resources?
        let exitProof: ExitProof
        let recovery: @Sendable () -> [CleanupFailure]
        /// Injected lost-notification regressions may recover only through separate
        /// real termination and native descriptor-close proof, never a deadline.
        func recoverPreservedResources() -> [CleanupFailure] { recovery() }
    }

    private enum Event: Sendable {
        case exit(Exit)
        case closed(IO)
        case unconfirmedClose(IO)
        case failed(Failure)
        case cleanup(CleanupFailure)
        case deadline, teardownDeadline, cancelled
        case diagnosticClosed(Int32, Int32)
        case diagnosticDeadline, diagnosticDrainDeadline
    }
    private final class CloseProof: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false
        func record() { lock.withLock { closed = true } }
        var value: Bool { lock.withLock { closed } }
    }
    private final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private var complete = false
        private var closed = false
        private var failed = false
        private let channel: DispatchIO
        private let nativeClose: CloseProof
        init(
            fd: Int32, kind: IO, limit: Int,
            events: AsyncStream<Event>.Continuation,
            suppressCloseEvent: Bool = false,
            injectedCloseError: Int32? = nil
        ) {
            let closeProof = CloseProof()
            nativeClose = closeProof
            let queue = DispatchQueue(
                label: "bleat.migration-child.\(kind.rawValue)")
            channel = DispatchIO(
                type: .stream, fileDescriptor: fd, queue: queue
            ) { @Sendable error in
                let result = Darwin.close(fd)
                let nativeError = error != 0 ? error : (result != 0 ? errno : 0)
                if nativeError == 0 { closeProof.record() }
                let reportedError =
                    nativeError != 0 ? nativeError : (injectedCloseError ?? 0)
                if reportedError != 0 {
                    events.yield(.cleanup(.readerClose(kind, reportedError)))
                } else {
                    events.yield(
                        suppressCloseEvent
                            ? .unconfirmedClose(kind) : .closed(kind))
                }
            }
            channel.setLimit(lowWater: 1)
            channel.setLimit(highWater: 16 * 1024)
            channel.read(offset: 0, length: .max, queue: queue) {
                @Sendable [self] done, data, error in
                let failure: Failure? = lock.withLock {
                    if let data, !failed {
                        if data.count > limit - bytes.count {
                            failed = true
                            return .ioOverflow(kind)
                        }
                        bytes.append(contentsOf: data)
                    }
                    if error != 0, !failed {
                        failed = true
                        return .ioRead(kind, error)
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
        var snapshot:
            (data: Data, complete: Bool, closed: Bool, nativeClosed: Bool)
        {
            lock.withLock { (bytes, complete, closed, nativeClose.value) }
        }
    }

    static func run(options: Options = Options()) async -> Result {
        let events = AsyncStream<Event>.makeStream(
            bufferingPolicy: .bufferingOldest(32))
        let cancellation = Cancellation(Task.isCancelled)
        let supervisor = Task.detached {
            await supervise(
                options: options, cancellation: cancellation, events: events)
        }
        return await withTaskCancellationHandler {
            await supervisor.value
        } onCancel: {
            cancellation.cancel()
            events.continuation.yield(.cancelled)
        }
    }

    private static func supervise(
        options: Options, cancellation: Cancellation,
        events: (
            stream: AsyncStream<Event>,
            continuation: AsyncStream<Event>.Continuation
        )
    ) async -> Result {
        let began = ContinuousClock.now
        let deadline = began.advanced(by: options.timeout)
        let timer = Task.detached {
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch { return }
            events.continuation.yield(.deadline)
        }
        let process = Process()
        let proof = ExitProof()
        proof.retain(process)
        process.terminationHandler = { @Sendable child in
            let reason: ExitReason
            switch child.terminationReason {
            case .exit: reason = .normal
            case .uncaughtSignal: reason = .signal
            @unknown default: reason = .unknown
            }
            let exit = Exit(reason: reason, status: child.terminationStatus)
            proof.record(exit)
            if !options.suppressExitEvent {
                events.continuation.yield(.exit(exit))
            }
        }
        var state: Liveness = .notLaunched
        var failures: [Failure] = []
        var cleanup: [CleanupFailure] = []
        var resources: Resources?
        var readers: [IO: Reader] = [:]
        var writer: FileHandle?
        var writersClosed = true
        var teardown: Task<Void, Never>?
        var report: Report?
        var unconfirmedClose: Set<IO> = []
        var diagnosticState: DiagnosticState?
        func fail(_ value: Failure) {
            if !failures.contains(value) && failures.count < 16 {
                failures.append(value)
            }
        }
        func closeWriter() {
            do {
                try writer?.close()
                writersClosed = true
            } catch {
                cleanup.append(.writerClose(Native(error)))
            }
        }
        if cancellation.value { fail(.cancelled) }
        if failures.isEmpty {
            do {
                resources = Resources(mode: options.mode)
                guard let owned = resources else {
                    throw ConfigurationFailure.identity
                }
                try owned.prepare()
                var descriptors: [Int32] = [-1, -1]
                guard Darwin.pipe(&descriptors) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                readers[.output] = Reader(
                    fd: descriptors[0], kind: .output, limit: outputLimit,
                    events: events.continuation,
                    suppressCloseEvent: options.suppressOutputCloseEvent)
                writer = FileHandle(
                    fileDescriptor: descriptors[1], closeOnDealloc: true)
                writersClosed = false
                if options.failSetupAfterPipe {
                    throw ConfigurationFailure.identity
                }
                process.executableURL =
                    options.executable
                    ?? URL(fileURLWithPath: CommandLine.arguments[0])
                // Build a fresh argument vector: inherit only required signed bundle/library arguments.
                var arguments: [String] = []
                if let i = CommandLine.arguments.firstIndex(
                    of: "--test-bundle-path"),
                    CommandLine.arguments.indices.contains(i + 1)
                {
                    arguments += [
                        "--test-bundle-path", CommandLine.arguments[i + 1],
                        "--testing-library", "swift-testing",
                    ]
                }
                let selection =
                    options.mode == .zeroSelection
                    ? "NoSuchMigrationChildIdentity" : "\(suite).\(name)"
                let xml =
                    options.reportFault == .missingXML
                    ? owned.configuration.root.appendingPathComponent(
                        "unused.xml") : owned.xml
                arguments += [
                    "--no-parallel", "--filter", selection, "--xunit-output",
                    xml.path,
                ]
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                var configuration = owned.configuration
                if options.mode == .invalidVersion { configuration.version = 0 }
                environment[environmentKey] =
                    options.mode == .partialMarker
                    ? "{}"
                    : String(
                        decoding: try JSONEncoder().encode(configuration),
                        as: UTF8.self)
                environment["LLVM_PROFILE_FILE"] = owned.coverage.path
                process.environment = environment
                process.standardOutput = writer
                process.standardError = writer
                await options.hook(.beforeLaunch)
                if cancellation.value { fail(.cancelled) }
                if ContinuousClock.now >= deadline { fail(.deadline) }
                if failures.isEmpty {
                    // This injected control latches cancellation during the launch invocation.
                    // It does not claim Foundation's synchronous run can be interrupted.
                    if options.injectCancellationDuringLaunch {
                        cancellation.cancel()
                    }
                    do {
                        try process.run()
                        state = .running
                        // Process.run failed to launch a child.
                    } catch { fail(.launch(Native(error))) }
                    await options.hook(.afterLaunch)
                }
            } catch { fail(.setup(Native(error))) }
        }
        closeWriter()
        if state == .notLaunched { readers[.output]?.stop() }
        if cancellation.value { fail(.cancelled) }
        if ContinuousClock.now >= deadline { fail(.deadline) }
        for failure in failures { events.continuation.yield(.failed(failure)) }
        if readers.isEmpty { events.continuation.yield(.closed(.output)) }

        for await event in events.stream {
            switch event {
            case .diagnosticClosed, .diagnosticDeadline,
                .diagnosticDrainDeadline:
                // Only the post-exit diagnostic phase consumes these events.
                break
            case .exit(let exit):
                state = .exited(exit)
                if exit.reason == .signal {
                    fail(.signal(exit.status))
                } else if exit.reason != .normal {
                    fail(.unknownTermination)
                } else if exit.status != 0 {
                    fail(.exitStatus(exit.status))
                }
                // Always inspect fresh bounded reports after exit, including nonzero exits.
                if let owned = resources {
                    for (kind, url, limit) in [
                        (IO.xml, owned.xml, xmlLimit),
                        (.typed, owned.typed, typedLimit),
                    ] {
                        let fd = Darwin.open(
                            url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
                        if fd < 0 {
                            if errno == ENOENT {
                                fail(
                                    kind == .xml
                                        ? .xml(.incomplete) : .typed(.missing))
                            } else {
                                fail(.ioRead(kind, errno))
                            }
                        } else {
                            readers[kind] = Reader(
                                fd: fd, kind: kind, limit: limit,
                                events: events.continuation,
                                injectedCloseError: kind == .xml
                                    && options.injectXMLCloseError ? EBADF : nil
                            )
                        }
                    }
                }
            case .closed(let kind): readers[kind]?.markClosed()
            case .unconfirmedClose(let kind): unconfirmedClose.insert(kind)
            case .failed(let value): fail(value)
            case .cleanup(let value):
                if cleanup.count < 16 { cleanup.append(value) }
            case .deadline: fail(.deadline)
            case .cancelled: fail(.cancelled)
            case .teardownDeadline:
                for reader in readers.values { reader.stop() }
                if state == .running {
                    state = .uncertain
                    cleanup.append(.exitUnconfirmed)
                }
                if readers.values.contains(where: { !$0.snapshot.closed })
                    || !writersClosed
                {
                    cleanup.append(.ioUnconfirmed)
                }
            }
            if cancellation.value { fail(.cancelled) }
            if case .exited = state {
                for kind in unconfirmedClose { fail(.ioIncomplete(kind)) }
            }
            if !failures.isEmpty || !cleanup.isEmpty, teardown == nil {
                // isRunning gates a kill only; it NEVER authorizes cleanup.
                if state == .running, process.isRunning {
                    if Darwin.kill(process.processIdentifier, SIGKILL) != 0
                        && errno != ESRCH
                    {
                        cleanup.append(.kill(errno))
                    }
                }
                // Do not discard post-exit reports merely because the caller cancelled.
                if state == .running || state == .notLaunched {
                    for reader in readers.values { reader.stop() }
                }
                teardown = Task.detached {
                    do {
                        try await Task.sleep(for: options.teardownTimeout)
                    } catch { return }
                    events.continuation.yield(.teardownDeadline)
                }
                await options.hook(.teardown)
            }
            if case .teardownDeadline = event { break }
            if state.permitsCleanup
                && readers.values.allSatisfy({ $0.snapshot.closed })
                && writersClosed
            {
                break
            }
        }
        await options.hook(.beforeValidation)
        if cancellation.value { fail(.cancelled) }
        if ContinuousClock.now >= deadline { fail(.deadline) }
        if case .exited = state {
            if let reader = readers[.output], !reader.snapshot.complete {
                fail(.ioIncomplete(.output))
            }
            if let reader = readers[.xml] {
                if !reader.snapshot.complete {
                    fail(.ioIncomplete(.xml))
                } else {
                    var data = reader.snapshot.data
                    switch options.reportFault {
                    case .malformedXML: data = Data("<testsuites>".utf8)
                    case .duplicateXML: data = Data(duplicateReport.utf8)
                    case .oversizedXML:
                        data = Data(repeating: 32, count: xmlLimit + 1)
                    case .none, .missingXML: break
                    }
                    if let rejected = reportFailure(data) {
                        fail(.xml(rejected))
                    }
                }
            }
            if let reader = readers[.typed], let owned = resources {
                if !reader.snapshot.complete {
                    fail(.ioIncomplete(.typed))
                } else {
                    let bytes = reader.snapshot.data
                    if bytes.count > typedLimit {
                        fail(.typed(.malformed))
                    } else if validReportShape(bytes),
                        let value = try? JSONDecoder().decode(
                            Report.self, from: bytes)
                    {
                        if value.scenario.utf8.count > 64
                            || value.native.map({
                                $0.domain.utf8.count > 128
                                    || $0.domain.contains("/")
                            }) == true || !(0...16).contains(value.knownIssues)
                        {
                            fail(.typed(.malformed))
                        } else {
                            report = value
                        }
                        if value.version != 1 { fail(.typed(.version)) }
                        if value.nonce != owned.configuration.nonce {
                            fail(.typed(.nonce))
                        }
                        if value.scenario != "read-only-migration" {
                            fail(.typed(.scenario))
                        }
                        if value.mode != options.mode { fail(.typed(.mode)) }
                        if value.knownIssues != 0 { fail(.typed(.knownIssue)) }
                        if value.cause != .metadataWriteFailed {
                            fail(.childReported(value.cause))
                        } else if value.stage != .verifyPersistence
                            || value.native?.domain != NSCocoaErrorDomain
                            || value.native?.code
                                != NSFileWriteNoPermissionError
                            || value.archiveEqual != true
                            || value.migrationComplete != false
                        {
                            fail(.typed(.outcome))
                        }
                        if !value.preferencesVisible {
                            fail(.typed(.preferences))
                        }
                    } else {
                        fail(.typed(.malformed))
                    }
                }
            }
        }
        let pipeWriterClosed = writersClosed
        if options.mode == .migration, !failures.isEmpty, !cancellation.value,
            let owned = resources
        {
            let diagnostic = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "bleat-migration-diagnostic-\(owned.configuration.nonce.uuidString).log"
                )
            let outcome = await writeDiagnostic(
                readers[.output]?.snapshot.data ?? Data(), to: diagnostic,
                options: options, operationDeadline: deadline,
                cancellation: cancellation, events: events)
            diagnosticState = outcome.state
            writersClosed = writersClosed && outcome.closed
            cleanup += outcome.failures
        }
        let preferences = resources?.childPreferencesVisible ?? false
        if failures.isEmpty && !preferences { fail(.typed(.preferences)) }
        await options.hook(.beforeCleanup)
        if cancellation.value { fail(.cancelled) }
        let readersClosed = readers.values.allSatisfy { $0.snapshot.closed }
        let safe = state.permitsCleanup && readersClosed && writersClosed
        if safe, let owned = resources {
            cleanup += owned.cleanup(removeFirst: options.removeRootFirst)
        } else if resources != nil {
            if !state.permitsCleanup && !cleanup.contains(.exitUnconfirmed) {
                cleanup.append(.exitUnconfirmed)
            }
            if (!readersClosed || !writersClosed)
                && !cleanup.contains(.ioUnconfirmed)
            {
                cleanup.append(.ioUnconfirmed)
            }
        }
        timer.cancel()
        teardown?.cancel()
        await timer.value
        await teardown?.value
        events.continuation.finish()
        if state.permitsCleanup {
            process.terminationHandler = nil
            proof.release()
        }
        // If exit is unconfirmed, proof retains the native observer until its real callback.
        let recoveryReaders = Array(readers.values)
        let recoveryResources = resources
        let writerProof = pipeWriterClosed
        let diagnosticProof = diagnosticState
        let recover: @Sendable () -> [CleanupFailure] = {
            guard proof.value != nil else { return [.exitUnconfirmed] }
            guard
                writerProof && (diagnosticProof?.nativeClosed ?? true)
                    && recoveryReaders.allSatisfy({ $0.snapshot.nativeClosed })
            else { return [.ioUnconfirmed] }
            return recoveryResources?.cleanup() ?? []
        }
        return Result(
            failures: failures, cleanupFailures: cleanup, state: state,
            readersClosed: readersClosed, writersClosed: writersClosed,
            resourcesRemoved: resources.map {
                !FileManager.default.fileExists(
                    atPath: $0.configuration.root.path) && $0.domainsAbsent
            } ?? true,
            preferencesVerified: preferences, report: report,
            resources: resources, exitProof: proof, recovery: recover)
    }

    /// Owns the descriptor and channel until the native cleanup callback, even
    /// if bounded supervision returns without a close acknowledgment.
    private final class DiagnosticState: @unchecked Sendable {
        private let lock = NSLock()
        private var owner: DispatchIO?
        private var writeError: Int32 = 0
        private var closed = false
        let descriptor: Int32
        init(descriptor: Int32) { self.descriptor = descriptor }
        func retain(_ channel: DispatchIO) { lock.withLock { owner = channel } }
        func stop() { lock.withLock { owner }?.close(flags: .stop) }
        func recordWrite(_ error: Int32) {
            lock.withLock { if writeError == 0 { writeError = error } }
        }
        func recordClose(_ error: Int32) -> Int32 {
            lock.withLock {
                closed = error == 0
                owner = nil
                return writeError
            }
        }
        var nativeClosed: Bool { lock.withLock { closed } }
    }
    private struct DiagnosticOutcome {
        var state: DiagnosticState?
        var closed: Bool
        var failures: [CleanupFailure]
    }
    private static func writeDiagnostic(
        _ data: Data, to url: URL, options: Options,
        operationDeadline: ContinuousClock.Instant, cancellation: Cancellation,
        events: (
            stream: AsyncStream<Event>,
            continuation: AsyncStream<Event>.Continuation
        )
    ) async -> DiagnosticOutcome {
        let deadline = min(
            operationDeadline,
            ContinuousClock.now.advanced(by: options.diagnosticTimeout))
        let timer = Task.detached {
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch { return }
            events.continuation.yield(.diagnosticDeadline)
        }
        let fd = Darwin.open(
            url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            let native = Native(
                NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
            timer.cancel()
            await timer.value
            return DiagnosticOutcome(
                closed: true, failures: [.diagnosticWrite(native)])
        }
        let state = DiagnosticState(descriptor: fd)
        let queue = DispatchQueue(
            label: "bleat.migration-child.diagnostic-writer")
        let channel = DispatchIO(
            type: .random, fileDescriptor: fd, queue: queue
        ) { error in
            state.recordWrite(error)
            let closeError: Int32 = Darwin.close(fd) == 0 ? 0 : errno
            let writeError = state.recordClose(closeError)
            if options.diagnosticFault
                != .stallCompletionAndLoseCloseAcknowledgment
            {
                events.continuation.yield(
                    .diagnosticClosed(writeError, closeError))
            }
        }
        state.retain(channel)
        let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: bytes, queue: queue) { done, _, error in
            state.recordWrite(error)
            // Inject loss of the write-completion action. Native stop/close is
            // still real; this does not claim a physical filesystem stall.
            if done, options.diagnosticFault == .none { channel.close() }
        }
        var failures: [CleanupFailure] = []
        var drain: Task<Void, Never>?
        var acknowledged = false
        func stop(_ reason: CleanupFailure) {
            if !failures.contains(reason) { failures.append(reason) }
            guard drain == nil else { return }
            state.stop()
            drain = Task.detached {
                do {
                    try await Task.sleep(for: options.diagnosticDrainTimeout)
                } catch { return }
                events.continuation.yield(.diagnosticDrainDeadline)
            }
        }
        if cancellation.value { stop(.diagnosticCancelled) }
        if ContinuousClock.now >= deadline { stop(.diagnosticDeadline) }
        diagnosticEvents: for await event in events.stream {
            switch event {
            case .diagnosticClosed(let writeError, let closeError):
                acknowledged = closeError == 0
                if writeError != 0 {
                    failures.append(
                        .diagnosticWrite(
                            Native(
                                NSError(
                                    domain: NSPOSIXErrorDomain,
                                    code: Int(writeError)))))
                }
                if closeError != 0 {
                    failures.append(
                        .diagnosticClose(
                            Native(
                                NSError(
                                    domain: NSPOSIXErrorDomain,
                                    code: Int(closeError)))))
                }
                break diagnosticEvents
            case .cancelled: stop(.diagnosticCancelled)
            case .deadline, .diagnosticDeadline: stop(.diagnosticDeadline)
            case .diagnosticDrainDeadline: break diagnosticEvents
            default: break
            }
            if cancellation.value { stop(.diagnosticCancelled) }
        }
        if !acknowledged { failures.append(.diagnosticUnconfirmed) }
        timer.cancel()
        drain?.cancel()
        await timer.value
        await drain?.value
        return DiagnosticOutcome(
            state: state, closed: acknowledged, failures: failures)
    }

    private final class WriteStatus: @unchecked Sendable {
        let lock = NSLock()
        var error: Int32 = 0
        func set(_ value: Int32) {
            lock.withLock { if error == 0 { error = value } }
        }
        var value: Int32 { lock.withLock { error } }
    }
    private static func writeChildReport(_ data: Data, to url: URL) async throws
    {
        let fd = Darwin.open(
            url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let code: Int32 = await withCheckedContinuation { continuation in
            let status = WriteStatus()
            let queue = DispatchQueue(
                label: "bleat.migration-child.report-writer")
            let channel = DispatchIO(
                type: .random, fileDescriptor: fd, queue: queue
            ) { error in
                status.set(error)
                if Darwin.close(fd) != 0 { status.set(errno) }
                continuation.resume(returning: status.value)
            }
            let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
            channel.write(offset: 0, data: bytes, queue: queue) {
                done, _, error in
                status.set(error)
                if done { channel.close() }
            }
        }
        guard code == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    /// Only the deliberately skipped helper control is disabled. Normal discovery stays enabled.
    static var shouldRun: Bool {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey],
            let data = raw.data(using: .utf8),
            let value = try? JSONDecoder().decode(
                Configuration.self, from: data)
        else { return true }
        return value.version != 1 || value.mode != .skip
    }

    static func perform(raw: String) async throws {
        guard raw.utf8.count <= 4096, let data = raw.data(using: .utf8),
            let c = try? JSONDecoder().decode(Configuration.self, from: data)
        else { throw ConfigurationFailure.malformed }
        guard c.version == 1 else { throw ConfigurationFailure.version }
        let expectedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bleat-migration-\(c.nonce.uuidString)")
            .standardizedFileURL.resolvingSymlinksInPath()
        let canonicalRoot = c.root.standardizedFileURL.resolvingSymlinksInPath()
        guard
            c.root.isFileURL, canonicalRoot.path == expectedRoot.path,
            c.dataDomain == "bleat-migration-data-\(c.nonce.uuidString)",
            c.configurationDomain
                == "bleat-migration-config-\(c.nonce.uuidString)",
            FileManager.default.fileExists(atPath: expectedRoot.path)
        else { throw ConfigurationFailure.identity }
        let visible: Bool
        do {
            let dataObserver = try #require(
                UserDefaults(suiteName: c.dataDomain))
            let configurationObserver = try #require(
                UserDefaults(suiteName: c.configurationDomain))
            visible =
                dataObserver.string(forKey: "parent-owner")
                == c.nonce.uuidString
                && configurationObserver.string(forKey: "parent-owner")
                    == c.nonce.uuidString
            guard visible else { throw ConfigurationFailure.preferences }
            for observer in [dataObserver, configurationObserver] {
                observer.set(c.nonce.uuidString, forKey: "child-observed")
                guard observer.synchronize() else {
                    throw ConfigurationFailure.preferences
                }
            }
        }
        let defaults = try #require(UserDefaults(suiteName: c.dataDomain))
        var report = Report(
            nonce: c.nonce, mode: c.mode, stage: .control,
            cause: .unexpectedSuccess, preferencesVisible: visible)
        let destination = c.root.appendingPathComponent("result.json")
        if c.mode == .hang {
            await withUnsafeContinuation {
                (_: UnsafeContinuation<Void, Never>) in
            }
            return
        }
        if c.mode == .signal {
            Darwin.kill(getpid(), SIGKILL)
            return
        }
        if c.mode == .thrown {
            report.cause = .injectedThrow
            try await writeChildReport(
                try JSONEncoder().encode(report), to: destination)
            throw InjectedError.thrown
        }
        if c.mode == .flood {
            print(String(repeating: "x", count: outputLimit * 2))
        }
        if c.mode == .oversizedXML {
            report.cause = .injectedAssertion
            Issue.record(
                Comment(rawValue: String(repeating: "x", count: xmlLimit * 2)))
        } else if c.mode == .assertion {
            report.cause = .injectedAssertion
            #expect(Bool(false), "Injected migration-child assertion")
        } else if c.mode == .knownIssue {
            let count = WriteStatus()
            withKnownIssue("Injected migration-child known issue") {
                Issue.record(InjectedError.knownIssue)
            } matching: { issue in
                guard issue.error as? InjectedError == .knownIssue else {
                    return false
                }
                count.set(1)
                return true
            }
            report.cause = .injectedKnownIssue
            report.knownIssues = Int(count.value)
        } else {
            let schema = Schema(BleatPersistenceModelCatalog.allModelTypes)
            let storeURL = c.root.appendingPathComponent("read-only.store")
            do {
                _ = try ModelContainer(
                    for: schema,
                    configurations: [
                        ModelConfiguration(
                            schema: schema, url: storeURL,
                            cloudKitDatabase: .none)
                    ])
            }
            let container = try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration(
                        schema: schema, url: storeURL, allowsSave: false,
                        cloudKitDatabase: .none)
                ])
            let record = CKRecord(
                recordType: "ListeningSlice",
                recordID: CKRecord.ID(
                    recordName: "retained",
                    zoneID: CKRecordZone.ID(
                        zoneName: "test", ownerName: CKCurrentUserDefaultName)))
            let archive = PrivateCloudPersistence.encodeSystemFields(record)
            defaults.set(
                ["retained": archive],
                forKey: PrivateCloudPersistence.metadataKey)
            let store = PrivateCloudSyncStore(
                statistics: StatisticsRepository(modelContainer: container),
                accounts: AccountStore(modelContainer: container),
                credentialStore: nil,
                configuration: CloudConfigurationStore(
                    defaults: try #require(
                        UserDefaults(suiteName: c.configurationDomain))),
                defaults: PrivateCloudDefaultsReference(defaults))
            report.stage = .prepareStorage
            do {
                try await store.prepareStorage()
                report.cause = .unexpectedSuccess
                Issue.record("Read-only save must fail")
            } catch let error as PrivateCloudSyncError {
                guard case .storage(.metadataWriteFailed(let native)) = error
                else { throw error }
                report.cause = .metadataWriteFailed
                report.native = Native(
                    NSError(domain: native.domain, code: native.code))
                #expect(native.domain == NSCocoaErrorDomain)
                #expect(native.code == NSFileWriteNoPermissionError)
            } catch {
                report.cause = .unexpectedFailure
                report.native = Native(error)
            }
            // Exact opaque archive bytes deliberately verify retained storage fidelity.
            let retained =
                defaults.dictionary(forKey: PrivateCloudPersistence.metadataKey)
                as? [String: Data]
            report.archiveEqual = retained == ["retained": archive]
            report.migrationComplete = try PrivateCloudPersistence(
                container: container
            ).migrationComplete()
            #expect(report.archiveEqual == true)
            #expect(report.migrationComplete == false)
            report.stage = .verifyPersistence
        }
        if c.mode == .missingResult { return }
        if c.mode == .wrongNonce { report.nonce = UUID() }
        let encoded: Data
        if c.mode == .malformedResult {
            encoded = Data("{".utf8)
        } else if c.mode == .oversizedResult {
            encoded = Data(repeating: 32, count: typedLimit + 1)
        } else if c.mode == .duplicateResult {
            let value = try JSONEncoder().encode(report)
            encoded = value + value
        } else {
            encoded = try JSONEncoder().encode(report)
        }
        try await writeChildReport(encoded, to: destination)
    }

    static func validReportShape(_ data: Data) -> Bool {
        guard data.count <= typedLimit else { return false }
        let bytes = Array(data)
        let fields: Set<String> = [
            "version", "nonce", "scenario", "mode", "stage", "cause", "native",
            "archiveEqual", "migrationComplete", "preferencesVisible",
            "knownIssues",
        ]
        struct Object {
            var keys: Set<String> = []
            var keyExpected = true
            var lastKey: String?
        }
        var objects: [Object] = []
        var rootSeen = false
        var i = 0
        while i < bytes.count {
            switch bytes[i] {
            case 123:
                if objects.isEmpty {
                    guard !rootSeen else { return false }
                    rootSeen = true
                }
                guard objects.count < 2 else { return false }
                if let parent = objects.last, parent.lastKey != "native" {
                    return false
                }
                objects.append(Object())
            case 125:
                guard !objects.isEmpty else { return false }
                objects.removeLast()
            case 91, 93: return false
            case 44:
                guard !objects.isEmpty else { return false }
                objects[objects.count - 1].keyExpected = true
            case 58:
                guard !objects.isEmpty else { return false }
                objects[objects.count - 1].keyExpected = false
            case 34:
                let start = i
                i += 1
                var escaped = false
                while i < bytes.count {
                    if !escaped && bytes[i] == 34 { break }
                    if !escaped && bytes[i] == 92 {
                        escaped = true
                    } else {
                        escaped = false
                    }
                    i += 1
                    guard i - start <= 256 else { return false }
                }
                guard i < bytes.count, !objects.isEmpty else { return false }
                if objects[objects.count - 1].keyExpected {
                    guard
                        let key = try? JSONDecoder().decode(
                            String.self, from: Data(bytes[start...i]))
                    else { return false }
                    let allowed =
                        objects.count == 1 ? fields : ["domain", "code"]
                    guard allowed.contains(key),
                        objects[objects.count - 1].keys.insert(key).inserted
                    else { return false }
                    objects[objects.count - 1].lastKey = key
                }
            default: break
            }
            i += 1
        }
        return rootSeen && objects.isEmpty
    }

    private static var duplicateReport: String {
        let test =
            "<testcase classname=\"\(suite)\" name=\"\(name)\" time=\"0\"/>"
        return
            "<testsuites><testsuite tests=\"1\" failures=\"0\" errors=\"0\" skipped=\"0\">\(test)\(test)</testsuite></testsuites>"
    }
    enum ReportFailure: String, Sendable {
        case malformed, summary, missingIdentity, duplicateIdentity
        case unexpectedIdentity, skipped, failed, unknownOutcome, incomplete
    }

    static func reportFailure(_ data: Data) -> ReportFailure? {
        guard data.count <= xmlLimit, !data.contains(0),
            String(data: data, encoding: .utf8) != nil,
            data.range(of: Data("<!DOCTYPE".utf8)) == nil,
            data.range(of: Data("<!ENTITY".utf8)) == nil
        else { return .malformed }
        let delegate = ReportParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { return .malformed }
        if delegate.cases == 0, delegate.suites == 1, delegate.rootClosed,
            delegate.failure == .summary
        {
            return .missingIdentity
        }
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
            if failure == nil
                || (failure == .summary
                    && (cause == .failed || cause == .skipped))
            {
                failure = cause
            }
        }

        func parser(
            _ parser: XMLParser, didStartElement name: String,
            namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            guard stack.count < 8, attributes.count <= 8,
                attributes.values.allSatisfy({ $0.utf8.count <= 1024 })
            else {
                reject(.malformed)
                parser.abortParsing()
                return
            }
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
                    || attributes["name"] != ReadOnlyMigrationChild.name
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
