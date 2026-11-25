import Foundation
import Testing

@testable import BleatCore

@Suite struct PrivateCloudGenerationRestoreTests {
    private typealias Restore = PrivateCloudGenerationRestore
    private typealias Entry = PrivateCloudBackup.Entry

    @Test func replacementPreservesLegacyAndIsolatesItsLaterWriter()
        async throws
    {
        let old = try entries(count: 2, title: "Old")
        let desired = try entries(count: 201, title: "Desired")
        let transport = MemoryTransport(initial: old)
        let restore = Restore(transport: transport)
        let source = try backup(desired)
        let preview = try await restore.preview(source)
        #expect(preview.plan.create == 199)
        #expect(preview.plan.replace == 2)
        // Candidate batches are inactive.
        #expect(!preview.plan.fitsSingleOperation)
        guard
            case .published = try await restore.restore(
                source, reviewed: preview)
        else {
            Issue.record("Expected generation publication")
            return
        }
        let active = await transport.readActive()
        #expect(active.pointer.generation != .legacy)
        #expect(try await transport.scan(active.pointer.generation) == desired)
        #expect(try await transport.scan(.legacy) == old)
        #expect(await transport.batchSizes == [100, 100, 1])
        let late = try entries(count: 1, title: "Late old device")
        await transport.writeFromLegacyClient(late)
        #expect(try await transport.scan(.legacy) == late)
        #expect(try await transport.scan(active.pointer.generation) == desired)
        #expect(await transport.publishedCount == 1)
    }

    @Test func recoveryStagesAnEarlierBackupAsAFreshGeneration() async throws {
        let old = try entries(count: 1, title: "Old")
        let new = try entries(count: 2, title: "New")
        let transport = MemoryTransport(initial: old)
        let restore = Restore(transport: transport)
        let first = try backup(new)
        let preview = try await restore.preview(first)
        guard
            case .published = try await restore.restore(
                first, reviewed: preview)
        else {
            Issue.record("Expected first publication")
            return
        }
        let initialSelection = await transport.readActive().pointer
        let previousBackup = try backup(old)
        let rollbackPlan = try await restore.preview(previousBackup)
        #expect(rollbackPlan.plan.remove == 1)
        guard
            case .published = try await restore.restore(
                previousBackup, reviewed: rollbackPlan)
        else {
            Issue.record("Expected fresh-generation rollback publication")
            return
        }
        let next = await transport.readActive().pointer
        #expect(next.generation != .legacy)
        #expect(next.generation != initialSelection.generation)
        #expect(next.revision != initialSelection.revision)
        #expect(try await transport.scan(next.generation) == old)
        #expect(try await transport.scan(initialSelection.generation) == new)
        #expect(try await transport.scan(.legacy) == old)
    }

    @Test func refusesWrongAccountChangedBackupAndStaleReviewedState()
        async throws
    {
        let old = try entries(count: 1, title: "Old")
        let desired = try backup(entries(count: 2, title: "New"))
        let transport = MemoryTransport(initial: old)
        let restore = Restore(transport: transport)
        let preview = try await restore.preview(desired)
        let different = try backup(entries(count: 1, title: "Different"))
        await #expect(throws: Restore.Failure.stalePreview) {
            try await restore.restore(different, reviewed: preview)
        }
        let wrong = try PrivateCloudBackup.capture(
            records: old,
            accountBinding: PrivateCloudBackup.binding(
                container: "Synthetic", cloudUserRecordName: "Wrong"
            )
        )
        await #expect(throws: Restore.Failure.accountMismatch) {
            try await restore.preview(wrong)
        }
        await transport.writeFromFencedActiveClient(old)
        await #expect(throws: Restore.Failure.stalePreview) {
            try await restore.restore(desired, reviewed: preview)
        }
        #expect(await transport.stageCount == 0)
        #expect(await transport.publishAttempts == 0)
    }

    @Test func ordinaryWriteRacingPublishIsRejectedByTransportCAS() async throws
    {
        let old = try entries(count: 1, title: "Old")
        let desired = try backup(entries(count: 2, title: "New"))
        let transport = MemoryTransport(initial: old, fault: .writerAtPublish)
        let restore = Restore(transport: transport)
        let preview = try await restore.preview(desired)
        #expect(
            try await restore.restore(desired, reviewed: preview) == .conflict)
        #expect(await transport.readActive().pointer.generation == .legacy)
        #expect(await transport.publishedCount == 0)
        #expect(await transport.publishAttempts == 1)
        #expect(try await transport.scan(.legacy) == old)
    }

    @Test func changedPointerBeforePublishRefusesReplacement() async throws {
        let old = try entries(count: 1, title: "Old")
        let desired = try backup(entries(count: 2, title: "New"))
        let transport = MemoryTransport(
            initial: old, fault: .selectorAtVerification)
        let restore = Restore(transport: transport)
        let preview = try await restore.preview(desired)
        #expect(
            try await restore.restore(desired, reviewed: preview) == .conflict)
        #expect(await transport.publishAttempts == 0)
        #expect(await transport.publishedCount == 0)
        #expect(try await transport.scan(.legacy) == old)
    }

    @Test func interruptedOrCorruptStageNeverPublishes() async throws {
        let old = try entries(count: 1, title: "Old")
        let wanted = try backup(entries(count: 201, title: "New"))
        let interrupted = MemoryTransport(
            initial: old, fault: .cancelSecondBatch)
        let restore = Restore(transport: interrupted)
        let preview = try await restore.preview(wanted)
        await #expect(throws: CancellationError.self) {
            try await restore.restore(wanted, reviewed: preview)
        }
        #expect(await interrupted.batchSizes == [100])
        #expect(await interrupted.publishAttempts == 0)
        #expect(try await interrupted.scan(.legacy) == old)
        let corrupt = MemoryTransport(initial: old, fault: .corruptStageRead)
        let other = Restore(transport: corrupt)
        let otherPreview = try await other.preview(wanted)
        await #expect(throws: Restore.Failure.verificationFailed) {
            try await other.restore(wanted, reviewed: otherPreview)
        }
        #expect(await corrupt.publishAttempts == 0)
        #expect(await corrupt.readActive().pointer.generation == .legacy)
    }

    @Test func lostCommitResponseUsesReceiptWithoutRetry() async throws {
        let old = try entries(count: 1, title: "Old")
        let desired = try backup(entries(count: 2, title: "New"))
        let transport = MemoryTransport(initial: old, fault: .lostAfterSwitch)
        let restore = Restore(transport: transport)
        let preview = try await restore.preview(desired)
        guard
            case .published(let receipt) = try await restore.restore(
                desired, reviewed: preview)
        else {
            Issue.record("Readback should prove the switch")
            return
        }
        #expect(await restore.resolve(receipt) == .published(receipt))
        #expect(await transport.publishAttempts == 1)
        #expect(await transport.publishedCount == 1)
    }

    @Test
    func
        unknownWithoutPositiveReadbackRemainsPendingEvenIfOldSelectionIsVisible()
        async throws
    {
        let old = try entries(count: 1, title: "Old")
        let desired = try backup(entries(count: 2, title: "New"))
        let transport = MemoryTransport(
            initial: old, fault: .unknownWithLateSwitch)
        let restore = Restore(transport: transport)
        let preview = try await restore.preview(desired)
        guard
            case .indeterminate(let receipt) = try await restore.restore(
                desired, reviewed: preview)
        else {
            Issue.record("Old pointer does not prove no publication")
            return
        }
        #expect(await transport.readActive().pointer.generation == .legacy)
        #expect(await restore.resolve(receipt) == .indeterminate(receipt))
        await #expect(throws: Restore.Failure.publicationPending) {
            try await restore.restore(desired, reviewed: preview)
        }
        #expect(await transport.publishAttempts == 1)
        await transport.deliverLatePublication()
        #expect(await restore.resolve(receipt) == .published(receipt))
        let current = try await restore.preview(desired)
        #expect(
            try await restore.restore(desired, reviewed: current) == .unchanged)
        #expect(await transport.publishAttempts == 1)
    }

    @Test func ambiguousResponseAndThirdPointerStayIndeterminate() async throws
    {
        let old = try entries(count: 1, title: "Old")
        let desired = try backup(entries(count: 2, title: "New"))
        let transport = MemoryTransport(
            initial: old, fault: .unknownWithCompetingSwitch)
        let restore = Restore(transport: transport)
        let review = try await restore.preview(desired)
        guard
            case .indeterminate(let receipt) = try await restore.restore(
                desired, reviewed: review)
        else {
            Issue.record(
                "A third pointer cannot prove a prior publish did not happen")
            return
        }
        #expect(await transport.readActive().pointer.generation != .legacy)
        #expect(await restore.resolve(receipt) == .indeterminate(receipt))
        #expect(await transport.publishAttempts == 1)
        #expect(await transport.stageCount == 2)
    }

    @Test func refusesUnfencedLegacyAndAccountSessionTransitionDuringStage()
        async throws
    {
        let old = try entries(count: 1, title: "Old")
        let wanted = try backup(entries(count: 201, title: "New"))
        let unfenced = MemoryTransport(initial: old, fault: .unfenceable)
        let first = Restore(transport: unfenced)
        await #expect(throws: Restore.Failure.writeFenceUnavailable) {
            try await first.preview(wanted)
        }
        #expect(await unfenced.stageCount == 0)

        let transition = MemoryTransport(
            initial: old, fault: .accountTransitionDuringStage)
        let second = Restore(transport: transition)
        let preview = try await second.preview(wanted)
        await #expect(throws: Restore.Failure.stagingFailed) {
            try await second.restore(wanted, reviewed: preview)
        }
        #expect(await transition.batchSizes == [100])
        #expect(await transition.publishAttempts == 0)
        #expect(try await transition.scan(.legacy) == old)
    }

    private func backup(_ entries: [Entry]) throws -> PrivateCloudBackup {
        try PrivateCloudBackup.capture(
            records: entries, accountBinding: Self.binding)
    }

    private func entries(count: Int, title: String) throws -> [Entry] {
        try (0..<count).map { index in
            let name = "session-" + String(format: "%04d", index)
            let value = RemoteListeningSession(
                id: PlaybackSessionID(rawValue: name),
                accountID: AccountID(rawValue: "test"),
                itemID: LibraryItemID(rawValue: "item"),
                startedAt: Date(timeIntervalSinceReferenceDate: 1000),
                updatedAt: Date(timeIntervalSinceReferenceDate: 1010),
                realSeconds: 3, currentTime: 3, duration: 60, title: title,
                author: "Synthetic"
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return Entry(
                kind: .remoteSession, name: "remote.test.\(name)",
                payload: try encoder.encode(value))
        }
    }

    private static let binding = PrivateCloudBackup.binding(
        container: "Synthetic", cloudUserRecordName: "Same Account"
    )

    private actor MemoryTransport: Restore.Transport {
        enum Fault {
            case none, writerAtPublish, selectorAtVerification,
                cancelSecondBatch, corruptStageRead, unfenceable,
                accountTransitionDuringStage, lostAfterSwitch,
                unknownWithLateSwitch, unknownWithCompetingSwitch
        }
        enum TestFailure: Error { case invalidStage, lostResponse }
        private struct Stage {
            var entries: [Entry] = []
            var sealed = false
        }

        private var pointer = Restore.Pointer(
            generation: .legacy, revision: UUID())
        private var mutation = UUID()
        private var sessionEpoch = UUID()
        private var stores: [Restore.Generation: Stage]
        private var late: (Restore.Pointer, Restore.ActiveState)?
        private let fault: Fault
        private(set) var batchSizes: [Int] = []
        private(set) var publishAttempts = 0
        private(set) var publishedCount = 0
        var stageCount: Int { stores.count - 1 }

        init(initial: [Entry], fault: Fault = .none) {
            stores = [.legacy: Stage(entries: initial, sealed: true)]
            self.fault = fault
        }

        var session: Restore.TargetSession {
            Restore.TargetSession(accountBinding: binding, epoch: sessionEpoch)
        }

        func readActive() -> Restore.ActiveState {
            Restore.ActiveState(
                session: session, fenceReady: fault != .unfenceable,
                pointer: pointer, writeRevision: mutation
            )
        }

        func scan(
            _ generation: Restore.Generation,
            in requested: Restore.TargetSession
        ) throws -> [Entry] {
            try requireSession(requested)
            return try scan(generation)
        }

        private func requireSession(_ requested: Restore.TargetSession) throws {
            guard requested == session else { throw TestFailure.invalidStage }
        }

        func scan(_ generation: Restore.Generation) throws -> [Entry] {
            guard let stage = stores[generation] else {
                throw TestFailure.invalidStage
            }
            if generation != .legacy, fault == .selectorAtVerification {
                let competitor = Restore.Generation.staged(UUID())
                stores[competitor] = Stage(entries: [], sealed: true)
                pointer = Restore.Pointer(
                    generation: competitor, revision: UUID())
            }
            if generation != .legacy, fault == .corruptStageRead {
                return Array(stage.entries.dropLast())
            }
            return stage.entries
        }

        func createStage(
            _ generation: Restore.Generation,
            in requested: Restore.TargetSession
        ) throws {
            try requireSession(requested)
            guard generation != .legacy, stores[generation] == nil else {
                throw TestFailure.invalidStage
            }
            stores[generation] = Stage()
        }

        func appendStage(
            _ records: [Entry], to generation: Restore.Generation,
            in requested: Restore.TargetSession
        ) throws {
            if fault == .accountTransitionDuringStage, !batchSizes.isEmpty {
                sessionEpoch = UUID()
            }
            try requireSession(requested)
            guard var stage = stores[generation], !stage.sealed,
                generation != pointer.generation
            else {
                throw TestFailure.invalidStage
            }
            if fault == .cancelSecondBatch, !batchSizes.isEmpty {
                throw CancellationError()
            }
            batchSizes.append(records.count)
            stage.entries.append(contentsOf: records)
            stores[generation] = stage
        }

        func sealStage(
            _ generation: Restore.Generation,
            in requested: Restore.TargetSession
        ) throws {
            try requireSession(requested)
            guard var stage = stores[generation], !stage.sealed else {
                throw TestFailure.invalidStage
            }
            stage.sealed = true
            stores[generation] = stage
        }

        func publish(
            _ new: Restore.Pointer, replacing expected: Restore.ActiveState
        ) throws -> Restore.PublishResult {
            publishAttempts += 1
            if fault == .writerAtPublish { mutation = UUID() }
            guard readActive() == expected,
                stores[new.generation]?.sealed == true
            else { return .rejected }
            if fault == .unknownWithCompetingSwitch {
                let competitor = Restore.Generation.staged(UUID())
                stores[competitor] = Stage(entries: [], sealed: true)
                pointer = Restore.Pointer(
                    generation: competitor, revision: UUID())
                mutation = UUID()
                return .unknown
            }
            if fault == .unknownWithLateSwitch {
                late = (new, expected)
                return .unknown
            }
            pointer = new
            mutation = UUID()
            publishedCount += 1
            if fault == .lostAfterSwitch { throw TestFailure.lostResponse }
            return .accepted
        }

        func writeFromLegacyClient(_ entries: [Entry]) {
            stores[.legacy] = Stage(entries: entries, sealed: true)
        }

        func writeFromFencedActiveClient(_ entries: [Entry]) {
            stores[pointer.generation] = Stage(entries: entries, sealed: true)
            mutation = UUID()
        }

        func deliverLatePublication() {
            guard let (new, expected) = late, readActive() == expected else {
                return
            }
            pointer = new
            mutation = UUID()
            publishedCount += 1
            late = nil
        }
    }
}
