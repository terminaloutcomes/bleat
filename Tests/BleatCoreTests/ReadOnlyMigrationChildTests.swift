import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct ReadOnlyMigrationChildTests {
    @Test(arguments: [
        ReadOnlyMigrationChild.Mode.migration, .assertion, .thrown, .skip,
        .knownIssue, .zeroSelection, .signal, .missingResult, .malformedResult,
        .oversizedResult, .wrongNonce, .invalidVersion, .partialMarker, .flood,
        .oversizedXML, .duplicateResult,
    ])
    func actualHelperContracts(mode: ReadOnlyMigrationChild.Mode) async throws {
        let streams = streamIdentities()
        let unrelated = ReadOnlyMigrationChild.Resources(mode: .migration)
        try unrelated.prepare()
        defer { #expect(unrelated.cleanup().isEmpty) }
        var options = ReadOnlyMigrationChild.Options()
        options.mode = mode
        let result = await ReadOnlyMigrationChild.run(options: options)
        expectClean(result)
        #expect(streamIdentities() == streams)
        let unrelatedRootExists = FileManager.default.fileExists(
            atPath: unrelated.configuration.root.path)
        let unrelatedDomainsPreserved = unrelated.domains.allSatisfy {
            UserDefaults(suiteName: $0)?.string(forKey: "parent-owner")
                == unrelated.configuration.nonce.uuidString
        }
        #expect(unrelatedRootExists)
        #expect(unrelatedDomainsPreserved)
        switch mode {
        case .migration:
            #expect(result.failures.isEmpty)
            #expect(result.preferencesVerified)
            #expect(result.report?.archiveEqual == true)
            #expect(result.report?.migrationComplete == false)
            let owned = try #require(result.resources)
            let profileOutsideFixture = !owned.coverage.path.hasPrefix(
                owned.configuration.root.path + "/")
            #expect(profileOutsideFixture)
            #expect(
                owned.coverage.path.contains(
                    owned.configuration.nonce.uuidString))
        case .assertion:
            #expect(result.failures.contains(.xml(.failed)))
            #expect(
                result.failures.contains(.childReported(.injectedAssertion)))
        case .thrown:
            #expect(result.failures.contains(.xml(.failed)))
            #expect(result.failures.contains(.childReported(.injectedThrow)))
        case .skip:
            #expect(result.failures.contains(.xml(.skipped)))
        case .knownIssue:
            // Actual runner XML may encode a known issue as a pass: the typed
            // count comes from the actual withKnownIssue matcher, not a constant.
            #expect(result.report?.knownIssues == 1)
            #expect(result.failures.contains(.typed(.knownIssue)))
            #expect(
                !result.failures.contains {
                    if case .xml = $0 { true } else { false }
                })
            #expect(result.state == .exited(.init(reason: .normal, status: 0)))
        case .zeroSelection:
            #expect(result.failures.contains(.xml(.missingIdentity)))
        case .signal:
            #expect(result.failures.contains(.signal(SIGKILL)))
        case .missingResult:
            #expect(result.failures.contains(.typed(.missing)))
        case .malformedResult, .duplicateResult:
            #expect(result.failures.contains(.typed(.malformed)))
        case .oversizedResult:
            #expect(result.failures.contains(.ioOverflow(.typed)))
        case .wrongNonce:
            #expect(result.failures.contains(.typed(.nonce)))
        case .invalidVersion, .partialMarker:
            #expect(result.failures.contains(.xml(.failed)))
            #expect(result.report == nil)
        case .flood:
            #expect(result.failures.contains(.ioOverflow(.output)))
        case .oversizedXML:
            #expect(result.failures.contains(.ioOverflow(.xml)))
        case .hang:
            Issue.record("Hang control requires a deliberate deadline")
        }
        if mode != .migration { #expect(!result.failures.isEmpty) }
    }

    @Test(arguments: [
        ReadOnlyMigrationChild.ReportFault.missingXML, .malformedXML,
        .duplicateXML, .oversizedXML,
    ])
    func injectedReportFaultsCannotPass(
        fault: ReadOnlyMigrationChild.ReportFault
    ) async {
        var options = ReadOnlyMigrationChild.Options()
        options.reportFault = fault
        let result = await ReadOnlyMigrationChild.run(options: options)
        expectClean(result)
        let expected: ReadOnlyMigrationChild.ReportFailure
        switch fault {
        case .missingXML: expected = .incomplete
        case .malformedXML, .oversizedXML: expected = .malformed
        case .duplicateXML: expected = .duplicateIdentity
        case .none:
            Issue.record("Fault selection was empty")
            return
        }
        #expect(result.failures.contains(.xml(expected)))
        #expect(result.report?.archiveEqual == true)
        #expect(result.report?.migrationComplete == false)
        #expect(result.state == .exited(.init(reason: .normal, status: 0)))
    }

    @Test func launchFailureClosesOwnedHandles() async {
        var options = ReadOnlyMigrationChild.Options()
        options.executable = URL(
            fileURLWithPath: "/does-not-exist-migration-helper")
        let streams = streamIdentities()
        let result = await ReadOnlyMigrationChild.run(options: options)
        #expect(result.state == .notLaunched)
        #expect(
            result.failures.contains {
                if case .launch = $0 { true } else { false }
            })
        expectClean(result)
        #expect(streamIdentities() == streams)
    }

    @Test func partialSetupClosesBothPipeEnds() async {
        var options = ReadOnlyMigrationChild.Options()
        options.failSetupAfterPipe = true
        let result = await ReadOnlyMigrationChild.run(options: options)
        #expect(result.state == .notLaunched)
        #expect(
            result.failures.contains {
                if case .setup = $0 { true } else { false }
            })
        expectClean(result)
    }

    @Test func deadlineReapsBeforeCleanup() async {
        var options = ReadOnlyMigrationChild.Options()
        options.mode = .hang
        // Deliberately short supervision deadline; not migration readiness evidence.
        options.timeout = .milliseconds(300)
        let result = await ReadOnlyMigrationChild.run(options: options)
        #expect(result.failures.contains(.deadline))
        expectClean(result)
        guard case .exited(let exit) = result.state else {
            Issue.record("Exit was not observed")
            return
        }
        #expect(exit.reason == .signal)
    }

    @Test func alreadyCancelledDoesNotLaunch() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ReadOnlyMigrationChild.run()
        }
        let result = await task.value
        #expect(result.state == .notLaunched)
        #expect(result.failures == [.cancelled])
        #expect(result.resources == nil)
        expectClean(result)
    }

    @Test func injectedLaunchCancellationIsLatched() async {
        var options = ReadOnlyMigrationChild.Options()
        options.mode = .hang
        options.injectCancellationDuringLaunch = true
        let result = await ReadOnlyMigrationChild.run(options: options)
        #expect(result.failures.contains(.cancelled))
        expectClean(result)
        #expect(
            result.state == .exited(.init(reason: .signal, status: SIGKILL)))
    }

    @Test(arguments: [
        ReadOnlyMigrationChild.Phase.beforeLaunch, .afterLaunch,
        .beforeValidation, .teardown, .beforeCleanup,
    ])
    func cancellationAcrossPhasesIsDrained(phase: ReadOnlyMigrationChild.Phase)
        async
    {
        let gate = PhaseGate(phase)
        var options = ReadOnlyMigrationChild.Options()
        if phase == .afterLaunch || phase == .teardown { options.mode = .hang }
        if phase == .teardown { options.timeout = .milliseconds(300) }
        options.hook = { await gate.enter($0) }
        let task = Task { await ReadOnlyMigrationChild.run(options: options) }
        let entered = await gate.entered.wait(
            untilAtLeast: 1, timeout: .seconds(10))
        task.cancel()
        await gate.release.increment()
        let result = await task.value
        #expect(entered.reached)
        #expect(result.failures.contains(.cancelled))
        expectClean(result)
        switch phase {
        case .beforeLaunch:
            #expect(result.state == .notLaunched)
            #expect(result.exitProof.value == nil)
        case .afterLaunch, .teardown:
            #expect(
                result.state == .exited(.init(reason: .signal, status: SIGKILL))
            )
        case .beforeValidation, .beforeCleanup:
            #expect(result.state == .exited(.init(reason: .normal, status: 0)))
            #expect(result.report?.archiveEqual == true)
            #expect(result.report?.migrationComplete == false)
        }
        if phase == .teardown { #expect(result.failures.contains(.deadline)) }
    }

    @Test func uncertainExitPreservesAllResources() async throws {
        var options = ReadOnlyMigrationChild.Options()
        options.mode = .hang
        options.timeout = .milliseconds(300)
        options.teardownTimeout = .milliseconds(500)
        // Inject a lost supervisor event; the separate native proof still records
        // the real termination. This is not a claim to make SIGKILL fail.
        options.suppressExitEvent = true
        let result = await ReadOnlyMigrationChild.run(options: options)
        #expect(result.state == .uncertain)
        #expect(result.cleanupFailures.contains(.exitUnconfirmed))
        #expect(!result.resourcesRemoved)
        let owned = try #require(result.resources)
        let preservedRootExists = FileManager.default.fileExists(
            atPath: owned.configuration.root.path)
        #expect(preservedRootExists)
        #expect(!owned.domainsAbsent)
        #expect(result.exitProof.value != nil)
        // No recovery is allowed without independent real exit proof and closed IO.
        #expect(result.recoverPreservedResources().isEmpty)
        let recoveredRootAbsent = !FileManager.default.fileExists(
            atPath: owned.configuration.root.path)
        #expect(recoveredRootAbsent)
        #expect(owned.domainsAbsent)
    }

    @Test(arguments: [false, true])
    func uncertainIOPreservesOwnedResources(injectedError: Bool) async throws {
        var options = ReadOnlyMigrationChild.Options()
        // Native close succeeds, but inject loss of its supervisor acknowledgment.
        // No real fd is double-closed and no parent descriptor is touched.
        options.suppressOutputCloseEvent = !injectedError
        options.injectXMLCloseError = injectedError
        options.teardownTimeout = .milliseconds(500)
        let result = await ReadOnlyMigrationChild.run(options: options)
        #expect(result.state == .exited(.init(reason: .normal, status: 0)))
        #expect(result.cleanupFailures.contains(.ioUnconfirmed))
        if injectedError {
            #expect(result.cleanupFailures.contains(.readerClose(.xml, EBADF)))
        }
        #expect(!result.readersClosed)
        #expect(!result.resourcesRemoved)
        #expect(result.report?.archiveEqual == true)
        let owned = try #require(result.resources)
        let rootPreserved = FileManager.default.fileExists(
            atPath: owned.configuration.root.path)
        #expect(rootPreserved)
        #expect(!owned.domainsAbsent)
        #expect(result.recoverPreservedResources().isEmpty)
        let rootRemoved = !FileManager.default.fileExists(
            atPath: owned.configuration.root.path)
        #expect(rootRemoved)
        #expect(owned.domainsAbsent)
    }

    @Test func operationAndCleanupFailuresRemainSeparate() async {
        var options = ReadOnlyMigrationChild.Options()
        options.mode = .thrown
        // Deterministic missing-root injection after reap.
        options.removeRootFirst = true
        let result = await ReadOnlyMigrationChild.run(options: options)
        #expect(result.failures.contains(.childReported(.injectedThrow)))
        #expect(
            result.cleanupFailures.contains {
                if case .rootRemoval(let native) = $0 {
                    native.domain == NSCocoaErrorDomain
                        && native.code == NSFileNoSuchFileError
                } else {
                    false
                }
            })
        #expect(result.readersClosed && result.writersClosed)
        #expect(result.resourcesRemoved)
    }

    @Test(arguments: [false, true])
    func stalledDiagnosticIsStoppedAndClosureIsProven(
        loseCloseAcknowledgment: Bool
    ) async throws {
        let streams = streamIdentities()
        var options = ReadOnlyMigrationChild.Options()
        options.reportFault = .malformedXML
        options.diagnosticTimeout = .milliseconds(100)
        options.diagnosticDrainTimeout = .milliseconds(500)
        options.diagnosticFault =
            loseCloseAcknowledgment
            ? .stallCompletionAndLoseCloseAcknowledgment : .stallCompletion
        let completed = BoundedTestCounter()
        let task = Task {
            let result = await ReadOnlyMigrationChild.run(options: options)
            await completed.increment()
            return result
        }
        let completion = await completed.wait(
            untilAtLeast: 1, timeout: .seconds(30))
        #expect(
            completion.reached, "Stalled diagnostic supervisor did not return")
        guard completion.reached else {
            task.cancel()
            return
        }
        let result = await task.value
        #expect(result.failures.contains(.xml(.malformed)))
        #expect(result.cleanupFailures.contains(.diagnosticDeadline))
        #expect(result.state == .exited(.init(reason: .normal, status: 0)))
        #expect(result.report?.archiveEqual == true)
        #expect(result.report?.migrationComplete == false)
        #expect(result.readersClosed)
        #expect(streamIdentities() == streams)
        let owned = try #require(result.resources)
        if loseCloseAcknowledgment {
            #expect(result.cleanupFailures.contains(.diagnosticUnconfirmed))
            #expect(!result.writersClosed)
            #expect(!result.resourcesRemoved)
            let rootPreserved = FileManager.default.fileExists(
                atPath: owned.configuration.root.path)
            #expect(rootPreserved)
            #expect(!owned.domainsAbsent)
            // Independent native close/exit proof authorizes test-only recovery.
            #expect(result.recoverPreservedResources().isEmpty)
            let rootRemoved = !FileManager.default.fileExists(
                atPath: owned.configuration.root.path)
            #expect(rootRemoved)
            #expect(owned.domainsAbsent)
        } else {
            #expect(!result.cleanupFailures.contains(.diagnosticUnconfirmed))
            #expect(result.writersClosed)
            #expect(result.resourcesRemoved)
            #expect(owned.domainsAbsent)
        }
    }

    @Test func typedReportGrammarRejectsAmbiguousAndUnboundedInput() throws {
        let report = ReadOnlyMigrationChild.Report(
            nonce: UUID(), mode: .migration,
            stage: .verifyPersistence, cause: .metadataWriteFailed,
            native: .init(
                NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileWriteNoPermissionError)),
            archiveEqual: true, migrationComplete: false,
            preferencesVisible: true)
        let bytes = try JSONEncoder().encode(report)
        #expect(ReadOnlyMigrationChild.validReportShape(bytes))
        #expect(
            try JSONDecoder().decode(
                ReadOnlyMigrationChild.Report.self, from: bytes) == report)
        let duplicateKey = Data(
            ("{\"version\":1,"
                + String(decoding: bytes.dropFirst(), as: UTF8.self)).utf8)
        let invalid: [Data] = [
            duplicateKey, bytes + bytes, Data("[]".utf8),
            Data("{\"native\":{\"domain\":{\"nested\":1}}}".utf8),
            Data(
                ("{\"scenario\":\"" + String(repeating: "x", count: 257) + "\"}")
                    .utf8),
            Data(repeating: 32, count: ReadOnlyMigrationChild.typedLimit + 1),
        ]
        for value in invalid {
            #expect(!ReadOnlyMigrationChild.validReportShape(value))
        }
    }

    @Test func xmlGrammarRejectsUntrustedAndAmbiguousReports() {
        let test =
            "<testcase classname=\"\(ReadOnlyMigrationChild.suite)\" name=\"\(ReadOnlyMigrationChild.name)\" time=\"0\"/>"
        let xml =
            "<testsuites><testsuite tests=\"1\" failures=\"0\" errors=\"0\" skipped=\"0\">\(test)</testsuite></testsuites>"
        #expect(ReadOnlyMigrationChild.reportFailure(Data(xml.utf8)) == nil)
        let invalid: [Data] = [
            Data(), Data(xml.dropLast(3).utf8),
            Data(
                ("<!DOCTYPE testsuites [<!ENTITY external SYSTEM 'file:///unrelated'>]>"
                    + xml).utf8),
            Data(
                xml.utf16.flatMap {
                    [
                        UInt8(truncatingIfNeeded: $0),
                        UInt8(truncatingIfNeeded: $0 >> 8),
                    ]
                }),
            Data(repeating: 32, count: ReadOnlyMigrationChild.xmlLimit + 1),
            Data(xml.replacingOccurrences(of: test, with: test + test).utf8),
            Data(
                xml.replacingOccurrences(of: "time=\"0\"", with: "time=\"nan\"")
                    .utf8),
            Data(
                xml.replacingOccurrences(
                    of: "/>", with: " status=\"unknown\"/>"
                ).utf8),
        ]
        for value in invalid {
            #expect(ReadOnlyMigrationChild.reportFailure(value) != nil)
        }
    }

    private actor PhaseGate {
        let phase: ReadOnlyMigrationChild.Phase
        let entered = BoundedTestCounter()
        let release = BoundedTestCounter()
        init(_ phase: ReadOnlyMigrationChild.Phase) { self.phase = phase }
        func enter(_ value: ReadOnlyMigrationChild.Phase) async {
            guard phase == value else { return }
            await entered.increment()
            let result = await release.wait(
                untilAtLeast: 1, timeout: .seconds(10))
            #expect(result.reached)
        }
    }
    private func expectClean(
        _ result: ReadOnlyMigrationChild.Result,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(result.cleanupFailures.isEmpty, sourceLocation: sourceLocation)
        #expect(
            result.readersClosed && result.writersClosed,
            sourceLocation: sourceLocation)
        #expect(result.resourcesRemoved, sourceLocation: sourceLocation)
    }
    private struct StreamIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
    }
    private func streamIdentities() -> [StreamIdentity] {
        [STDOUT_FILENO, STDERR_FILENO].map {
            var value = stat()
            #expect(fstat($0, &value) == 0)
            return StreamIdentity(
                device: value.st_dev, inode: value.st_ino, mode: value.st_mode)
        }
    }
}
