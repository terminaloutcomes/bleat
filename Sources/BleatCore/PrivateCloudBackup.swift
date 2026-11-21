import CloudKit
import CryptoKit
import Foundation

/// Version 2 is a backup of the app-owned private CloudKit records, not of
/// local app data, iCloud Keychain, system metadata, or the ABS server.
public struct PrivateCloudBackup: Codable, Sendable {
    public static let formatVersion = 2
    public static let maximumArchiveBytes = 224 * 1024 * 1024
    static let maximumPayloadBytes = 128 * 1024 * 1024
    static let maximumRecordBytes = 768 * 1024
    static let maximumRecords = 120_000

    public enum Failure: String, Error, Codable, Sendable {
        case invalidBackup, unsupportedVersion, incompleteCapture,
            unsupportedData
        case invalidRecord, duplicateRecord, ambiguousAccount,
            unsafeAccountPayload
        case accountMismatch, archiveTooLarge, captureFailed
    }

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case account = "ServerAccount"
        case configuration = "Configuration"
        case listening = "ListeningSlice"
        case completion = "CompletionMilestone"
        case remoteSession = "RemoteListeningSession"
    }

    private struct WireKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func requireKnownKeys<Key: CodingKey & CaseIterable>(
        _ decoder: any Decoder, _ type: Key.Type
    ) throws {
        let all = try decoder.container(keyedBy: WireKey.self).allKeys
        let expected = Set(Key.allCases.map(\.stringValue))
        guard all.allSatisfy({ expected.contains($0.stringValue) }) else {
            throw Failure.unsupportedData
        }
    }

    struct Entry: Codable, Equatable, Sendable {
        let kind: Kind
        let name: String
        let payload: Data

        init(kind: Kind, name: String, payload: Data) {
            self.kind = kind
            self.name = name
            self.payload = payload
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case kind, name, payload
        }

        init(from decoder: any Decoder) throws {
            try requireKnownKeys(decoder, CodingKeys.self)
            let values = try decoder.container(keyedBy: CodingKeys.self)
            kind = try values.decode(Kind.self, forKey: .kind)
            name = try values.decode(String.self, forKey: .name)
            payload = try values.decode(Data.self, forKey: .payload)
        }

        init(cloudRecord: CKRecord) throws {
            guard let kind = Kind(rawValue: cloudRecord.recordType),
                Set(cloudRecord.allKeys()) == ["payload"],
                cloudRecord.parent == nil, cloudRecord.share == nil,
                cloudRecord.encryptedValues.allKeys().isEmpty,
                let payload = cloudRecord["payload"] as? Data
            else { throw Failure.unsupportedData }
            self.init(
                kind: kind, name: cloudRecord.recordID.recordName,
                payload: payload)
        }
    }

    public struct Preview: Codable, Equatable, Sendable {
        public let version: Int
        public let sourceBuild: String?
        public let recordsByType: [String: Int]
        public let recordCount: Int
    }

    public struct ReplacePlan: Codable, Equatable, Sendable {
        public let source: Preview
        public let current: Preview
        public let create: Int
        public let replace: Int
        public let remove: Int
        public let unchanged: Int
        public let accountRecordsRemoved: Int
        public let accountRecordsAddedOrChanged: Int
        /// Conservative planning limit, not a guarantee of provider acceptance.
        public let fitsSingleOperation: Bool
    }

    public let version: Int
    public let zone: String
    public let complete: Bool
    public let sourceBuild: String?
    private let accountBinding: String
    private let contentDigest: String
    private let records: [Entry]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, zone, complete, sourceBuild, accountBinding,
            contentDigest, records
    }

    private init(records: [Entry], accountBinding: String, sourceBuild: String?)
    {
        version = Self.formatVersion
        zone = PrivateCloudSyncStore.zoneName
        complete = true
        self.sourceBuild = sourceBuild
        self.accountBinding = accountBinding
        self.records = records
        contentDigest = Self.digest(
            records: records, accountBinding: accountBinding)
    }

    public init(from decoder: any Decoder) throws {
        try Self.requireKnownKeys(decoder, CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        zone = try values.decode(String.self, forKey: .zone)
        complete = try values.decode(Bool.self, forKey: .complete)
        sourceBuild = try values.decodeIfPresent(
            String.self, forKey: .sourceBuild)
        accountBinding = try values.decode(String.self, forKey: .accountBinding)
        contentDigest = try values.decode(String.self, forKey: .contentDigest)
        records = try values.decode([Entry].self, forKey: .records).sorted {
            $0.name < $1.name
        }
        try validate()
    }

    private static func digest(records: [Entry], accountBinding: String)
        -> String
    {
        var hasher = SHA256()
        func frame(_ data: Data) {
            let prefix = Data("\(data.count):".utf8)
            hasher.update(data: prefix)
            hasher.update(data: data)
        }
        frame(Data("BleatPrivateCloudBackup.v2".utf8))
        frame(Data(accountBinding.utf8))
        for record in records {
            frame(Data(record.kind.rawValue.utf8))
            frame(Data(record.name.utf8))
            frame(record.payload)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func binding(container: String, cloudUserRecordName: String)
        -> String
    {
        let text =
            "BleatPrivateCloudBackup.v2\u{0}\(container)\u{0}\(cloudUserRecordName)"
        return SHA256.hash(data: Data(text.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    static func capture(
        records: [Entry], accountBinding: String, sourceBuild: String? = nil
    ) throws -> Self {
        let backup = Self(
            records: records.sorted { $0.name < $1.name },
            accountBinding: accountBinding, sourceBuild: sourceBuild
        )
        try backup.validate()
        return backup
    }

    public static func decode(_ data: Data) throws -> Self {
        struct Header: Decodable { let version: Int }
        guard data.count <= maximumArchiveBytes else {
            throw Failure.archiveTooLarge
        }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else {
            throw Failure.invalidBackup
        }
        guard header.version == formatVersion else {
            throw Failure.unsupportedVersion
        }
        do {
            return try decoder.decode(Self.self, from: data)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.invalidBackup
        }
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumArchiveBytes else {
            throw Failure.archiveTooLarge
        }
        return data
    }

    public func preview() throws -> Preview {
        try validate()
        return validatedPreview()
    }

    private func validatedPreview() -> Preview {
        var counts = Dictionary(
            uniqueKeysWithValues: Kind.allCases.map { ($0.rawValue, 0) })
        for record in records { counts[record.kind.rawValue, default: 0] += 1 }
        return Preview(
            version: version, sourceBuild: sourceBuild, recordsByType: counts,
            recordCount: records.count
        )
    }

    struct RestoreMaterial: Equatable, Sendable {
        let accountBinding: String
        let digest: String
        let records: [Entry]
    }

    func restoreMaterial() throws -> RestoreMaterial {
        try validate()
        return RestoreMaterial(
            accountBinding: accountBinding, digest: contentDigest,
            records: records)
    }

    func reboundForIsolatedTesting(to targetBinding: String) throws -> Self {
        try validate()
        return try Self.capture(
            records: records, accountBinding: targetBinding,
            sourceBuild: sourceBuild)
    }

    /// Only plans replacement; it never produces CloudKit write requests.
    public func planReplacing(_ current: Self) throws -> ReplacePlan {
        try validate()
        try current.validate()
        guard accountBinding == current.accountBinding, zone == current.zone
        else {
            throw Failure.accountMismatch
        }
        let present = Dictionary(
            uniqueKeysWithValues: current.records.map { ($0.name, $0) })
        let target = Dictionary(
            uniqueKeysWithValues: records.map { ($0.name, $0) })
        var create = 0
        var replace = 0
        var unchanged = 0
        var bytes = 0
        var accountsAddedOrChanged = 0
        for (name, record) in target {
            if let existing = present[name] {
                guard existing.kind == record.kind else {
                    throw Failure.invalidRecord
                }
                if existing == record {
                    unchanged += 1
                } else {
                    replace += 1
                    bytes += record.payload.count
                    if record.kind == .account { accountsAddedOrChanged += 1 }
                }
            } else {
                create += 1
                bytes += record.payload.count
                if record.kind == .account { accountsAddedOrChanged += 1 }
            }
        }
        let removals = present.values.filter { target[$0.name] == nil }
        return ReplacePlan(
            source: validatedPreview(), current: current.validatedPreview(),
            create: create, replace: replace, remove: removals.count,
            unchanged: unchanged,
            accountRecordsRemoved: removals.filter { $0.kind == .account }
                .count,
            accountRecordsAddedOrChanged: accountsAddedOrChanged,
            fitsSingleOperation: create + replace + removals.count <= 200
                && bytes <= 1_500_000
        )
    }

    /// Rehearses exact replacement in a throwaway dictionary, verifies a
    /// re-export against the backup, and never contacts a service.
    public func rehearseReplacing(_ current: Self) throws -> ReplacePlan {
        let plan = try planReplacing(current)
        var stage = Dictionary(
            uniqueKeysWithValues: current.records.map { ($0.name, $0) })
        let desired = Dictionary(
            uniqueKeysWithValues: records.map { ($0.name, $0) })
        var removed = 0
        var created = 0
        var updated = 0
        for name in stage.keys.filter({ desired[$0] == nil }) {
            stage.removeValue(forKey: name)
            removed += 1
        }
        for (name, record) in desired where stage[name] != record {
            if stage.updateValue(record, forKey: name) == nil {
                created += 1
            } else {
                updated += 1
            }
        }
        let reexport = try Self.capture(
            records: Array(stage.values),
            accountBinding: current.accountBinding, sourceBuild: sourceBuild
        )
        guard created == plan.create, updated == plan.replace,
            removed == plan.remove,
            try reexport.encoded() == encoded()
        else { throw Failure.invalidBackup }
        return plan
    }

    private func validate() throws {
        guard version == Self.formatVersion else {
            throw Failure.unsupportedVersion
        }
        guard complete else { throw Failure.incompleteCapture }
        guard zone == PrivateCloudSyncStore.zoneName,
            accountBinding.utf8.count == 64,
            accountBinding.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            }),
            sourceBuild.map({
                !$0.isEmpty && $0.utf8.count <= 64
                    && $0.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 }
            }) != false
        else { throw Failure.invalidBackup }
        guard records.count <= Self.maximumRecords else {
            throw Failure.archiveTooLarge
        }
        guard contentDigest.utf8.count == 64,
            contentDigest
                == Self.digest(records: records, accountBinding: accountBinding)
        else { throw Failure.invalidBackup }
        var aliases: [AccountID: AccountID] = [:]
        var names = Set<String>()
        var remaining = Self.maximumPayloadBytes
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        for entry in records {
            guard entry.payload.count <= remaining,
                entry.payload.count <= Self.maximumRecordBytes
            else { throw Failure.archiveTooLarge }
            remaining -= entry.payload.count
            guard names.insert(entry.name).inserted else {
                throw Failure.duplicateRecord
            }
            do {
                let shape: Data
                let name: String
                switch entry.kind {
                case .account:
                    let source = try Self.validateAccountJSON(entry.payload)
                    let account: ServerAccount
                    var sourceAliases: [AccountID] = []
                    if source["schemaVersion"] != nil {
                        let versioned = try decoder.decode(
                            CloudServerAccountRecordPayload.self,
                            from: entry.payload
                        )
                        guard
                            CloudServerAccountRecordPayload
                                .supportedSchemaVersions
                                .contains(versioned.schemaVersion),
                            versioned.supersededPayloadDigest.map({
                                $0.count == 32
                            }) != false
                        else { throw Failure.unsupportedData }
                        account = versioned.account
                        sourceAliases = versioned.legacyAccountIDs
                        shape = try encoder.encode(versioned)
                    } else {
                        account = try decoder.decode(
                            ServerAccount.self, from: entry.payload)
                        shape = try encoder.encode(account)
                    }
                    let canonical = AccountID.canonical(
                        server: account.server, userID: account.user.id)
                    for identifier in sourceAliases + [account.id, canonical] {
                        guard !identifier.rawValue.isEmpty,
                            aliases[identifier].map({ $0 == canonical })
                                != false
                        else { throw Failure.ambiguousAccount }
                        aliases[identifier] = canonical
                    }
                    name = "account.\(account.id.rawValue)"
                case .configuration:
                    let value = try decoder.decode(
                        CloudConfigurationSnapshot.self, from: entry.payload)
                    try CloudConfigurationStore.validate(value)
                    shape = try encoder.encode(value)
                    name = "configuration.singleton"
                case .listening:
                    let value = try ListeningSegmentCodec.decode(entry.payload)
                    shape = try ListeningSegmentCodec.encode(value)
                    name = "slice.\(value.id.uuidString.lowercased())"
                case .completion:
                    let value = try decoder.decode(
                        CompletionMilestone.self, from: entry.payload)
                    guard !value.accountID.rawValue.isEmpty,
                        !value.itemID.rawValue.isEmpty,
                        value.duration.isFinite, value.duration > 0
                    else { throw Failure.invalidRecord }
                    shape = try encoder.encode(value)
                    name = "completion.\(value.id.uuidString.lowercased())"
                case .remoteSession:
                    let value = try decoder.decode(
                        RemoteListeningSession.self, from: entry.payload)
                    guard !value.accountID.rawValue.isEmpty,
                        !value.itemID.rawValue.isEmpty,
                        !value.id.rawValue.isEmpty,
                        value.startedAt <= value.updatedAt,
                        [value.realSeconds, value.currentTime, value.duration]
                            .allSatisfy({
                                $0.isFinite && $0 >= 0
                            })
                    else { throw Failure.invalidRecord }
                    shape = try encoder.encode(value)
                    name =
                        "remote.\(value.accountID.rawValue).\(value.id.rawValue)"
                }
                guard entry.name == name,
                    PrivateCloudHistoryArchive.matchesShape(
                        try JSONSerialization.jsonObject(with: entry.payload),
                        try JSONSerialization.jsonObject(with: shape)
                    )
                else { throw Failure.invalidRecord }
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure.invalidRecord
            }
        }
    }

    private static func validateAccountJSON(_ payload: Data) throws -> [String:
        Any]
    {
        guard
            let object = try JSONSerialization.jsonObject(with: payload)
                as? [String: Any]
        else { throw Failure.invalidRecord }
        let account: [String: Any]
        if object["schemaVersion"] != nil {
            guard let nested = object["account"] as? [String: Any] else {
                throw Failure.invalidRecord
            }
            account = nested
        } else {
            account = object
        }
        for key in ["server", "localServer"] {
            guard let value = account[key], !(value is NSNull) else { continue }
            guard let raw = value as? String,
                let url = URLComponents(string: raw),
                url.user == nil, url.password == nil, url.query == nil,
                url.fragment == nil
            else { throw Failure.unsafeAccountPayload }
        }
        return object
    }
}
