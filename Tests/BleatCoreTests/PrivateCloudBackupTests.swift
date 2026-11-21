import CloudKit
import Foundation
import Testing

@testable import BleatCore

@Suite struct PrivateCloudBackupTests {
    private let binding = PrivateCloudBackup.binding(
        container: "synthetic-container",
        cloudUserRecordName: "synthetic-account"
    )

    @Test func allFiveRecordTypesKeepExactPayloadBytesThroughAnArchive() throws
    {
        let entries = try makeRecords()
        let archive = try PrivateCloudBackup.capture(
            records: entries, accountBinding: binding)
        let encoded = try archive.encoded()
        let restored = try PrivateCloudBackup.decode(encoded)
        #expect(try restored.encoded() == encoded)
        let result = try restored.preview()
        #expect(result.recordCount == 5)
        #expect(result.recordsByType.values.allSatisfy { $0 == 1 })
        let decoded = try JSONDecoder().decode(Envelope.self, from: encoded)
        #expect(decoded.records == entries.sorted { $0.name < $1.name })
        let summary = try String(
            decoding: JSONEncoder().encode(result), as: UTF8.self)
        #expect(!summary.contains(binding))
        #expect(!summary.contains("synthetic.invalid"))
        #expect(!summary.contains("payload"))
    }

    @Test func plannerPreviewsExactReplacementAndFlagsAccountDeletion() throws {
        let entries = try makeRecords()
        let desired = try PrivateCloudBackup.capture(
            records: entries.filter { $0.kind != .account },
            accountBinding: binding
        )
        let current = try PrivateCloudBackup.capture(
            records: entries.map {
                guard $0.kind == .configuration else { return $0 }
                // An earlier settings payload, different bytes with the same stable identity.
                let payload = $0.payload + Data(" ".utf8)
                return PrivateCloudBackup.Entry(
                    kind: $0.kind, name: $0.name, payload: payload)
            }.filter { $0.kind != .completion },
            accountBinding: binding
        )
        let plan = try desired.planReplacing(current)
        #expect(try desired.rehearseReplacing(current) == plan)
        #expect(plan.create == 1)
        #expect(plan.replace == 1)
        #expect(plan.remove == 1)
        #expect(plan.unchanged == 2)
        #expect(plan.accountRecordsRemoved == 1)
        #expect(plan.fitsSingleOperation)
        #expect(try desired.planReplacing(desired).unchanged == 4)

        let unrelated = try PrivateCloudBackup.capture(
            records: [], accountBinding: Self.otherBinding
        )
        #expect(throws: PrivateCloudBackup.Failure.accountMismatch) {
            try desired.planReplacing(unrelated)
        }
    }

    @Test func refusesUnknownAssetFieldsUnsafeURLsAndIncompleteArchives() throws
    {
        let id = CKRecord.ID(recordName: "configuration.singleton")
        let record = CKRecord(recordType: "Configuration", recordID: id)
        record["payload"] = Data("{}".utf8) as CKRecordValue
        #expect(
            try PrivateCloudBackup.Entry(cloudRecord: record).kind
                == .configuration)
        record["attachment"] = CKAsset(
            fileURL: URL(fileURLWithPath: "/synthetic/private.dat"))
        #expect(throws: PrivateCloudBackup.Failure.unsupportedData) {
            try PrivateCloudBackup.Entry(cloudRecord: record)
        }
        #expect(throws: PrivateCloudBackup.Failure.unsupportedData) {
            try PrivateCloudBackup.Entry(
                cloudRecord: CKRecord(recordType: "FutureType"))
        }

        let entries = try makeRecords()
        let account = try #require(entries.first { $0.kind == .account })
        let unsafe = String(decoding: account.payload, as: UTF8.self)
            .replacingOccurrences(
                of: "synthetic.invalid", with: "synthetic.invalid?token=private"
            )
        #expect(throws: PrivateCloudBackup.Failure.unsafeAccountPayload) {
            try PrivateCloudBackup.capture(
                records: [
                    .init(
                        kind: .account, name: account.name,
                        payload: Data(unsafe.utf8))
                ],
                accountBinding: binding
            )
        }
        let duplicate = [account, account]
        #expect(throws: PrivateCloudBackup.Failure.duplicateRecord) {
            try PrivateCloudBackup.capture(
                records: duplicate, accountBinding: binding)
        }
        let archive = try PrivateCloudBackup.capture(
            records: [], accountBinding: binding)
        var wire = try #require(
            JSONSerialization.jsonObject(with: archive.encoded())
                as? [String: Any])
        wire["unexpected"] = true
        let unexpected = try JSONSerialization.data(withJSONObject: wire)
        #expect(throws: PrivateCloudBackup.Failure.unsupportedData) {
            try PrivateCloudBackup.decode(unexpected)
        }
        wire.removeValue(forKey: "unexpected")
        wire["complete"] = false
        let malformed = try JSONSerialization.data(withJSONObject: wire)
        #expect(throws: PrivateCloudBackup.Failure.incompleteCapture) {
            try PrivateCloudBackup.decode(malformed)
        }
        wire["version"] = 1
        let partialHistory = try JSONSerialization.data(withJSONObject: wire)
        #expect(throws: PrivateCloudBackup.Failure.unsupportedVersion) {
            try PrivateCloudBackup.decode(partialHistory)
        }
    }

    @Test func canonicalizesOrderAndDetectsValidlyTruncatedJSON() throws {
        let source = try PrivateCloudBackup.capture(
            records: makeRecords(), accountBinding: binding)
        let bytes = try source.encoded()
        var wire = try #require(
            JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let records = try #require(wire["records"] as? [[String: Any]])
        wire["records"] = Array(records.reversed())
        let shuffled = try JSONSerialization.data(withJSONObject: wire)
        #expect(try PrivateCloudBackup.decode(shuffled).encoded() == bytes)
        wire["records"] = Array(records.dropLast())
        let truncated = try JSONSerialization.data(withJSONObject: wire)
        #expect(throws: PrivateCloudBackup.Failure.invalidBackup) {
            try PrivateCloudBackup.decode(truncated)
        }
    }

    @Test
    func largeCaptureIsValidButAnOversizedReplaceIsNeverPlannedAsOneOperation()
        throws
    {
        let entries = try (0..<58_004).map {
            index -> PrivateCloudBackup.Entry in
            let value = try JSONEncoder().encode(
                RemoteListeningSession(
                    id: PlaybackSessionID(rawValue: "synthetic-\(index)"),
                    accountID: AccountID(rawValue: "test-account"),
                    itemID: LibraryItemID(rawValue: "test-item"),
                    startedAt: Date(timeIntervalSinceReferenceDate: 7000),
                    updatedAt: Date(timeIntervalSinceReferenceDate: 7060),
                    realSeconds: 1, currentTime: 6, duration: 60, title: "Test",
                    author: "Synthetic"
                ))
            return .init(
                kind: .remoteSession,
                name: "remote.test-account.synthetic-\(index)", payload: value)
        }
        let empty = try PrivateCloudBackup.capture(
            records: [], accountBinding: binding)
        let large = try PrivateCloudBackup.capture(
            records: entries, accountBinding: binding)
        let plan = try large.planReplacing(empty)
        #expect(plan.create == 58_004)
        #expect(!plan.fitsSingleOperation)
    }

    private static let otherBinding = PrivateCloudBackup.binding(
        container: "synthetic-container", cloudUserRecordName: "other-account"
    )

    private struct Envelope: Decodable {
        let records: [PrivateCloudBackup.Entry]
    }

    private func makeRecords() throws -> [PrivateCloudBackup.Entry] {
        let server = try NormalizedServerURL("https://synthetic.invalid")
        let userID = UserID(rawValue: "fixture-user")
        let account = try ServerAccount(
            id: AccountID.canonical(server: server, userID: userID),
            server: server,
            serverVersion: "2.38.0", authenticationMethods: [.local],
            user: AuthenticatedUser(
                id: userID, username: "Synthetic User", type: .user,
                permissions: try JSONDecoder().decode(
                    UserPermissions.self, from: Data("{}".utf8)),
                accessibleLibraryIDs: [], selectedItemTags: []
            )
        )
        let legacyResource = try #require(
            Bundle.module.url(
                forResource: "cloud-history-legacy-v1", withExtension: "json"
            ))
        let history = try #require(
            JSONDecoder().decode(
                HistoryEnvelope.self, from: Data(contentsOf: legacyResource)
            ).records.first)
        let legacySlice = try ListeningSegmentCodec.decode(history.payload)
        let slice = legacySlice.reidentified(as: account.id)
        let milestone = CompletionMilestone(
            accountID: account.id, itemID: slice.itemID,
            completedAt: slice.endedAt,
            duration: slice.duration, title: slice.title, author: slice.author,
            evidence: .naturalEnd
        )
        let remote = RemoteListeningSession(
            id: slice.sessionID, accountID: account.id, itemID: slice.itemID,
            startedAt: slice.startedAt, updatedAt: slice.endedAt,
            realSeconds: slice.realSeconds,
            currentTime: slice.endPosition, duration: slice.duration,
            title: slice.title, author: slice.author
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Include a legacy settings payload without newer optional fields.
        let settings = Data(
            """
            {"defaultPlaybackRate":1,"resumeRewindSeconds":10,"skipBackwardSeconds":30,
            "skipForwardSeconds":30,"downloadNetworkPolicy":"wifiOnly",
            "automaticDownloadLookahead":0,"automaticDownloadCleanupPolicy":"afterTwentyFourHours"}
            """.utf8)
        return [
            .init(
                kind: .account, name: "account.\(account.id.rawValue)",
                payload: try encoder.encode(
                    CloudServerAccountRecordPayload(
                        supersededPayloadDigest: nil, account: account)
                )),
            .init(
                kind: .configuration, name: "configuration.singleton",
                payload: settings),
            .init(
                kind: .listening, name: history.name,
                payload: try ListeningSegmentCodec.encode(slice)),
            .init(
                kind: .completion,
                name: "completion.\(milestone.id.uuidString.lowercased())",
                payload: try encoder.encode(milestone)),
            .init(
                kind: .remoteSession,
                name: "remote.\(account.id.rawValue).\(remote.id.rawValue)",
                payload: try encoder.encode(remote)),
        ]
    }

    private struct HistoryEnvelope: Decodable {
        let records: [PrivateCloudHistoryArchive.Record]
    }
}
