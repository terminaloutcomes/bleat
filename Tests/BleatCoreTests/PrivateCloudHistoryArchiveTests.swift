import CloudKit
import Foundation
import Testing

@testable import BleatCore

@Suite struct PrivateCloudHistoryArchiveTests {
    private let account = AccountID(rawValue: "fixture-account")

    private func fixture() throws -> Data {
        try Data(
            contentsOf: #require(
                Bundle.module.url(
                    forResource: "cloud-history-legacy-v1",
                    withExtension: "json"
                )))
    }

    @Test func replaysOriginalLegacyRecordsAndMixedCanonicalHistory()
        async throws
    {
        let data = try fixture()
        let archive = try PrivateCloudHistoryArchive.decode(data)
        let preview = try archive.preview()
        #expect(preview.legacySliceCount == 2)
        #expect(preview.currentSliceCount == 0)
        #expect(preview.accountCount == 1)
        let replay = try await archive.replayEvidence(confirmedAccountIDs: [
            account
        ])
        let summary = replay.summary
        #expect(summary.localRealSeconds == 10)
        #expect(summary.audiobookSeconds == 10)
        #expect(summary.sessions == 1)

        let input = try JSONDecoder().decode(Fixture.self, from: data).records
        let observations = try input.map {
            try ListeningSegmentCodec.decode($0.payload)
        }
        let canonical = try ListeningSegmentCodec.coalesce(observations)
        #expect(canonical.count == 1)
        #expect(canonical.first?.lineage != nil)
        #expect(canonical.first?.startedAt == observations.first?.startedAt)
        #expect(canonical.first?.endedAt == observations.last?.endedAt)

        #expect(replay.preparedSlices.filter { $0.lineage != nil } == canonical)

        let zone = CKRecordZone.ID(zoneName: "SyntheticSource")
        let old = input.map {
            let record = CKRecord(
                recordType: "ListeningSlice",
                recordID: CKRecord.ID(recordName: $0.name, zoneID: zone)
            )
            record["payload"] = $0.payload as CKRecordValue
            return record
        }
        let new = try canonical.map {
            try ListeningSegmentCodec.cloudRecord($0, zoneID: zone)
        }
        let current = try PrivateCloudHistoryArchive.capture(new)
        #expect(try current.preview().legacySliceCount == 0)
        #expect(
            try await current.replay(confirmedAccountIDs: [account]) == summary)
        let mixed = try PrivateCloudHistoryArchive.capture(old + new)
        let encoded = try mixed.encoded()
        let restored = try PrivateCloudHistoryArchive.decode(encoded)
        #expect(try restored.encoded() == encoded)
        #expect(try restored.preview().currentSliceCount == 1)
        #expect(
            try await restored.replay(confirmedAccountIDs: [account]) == summary
        )
        let stable = try JSONDecoder().decode(Fixture.self, from: encoded)
        for record in input {
            #expect(
                stable.records.first { $0.name == record.name }?.payload
                    == record.payload)
        }
        let redacted = try String(
            decoding: JSONEncoder().encode(restored.preview()), as: UTF8.self)
        #expect(!redacted.contains("fixture-account"))
        #expect(!redacted.contains("Synthetic"))
        #expect(!redacted.contains("payload"))
    }

    @Test func countsCanonicalSingletonAndReplaysResetAnchor() async throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: fixture())
        let input = try ListeningSegmentCodec.decode(fixture.records[0].payload)
        let singleton = try #require(
            ListeningSegmentCodec.coalesce([input]).first)
        #expect(singleton.lineage == nil)
        #expect(singleton.recordingFormat == .continuousSegment)
        let reset = try ListeningSegmentCodec.resetEnvelopes(
            accountID: account,
            action: ListeningResetAction(
                id: try #require(
                    UUID(uuidString: "80000000-0000-4000-8000-000000000001")),
                start: nil, end: nil, issuedAt: input.endedAt,
                selection: .sourceIdentities
            ),
            ids: [input.id]
        )
        let zone = CKRecordZone.ID(zoneName: "SyntheticSource")
        let records = try ([singleton] + reset).map {
            try ListeningSegmentCodec.cloudRecord($0, zoneID: zone)
        }
        let archive = try PrivateCloudHistoryArchive.capture(records)
        #expect(try archive.preview().currentSliceCount == 2)
        #expect(try archive.preview().legacySliceCount == 0)
        #expect(
            try await archive.replay(confirmedAccountIDs: [account])
                .localRealSeconds == 0)
    }

    @Test func futurePartialMalformedAndUnknownPayloadFieldsFailBeforeReplay()
        throws
    {
        let original = try #require(
            JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        for (key, value, expected):
            (String, Any, PrivateCloudHistoryArchive.Failure) in [
                ("version", 2, .unsupportedVersion),
                ("completeForScope", false, .incompleteCapture),
                ("scope", "unsupported", .invalidArchive),
            ]
        {
            var changed = original
            changed[key] = value
            let data = try JSONSerialization.data(withJSONObject: changed)
            #expect(throws: expected) {
                try PrivateCloudHistoryArchive.decode(data)
            }
        }
        var records = try #require(original["records"] as? [[String: String]])
        var changed = original
        changed["records"] = records + [records[0]]
        let duplicate = try JSONSerialization.data(withJSONObject: changed)
        #expect(throws: PrivateCloudHistoryArchive.Failure.duplicateRecord) {
            try PrivateCloudHistoryArchive.decode(duplicate)
        }

        let firstPayload = try #require(records.first?["payload"])
        let firstBytes = try #require(Data(base64Encoded: firstPayload))
        var payload = try #require(
            JSONSerialization.jsonObject(with: firstBytes) as? [String: Any])
        payload["unknown"] = ["token": "never-export"]
        records[0]["payload"] = try JSONSerialization.data(
            withJSONObject: payload
        ).base64EncodedString()
        changed["records"] = records
        let malformed = try JSONSerialization.data(withJSONObject: changed)
        #expect(throws: PrivateCloudHistoryArchive.Failure.invalidRecord) {
            try PrivateCloudHistoryArchive.decode(malformed)
        }
    }

    @Test func requiresExactAccountScopeAndRetryAfterCancellation() async throws
    {
        let archive = try PrivateCloudHistoryArchive.decode(fixture())
        await #expect(
            throws: PrivateCloudHistoryArchive.Failure.accountMismatch
        ) {
            try await archive.replay(confirmedAccountIDs: [
                AccountID(rawValue: "wrong-account")
            ])
        }
        await #expect(throws: CancellationError.self) {
            try await archive.replayEvidence(confirmedAccountIDs: [account]) {
                throw CancellationError()
            }
        }
        #expect(
            try await archive.replay(confirmedAccountIDs: [account])
                .localRealSeconds == 10)
    }

    private struct Fixture: Decodable {
        let records: [PrivateCloudHistoryArchive.Record]
    }
}
