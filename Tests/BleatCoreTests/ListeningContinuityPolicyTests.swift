import CloudKit
import Foundation
import SwiftData
import Testing

@testable import BleatCore

@Suite struct ListeningContinuityPolicyTests {
    @Test func diagnosticsRetainExactSegmentStageAndCause() throws {
        let failure = ListeningSegmentFailure(
            .retirement, .partialRangeResetUnsupported)
        let event = DiagnosticEvent.failed(
            .resetStatistics, category: .sync,
            failureCode: .statisticsSegmentFailure,
            listeningSegmentFailure: failure)
        #expect(
            event.text.contains(
                "segment_failure=listening_segment.retirement.partialRangeResetUnsupported"
            ))
        #expect(
            try JSONDecoder().decode(
                DiagnosticEvent.self, from: JSONEncoder().encode(event)
            ).listeningSegmentFailure == failure)
    }

    @Test func fractionalMeasuredQuantitiesSurviveCanonicalTransportExactly()
        throws
    {
        var originals: [ListeningSlice] = []
        for index in 0..<2 {
            let value = try slice(index)
            var json = try #require(
                JSONSerialization.jsonObject(
                    with: ListeningSegmentCodec.encode(value)) as? [String: Any]
            )
            json["realSeconds"] = 5.000000000000001
            json["audiobookSeconds"] = 7.500000000000001
            json["startedAt"] =
                value.startedAt.timeIntervalSinceReferenceDate + 0.1234567
            json["endedAt"] =
                value.endedAt.timeIntervalSinceReferenceDate + 0.1234567
            originals.append(
                try ListeningSegmentCodec.decode(
                    JSONSerialization.data(withJSONObject: json)))
        }
        let merged = try #require(
            ListeningSegmentCodec.coalesce(originals).first)
        let record = try ListeningSegmentCodec.cloudRecord(
            merged,
            zoneID: CKRecordZone.ID(
                zoneName: "isolated", ownerName: CKCurrentUserDefaultName))
        let restored = try ListeningSegmentCodec.decode(record)
        #expect(restored == merged)
        let quantities = try ListeningSegmentCodec.contributions(restored)
        #expect(
            quantities.allSatisfy {
                $0.realSeconds == 5.000000000000001
                    && $0.audiobookSeconds == 7.500000000000001
            })
        #expect(
            restored.realSeconds == originals.reduce(0) { $0 + $1.realSeconds })
        let payload = try ListeningSegmentCodec.encode(restored)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(BleatPersistenceModelCatalog.currentModelTypes)
        let configuration = ModelConfiguration(
            schema: schema,
            url: directory.appendingPathComponent("precision.store"),
            cloudKitDatabase: .none)
        do {
            let container = try ModelContainer(
                for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(try ListeningSliceRecord(encodedSegment: payload))
            try context.save()
        }
        let reopened = try ModelContainer(
            for: schema, configurations: [configuration])
        let row = try #require(
            ModelContext(reopened).fetch(
                FetchDescriptor<ListeningSliceRecord>()
            ).first)
        #expect(try row.validatedValue() == restored)
        // Intentional storage identity: the cloud payload is persisted unchanged.
        #expect(row.segmentPayload == payload)
    }

    private func repository() throws -> StatisticsRepository {
        let schema = Schema(BleatPersistenceModelCatalog.currentModelTypes)
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            ])
        return StatisticsRepository(
            modelContainer: container, monotonicNow: { 0 },
            canonicalHistoryEnabled: { true })
    }

    @Test func retirementWaitsForExactSavedPayloadAndSurvivesActorRecreation()
        async throws
    {
        let repository = try repository()
        let originals = try (0..<8).map { try slice($0) }
        try await repository.importArchive(
            StatisticsArchive(
                slices: originals, completions: [], remoteSessions: []))
        try await repository.prepareCanonicalCompaction()
        try await repository.retireConfirmedCanonicalSources()
        #expect(try await repository.privateCloudDeletions().isEmpty)
        let prepared = try await repository.privateCloudSnapshot()
        let replacements = prepared.archive.slices.filter { $0.lineage != nil }
        #expect(replacements.count == 1)
        let archive = StatisticsArchive(
            slices: replacements, completions: [], remoteSessions: [])
        try await repository.markPrivateCloudArchiveSynchronized(archive)
        try await repository.retireConfirmedCanonicalSources()
        #expect(try await repository.privateCloudDeletions().isEmpty)
        try await repository.markPrivateCloudArchiveSynchronized(
            archive, confirmedUpload: true, savedPayloads: prepared.payloads)
        let reopened = StatisticsRepository(
            modelContainer: await repository.modelContainer,
            canonicalHistoryEnabled: { true })
        try await reopened.retireConfirmedCanonicalSources()
        #expect(
            try await reopened.privateCloudDeletions().count == originals.count)
        // Replayed old-client records stay logically deduplicated and get
        // cleanup again without changing the retained replacement.
        try await reopened.importArchive(
            StatisticsArchive(
                slices: originals, completions: [], remoteSessions: []))
        try await reopened.retireConfirmedCanonicalSources(
            additional: originals)
        let retained = try await reopened.archive().slices
        #expect(
            try ListeningSegmentCodec.resolve(retained).groups.reduce(0) {
                $0 + $1.value.realSeconds
            } == 40)
        #expect(
            try await reopened.privateCloudDeletions().count == originals.count)
    }

    @Test func corruptAndUnknownCanonicalPayloadNeverFallsBackToScalarColumns()
        throws
    {
        let value = try #require(
            ListeningSegmentCodec.coalesce([slice(0), slice(1)]).first)
        let row = try ListeningSliceRecord(
            encodedSegment: ListeningSegmentCodec.encode(value))
        row.segmentEnvelopeVersion = nil
        #expect(try row.validatedValue() == value)
        row.segmentEnvelopeVersion = ListeningSegmentCodec.currentVersion
        row.segmentPayload = Data("corrupt".utf8)
        #expect(throws: ListeningSegmentFailure.self) {
            try row.validatedValue()
        }
        row.segmentPayload = nil
        #expect(throws: ListeningSegmentFailure.self) {
            try row.validatedValue()
        }
        var json = try #require(
            JSONSerialization.jsonObject(
                with: ListeningSegmentCodec.encode(value)) as? [String: Any])
        var lineage = try #require(json["lineage"] as? [String: Any])
        lineage["version"] = 99
        json["lineage"] = lineage
        #expect(throws: ListeningSegmentFailure.self) {
            try ListeningSegmentCodec.decode(
                JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test func resetFencesPreparedUploadsAndLateSavesWaitForDurableAnchors()
        async throws
    {
        let repository = try repository()
        let originals = try (0..<8).map { try slice($0) }
        try await repository.importArchive(
            StatisticsArchive(
                slices: originals, completions: [], remoteSessions: []))
        try await repository.prepareCanonicalCompaction()
        let prepared = try await repository.privateCloudSnapshot()
        let replacement = try #require(
            prepared.archive.slices.first { $0.lineage != nil })
        try await repository.reset(
            query: StatisticsQuery(accountID: originals[0].accountID))
        await #expect(throws: StatisticsRepositoryError.self) {
            try await repository.validatePreparedHistory(
                generation: prepared.retirementGeneration)
        }
        #expect(
            try await repository.currentListeningUpload(id: replacement.id)
                == nil)
        try await repository.compensateLateListeningSaves([replacement])
        #expect(try await repository.archive().slices.isEmpty)
        #expect(try await repository.privateCloudDeletions().isEmpty)
        let reset = try await repository.privateCloudSnapshot()
        #expect(!(reset.archive.resetEnvelopes ?? []).isEmpty)
        try await repository.markPrivateCloudArchiveSynchronized(
            reset.archive, confirmedUpload: true, savedPayloads: reset.payloads)
        let reopened = StatisticsRepository(
            modelContainer: await repository.modelContainer,
            canonicalHistoryEnabled: { true })
        #expect(
            try await reopened.privateCloudDeletions().contains {
                $0.recordName
                    == "slice.\(replacement.id.uuidString.lowercased())"
            })
        try await reopened.importArchive(
            StatisticsArchive(
                slices: originals, completions: [], remoteSessions: []))
        #expect(try await reopened.archive().slices.isEmpty)
    }

    @Test func uncoveredCloudDeletionRepairsHistoryAndPermanentResetAnchors()
        async throws
    {
        let repository = try repository()
        let values = try (0..<4).map { try slice($0) }
        let replacement = try #require(
            ListeningSegmentCodec.coalesce(values).first)
        try await repository.importArchive(
            StatisticsArchive(
                slices: [replacement], completions: [], remoteSessions: []))
        try await repository.observeCloudSliceDeletion(id: replacement.id)
        try await repository.finalizeObservedListeningDeletions()
        #expect(try await repository.archive().slices == [replacement])
        #expect(
            try await repository.currentListeningUpload(id: replacement.id)?
                .value == replacement)
        try await repository.reset(
            query: StatisticsQuery(accountID: replacement.accountID))
        let roots = try #require(await repository.archive().resetEnvelopes)
        for root in roots {
            try await repository.observeCloudSliceDeletion(id: root.id)
        }
        try await repository.finalizeObservedListeningDeletions()
        #expect(try await repository.archive().resetEnvelopes == roots)
        try await repository.importArchive(
            StatisticsArchive(
                slices: values, completions: [], remoteSessions: []))
        #expect(try await repository.archive().slices.isEmpty)
    }

    @Test func accountRekeyRebuildsCanonicalPayloadAndReceiptDependencies()
        async throws
    {
        let repository = try repository()
        let values = try (0..<4).map { try slice($0) }
        try await repository.importArchive(
            StatisticsArchive(
                slices: values, completions: [], remoteSessions: []))
        try await repository.prepareCanonicalCompaction()
        let old = try #require(
            await repository.archive().slices.first { $0.lineage != nil })
        let owner = AccountID(rawValue: "canonical-account")
        let store = AccountStore(
            modelContainer: await repository.modelContainer)
        try await store.applyIdentityMigrations([
            AccountIdentityMigration(
                legacyID: old.accountID, canonicalID: owner)
        ])
        await repository.accountOwnershipDidChange()
        let migrated = try await repository.archive()
        #expect(migrated.slices.allSatisfy { $0.accountID == owner })
        let replacement = try #require(
            migrated.slices.first { $0.lineage != nil })
        #expect(replacement == old.reidentified(as: owner))
        #expect(replacement.id != old.id)
        #expect(try await repository.privateCloudDeletions().isEmpty)
        let pending = try await repository.privateCloudSnapshot()
        try await repository.markPrivateCloudArchiveSynchronized(
            pending.archive, confirmedUpload: true,
            savedPayloads: pending.payloads)
        #expect(
            try await repository.privateCloudDeletions().contains {
                $0.recordName == "slice.\(old.id.uuidString.lowercased())"
            })
        try await repository.compensateLateListeningSaves([old])
        #expect(
            try await repository.archive().slices.allSatisfy {
                $0.accountID == owner
            })
    }

    @Test func pendingPreconsentResetDoesNotActivateAnotherAccountsProtocol()
        async throws
    {
        let enabledRepository = try repository()
        let repository = StatisticsRepository(
            modelContainer: await enabledRepository.modelContainer)
        let a = try slice(0)
        let b = try slice(1).reidentified(
            as: AccountID(rawValue: "other-account"))
        try await repository.importArchive(
            StatisticsArchive(
                slices: [a, b], completions: [], remoteSessions: []))
        try await repository.reset(
            query: StatisticsQuery(accountID: a.accountID))
        #expect(
            try await repository.privateCloudSnapshot(
                includeCanonicalSegments: false
            ).archive.resetEnvelopes == nil)
        try await repository.observeCloudSliceDeletion(id: b.id)
        try await repository.finalizeObservedListeningDeletions()
        #expect(try await repository.archive().slices.isEmpty)
    }

    @Test func localAccountHistoryRemovalDoesNotCreateCloudReset() async throws
    {
        let repository = try repository()
        let original = try slice(0)
        try await repository.importArchive(
            StatisticsArchive(
                slices: [original], completions: [], remoteSessions: []))
        try await repository.removeAccountHistoryLocally(original.accountID)
        #expect(try await repository.archive().slices.isEmpty)
        #expect(try await repository.archive().resetEnvelopes == nil)
        #expect(try await repository.privateCloudDeletions().isEmpty)
        try await repository.importArchive(
            StatisticsArchive(
                slices: [original], completions: [], remoteSessions: []))
        #expect(try await repository.archive().slices == [original])
        try await repository.reset(
            query: StatisticsQuery(accountID: original.accountID))
        let roots = try await repository.archive().resetEnvelopes
        try await repository.removeAccountHistoryLocally(original.accountID)
        #expect(try await repository.archive().resetEnvelopes == roots)
    }
    private func slice(
        _ index: Int, gap: Double = 0, positionGap: Double = 0,
        boundary: ListeningBoundary? = nil
    ) throws -> ListeningSlice {
        let id = try #require(
            UUID(
                uuidString: String(
                    format: "00000000-0000-4000-8000-%012x", index)))
        let start = 800_000_000.0 + Double(index) * 5 + (index == 0 ? 0 : gap)
        return ListeningSlice(
            id: id, accountID: AccountID(rawValue: "account"),
            itemID: LibraryItemID(rawValue: "book"),
            sessionID: PlaybackSessionID(rawValue: "session"),
            startedAt: Date(timeIntervalSinceReferenceDate: start),
            endedAt: Date(timeIntervalSinceReferenceDate: start + 5),
            startPosition: Double(index) * 7.5 + positionGap,
            endPosition: Double(index + 1) * 7.5 + positionGap,
            realSeconds: 5, audiobookSeconds: 7.5, playbackRate: 1.5,
            chapterID: nil, chapterTitle: nil, chapterStart: nil,
            chapterEnd: nil,
            title: "Synthetic book", author: "Synthetic author",
            duration: 100_000,
            boundaryAfter: boundary)
    }

    @Test(arguments: [0.499999, 0.5, 0.500001, -0.001])
    func wallToleranceHasExplicitHalfSecondBoundary(gap: Double) throws {
        let expected = gap >= 0 && gap <= 0.5
        #expect(
            ListeningContinuityPolicy.canJoin(
                try slice(0), try slice(1, gap: gap), evidence: .storedEndpoints
            ) == expected)
    }

    @Test func representationNoiseDoesNotCreateAFalseGap() throws {
        #expect(
            ListeningContinuityPolicy.canJoin(
                try slice(0), try slice(1, gap: -1e-12, positionGap: 1e-12),
                evidence: .storedEndpoints))
        #expect(
            !ListeningContinuityPolicy.canJoin(
                try slice(0), try slice(1, gap: -0.01),
                evidence: .storedEndpoints))
        #expect(
            !ListeningContinuityPolicy.canJoin(
                try slice(0), try slice(1, gap: 30), evidence: .storedEndpoints)
        )
    }

    @Test(arguments: [
        ListeningBoundary.inaudibleSample, .explicitStop, .rateChanged,
        .chapterChanged,
        .accountChanged, .bookChanged, .sessionChanged,
        .playbackGenerationChanged,
        .positionDiscontinuity, .processInterrupted,
    ])
    func knownBoundariesAlwaysWin(boundary: ListeningBoundary) throws {
        #expect(
            !ListeningContinuityPolicy.canJoin(
                try slice(0, boundary: boundary), try slice(1, gap: 0.1),
                evidence: .storedEndpoints))
    }

    @Test func wallGapNeverAddsListeningAndMediaSeekRemainsSeparate() throws {
        let first = try slice(0)
        let next = try slice(1, gap: 0.5)
        let merged = try #require(
            ListeningSegmentCodec.coalesce([first, next]).first)
        #expect(merged.realSeconds == 10)
        #expect(merged.audiobookSeconds == 15)
        #expect(merged.endedAt.timeIntervalSince(merged.startedAt) == 10.5)
        #expect(merged.lineage?.sourceData.count == 128)
        #expect(
            !ListeningContinuityPolicy.canJoin(
                first, try slice(1, gap: 0.1, positionGap: 0.2),
                evidence: .storedEndpoints))
        #expect(
            try ListeningSegmentCodec.coalesce([first, slice(1, gap: 0.500001)])
                .count == 2)
    }

    @Test func deterministicSharedCodecPreservesLocalCloudLocalPayload() throws
    {
        let originals = try (0..<20).map { try slice($0) }
        let a = try #require(ListeningSegmentCodec.coalesce(originals).first)
        let b = try #require(
            ListeningSegmentCodec.coalesce(originals.reversed()).first)
        #expect(a == b)
        let local = try ListeningSegmentCodec.encode(a)
        let cloud = try ListeningSegmentCodec.cloudRecord(
            a,
            zoneID: CKRecordZone.ID(
                zoneName: "isolated", ownerName: CKCurrentUserDefaultName),
            payload: local)
        // Exact byte comparison deliberately verifies transport identity.
        #expect(cloud["payload"] as? Data == local)
        let restored = try ListeningSegmentCodec.decode(cloud)
        #expect(restored == a)
        #expect(try ListeningSegmentCodec.encode(restored) == local)
    }

    @Test func overlapDeduplicationNeedsOnlyOpaqueContributionBookkeeping()
        throws
    {
        let originals = try (0..<20).map { try slice($0) }
        let a = try ListeningSegmentCodec.coalesce(Array(originals.prefix(15)))
        let b = try ListeningSegmentCodec.coalesce(Array(originals.suffix(15)))
        for delivery in [a + b + originals, b + a + b] {
            let result = try ListeningSegmentCodec.resolve(delivery)
            try #require(result.groups.count == 1)
            #expect(result.groups[0].value.realSeconds == 100)
            #expect(result.groups[0].value.audiobookSeconds == 150)
            #expect(result.groups[0].sources.count == 20)
        }
        let data = try ListeningSegmentCodec.encode(#require(a.first))
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let lineage = try #require(json["lineage"] as? [String: Any])
        #expect(lineage["sourceData"] is String)
        #expect(lineage["observations"] == nil)
        #expect(lineage["timestamps"] == nil)
    }

    @Test func syntheticHistoryShowsActualRecordAndPayloadReduction() throws {
        let originals = try (0..<58_008).map { try slice($0) }
        let compacted = try ListeningSegmentCodec.coalesce(originals)
        let oldBytes = try originals.reduce(0) {
            try $0 + JSONEncoder().encode($1).count
        }
        let newBytes = try compacted.reduce(0) {
            try $0 + ListeningSegmentCodec.encode($1).count
        }
        #expect(compacted.count < 100)
        #expect(newBytes < oldBytes / 2)
        #expect(compacted.reduce(0) { $0 + $1.realSeconds } == 290_040)
        #expect(compacted.reduce(0) { $0 + $1.audiobookSeconds } == 435_060)
        print(
            "Canonical trial: \(originals.count) records / \(oldBytes) bytes -> \(compacted.count) records / \(newBytes) bytes; synthetic only"
        )
    }
}
