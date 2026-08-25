import Foundation
import SwiftData

public enum AccountConnectionState: String, Codable, Sendable {
    case connected
    case offline
    case reauthenticationRequired
}

public enum ServerAccountValidationError: Error, Equatable, Sendable {
    case invalidAccountID
    case invalidRemoteUserID
    case invalidUsername
    case invalidServerVersion
    case localAuthenticationUnavailable
    case serverMismatch
}

public struct ServerAccount: Codable, Hashable, Identifiable, Sendable {
    public let id: AccountID
    public let server: NormalizedServerURL
    public let localServer: NormalizedServerURL?
    public let localServerValidated: Bool
    public let serverVersion: String
    public let authenticationMethods: [AuthenticationMethod]
    public let user: AuthenticatedUser
    public let connectionState: AccountConnectionState

    public init(
        id: AccountID,
        server: NormalizedServerURL,
        localServer: NormalizedServerURL? = nil,
        localServerValidated: Bool = false,
        serverVersion: String,
        authenticationMethods: [AuthenticationMethod],
        user: AuthenticatedUser,
        connectionState: AccountConnectionState = .connected
    ) throws(ServerAccountValidationError) {
        guard !id.rawValue.isEmpty else {
            throw .invalidAccountID
        }
        guard !user.id.rawValue.isEmpty else {
            throw .invalidRemoteUserID
        }
        guard !user.username.isEmpty,
              user.username.rangeOfCharacter(
                  from: .controlCharacters
              ) == nil
        else {
            throw .invalidUsername
        }
        guard AudiobookshelfServerVersion(serverVersion) != nil else {
            throw .invalidServerVersion
        }
        guard authenticationMethods.contains(.local)
            || authenticationMethods.contains(.openID)
        else {
            throw .localAuthenticationUnavailable
        }
        self.id = id
        self.server = server
        self.localServer = localServer == server ? nil : localServer
        self.localServerValidated =
            self.localServer != nil && localServerValidated
        self.serverVersion = serverVersion
        self.authenticationMethods = authenticationMethods
        self.user = user
        self.connectionState = connectionState
    }

    public init(
        authenticatedAccount: AuthenticatedAccount,
        discoveredServer: DiscoveredServer
    ) throws(ServerAccountValidationError) {
        guard authenticatedAccount.server == discoveredServer.baseURL else {
            throw .serverMismatch
        }
        try self.init(
            id: authenticatedAccount.id,
            server: authenticatedAccount.server,
            serverVersion: discoveredServer.version.original,
            authenticationMethods: discoveredServer.authenticationMethods,
            user: authenticatedAccount.user
        )
    }

    public var supportsLocalAuthentication: Bool {
        authenticationMethods.contains(.local)
    }

    public var supportsOpenIDAuthentication: Bool {
        authenticationMethods.contains(.openID)
    }

    public func updatingConnectionState(
        _ state: AccountConnectionState
    ) throws(ServerAccountValidationError) -> ServerAccount {
        try ServerAccount(
            id: id,
            server: server,
            localServer: localServer,
            localServerValidated: localServerValidated,
            serverVersion: serverVersion,
            authenticationMethods: authenticationMethods,
            user: user,
            connectionState: state
        )
    }

    public func updatingLocalServer(
        _ localServer: NormalizedServerURL?,
        validated: Bool = false
    ) throws(ServerAccountValidationError) -> ServerAccount {
        try ServerAccount(
            id: id,
            server: server,
            localServer: localServer,
            localServerValidated: validated,
            serverVersion: serverVersion,
            authenticationMethods: authenticationMethods,
            user: user,
            connectionState: connectionState
        )
    }

    func reidentified(
        as accountID: AccountID
    ) throws(ServerAccountValidationError) -> ServerAccount {
        try ServerAccount(
            id: accountID,
            server: server,
            localServer: localServer,
            localServerValidated: localServerValidated,
            serverVersion: serverVersion,
            authenticationMethods: authenticationMethods,
            user: user,
            connectionState: connectionState
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case server
        case localServer
        case localServerValidated
        case serverVersion
        case authenticationMethods
        case user
        case connectionState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(AccountID.self, forKey: .id),
                server: container.decode(
                    NormalizedServerURL.self,
                    forKey: .server
                ),
                localServer: container.decodeIfPresent(
                    NormalizedServerURL.self,
                    forKey: .localServer
                ),
                localServerValidated: try container.decodeIfPresent(
                    Bool.self,
                    forKey: .localServerValidated
                ) ?? false,
                serverVersion: container.decode(
                    String.self,
                    forKey: .serverVersion
                ),
                authenticationMethods: container.decode(
                    [AuthenticationMethod].self,
                    forKey: .authenticationMethods
                ),
                user: container.decode(
                    AuthenticatedUser.self,
                    forKey: .user
                ),
                connectionState: container.decode(
                    AccountConnectionState.self,
                    forKey: .connectionState
                )
            )
        } catch let error as ServerAccountValidationError {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Stored server account failed validation: \(error)"
                )
            )
        }
    }
}

@Model
public final class ServerAccountRecord {
    @Attribute(.unique)
    var accountID: String
    var serverURL: String
    var remoteUserID: String
    var profileData: Data
    var isActiveBrowsingAccount: Bool

    init(
        accountID: String,
        serverURL: String,
        remoteUserID: String,
        profileData: Data,
        isActiveBrowsingAccount: Bool
    ) {
        self.accountID = accountID
        self.serverURL = serverURL
        self.remoteUserID = remoteUserID
        self.profileData = profileData
        self.isActiveBrowsingAccount = isActiveBrowsingAccount
    }
}

@Model
public final class AccountIdentityAliasRecord {
    @Attribute(.unique)
    var legacyAccountID: String
    var canonicalAccountID: String

    init(legacyAccountID: String, canonicalAccountID: String) {
        self.legacyAccountID = legacyAccountID
        self.canonicalAccountID = canonicalAccountID
    }
}

public enum AccountCacheKind: String, Equatable, Sendable {
    case libraryCollection
    case library
    case libraryPage
    case librarySearch
    case libraryHome
    case bookDetail
    case chapterTranscript
    case transcriptionTask
}

public enum AccountCacheIdentityMigrationCause: Equatable, Sendable {
    case malformedKey
    case invalidPayload
    case ambiguousCollision
}

public struct AccountCacheIdentityMigrationResidual: Equatable, Sendable {
    public let legacyAccountID: AccountID
    public let canonicalAccountID: AccountID
    public let kind: AccountCacheKind
    public let cause: AccountCacheIdentityMigrationCause
}

public struct AccountIdentityMigrationReport: Equatable, Sendable {
    public let residuals: [AccountCacheIdentityMigrationResidual]

    public init(residuals: [AccountCacheIdentityMigrationResidual] = []) {
        self.residuals = residuals
    }
}

public enum AccountStoreError: Error, Equatable, Sendable {
    case accountNotFound(AccountID)
    case duplicateRemoteAccount(existingAccountID: AccountID)
    case profileEncodingFailed
    case invalidStoredAccount(AccountID)
    case contradictoryIdentityAlias(
        legacyID: AccountID,
        existingCanonicalID: AccountID,
        requestedCanonicalID: AccountID
    )
    case persistenceFailed
}

public struct AccountIdentityMigration: Equatable, Sendable {
    public let legacyID: AccountID
    public let canonicalID: AccountID

    public init(legacyID: AccountID, canonicalID: AccountID) {
        self.legacyID = legacyID
        self.canonicalID = canonicalID
    }
}

public enum AccountOnboardingError: Error, Equatable, Sendable {
    case localAuthenticationUnavailable
    case authenticationFailed(LocalAuthenticationError)
    case openIDAuthenticationUnavailable
    case openIDAuthenticationFailed(OpenIDAuthenticationError)
    case authenticationRequestFailed
    case invalidAccount(ServerAccountValidationError)
    case accountPersistenceFailed(AccountStoreError)
    case credentialRollbackFailed
}

public enum AccountLifecycleError: Error, Equatable, Sendable {
    case accountNotFound(AccountID)
    case logoutFailed(LogoutError)
    case logoutRequestFailed
    case accountStoreFailed(AccountStoreError)
}

@ModelActor
public actor AccountStore {
    public func legacyIdentityMigrations() throws(AccountStoreError)
        -> [AccountIdentityMigration]
    {
        try accounts().compactMap { account in
            let canonicalID = AccountID.canonical(
                server: account.server,
                userID: account.user.id
            )
            guard canonicalID != account.id else {
                return nil
            }
            return AccountIdentityMigration(
                legacyID: account.id,
                canonicalID: canonicalID
            )
        }
    }

    @discardableResult
    public func applyIdentityMigrations(
        _ migrations: [AccountIdentityMigration]
    ) throws(AccountStoreError) -> AccountIdentityMigrationReport {
        guard !migrations.isEmpty else { return AccountIdentityMigrationReport() }
        var mapping: [String: String] = [:]
        for migration in migrations {
            if let existing = mapping[migration.legacyID.rawValue],
                existing != migration.canonicalID.rawValue
            {
                throw .contradictoryIdentityAlias(
                    legacyID: migration.legacyID,
                    existingCanonicalID: AccountID(rawValue: existing),
                    requestedCanonicalID: migration.canonicalID
                )
            }
            mapping[migration.legacyID.rawValue] =
                migration.canonicalID.rawValue
        }
        return try applyIdentityChanges(mapping: mapping, replacements: [:])
    }

    @discardableResult
    public func replaceAccountIdentity(
        from legacyID: AccountID,
        with account: ServerAccount
    ) throws(AccountStoreError) -> AccountIdentityMigrationReport {
        guard legacyID != account.id else {
            try save(account)
            return AccountIdentityMigrationReport()
        }
        return try applyIdentityChanges(
            mapping: [legacyID.rawValue: account.id.rawValue],
            replacements: [legacyID.rawValue: account]
        )
    }

    private func applyIdentityChanges(
        mapping: [String: String],
        replacements: [String: ServerAccount]
    ) throws(AccountStoreError) -> AccountIdentityMigrationReport {
        do {
            let accountRecords = try modelContext.fetch(
                FetchDescriptor<ServerAccountRecord>()
            )
            for (legacy, canonical) in mapping
            where accountRecords.contains(where: {
                $0.accountID == canonical && $0.accountID != legacy
            }) {
                throw AccountStoreError.duplicateRemoteAccount(
                    existingAccountID: AccountID(rawValue: canonical)
                )
            }
            for record in accountRecords {
                guard let canonical = mapping[record.accountID] else {
                    continue
                }
                let migrated = try replacements[record.accountID]
                    ?? decode(record).reidentified(
                        as: AccountID(rawValue: canonical)
                    )
                record.accountID = canonical
                record.serverURL = migrated.server.url.absoluteString
                record.remoteUserID = migrated.user.id.rawValue
                record.profileData = try JSONEncoder().encode(migrated)
            }
            let aliases = try modelContext.fetch(
                FetchDescriptor<AccountIdentityAliasRecord>()
            )
            for (legacy, canonical) in mapping {
                if let alias = aliases.first(where: {
                    $0.legacyAccountID == legacy
                }) {
                    guard alias.canonicalAccountID == canonical else {
                        throw AccountStoreError.contradictoryIdentityAlias(
                            legacyID: AccountID(rawValue: legacy),
                            existingCanonicalID: AccountID(
                                rawValue: alias.canonicalAccountID
                            ),
                            requestedCanonicalID: AccountID(
                                rawValue: canonical
                            )
                        )
                    }
                } else {
                    modelContext.insert(AccountIdentityAliasRecord(
                        legacyAccountID: legacy,
                        canonicalAccountID: canonical
                    ))
                }
            }
            for record in try modelContext.fetch(
                FetchDescriptor<ListeningSliceRecord>()
            ) {
                if let canonical = mapping[record.accountID] {
                    record.accountID = canonical
                    record.privateCloudSynchronized = false
                }
            }
            for record in try modelContext.fetch(
                FetchDescriptor<CompletionMilestoneRecord>()
            ) {
                if let canonical = mapping[record.accountID] {
                    record.accountID = canonical
                    record.privateCloudSynchronized = false
                }
            }
            for record in try modelContext.fetch(
                FetchDescriptor<RemoteListeningSessionRecord>()
            ) {
                if let canonical = mapping[record.accountID] {
                    record.accountID = canonical
                    record.compositeID = RemoteListeningSessionRecord
                        .compositeID(
                            accountID: AccountID(rawValue: canonical),
                            sessionID: PlaybackSessionID(
                                rawValue: record.sessionID
                            )
                        )
                    record.privateCloudSynchronized = false
                }
            }
            for record in try modelContext.fetch(
                FetchDescriptor<PrivateCloudStatisticsDeletionRecord>()
            ) {
                if let canonical = mapping[record.accountID] {
                    record.accountID = canonical
                }
            }
            for record in try modelContext.fetch(
                FetchDescriptor<StatisticsSessionAccountingRecord>()
            ) {
                if let canonical = mapping[record.accountID] {
                    record.accountID = canonical
                    record.compositeID = StatisticsSessionAccountingRecord
                        .compositeID(
                            accountID: AccountID(rawValue: canonical),
                            sessionID: PlaybackSessionID(
                                rawValue: record.sessionID
                            )
                        )
                }
            }
            let residuals = try migrateLegacyCaches(mapping: mapping)
            try modelContext.save()
            return AccountIdentityMigrationReport(residuals: residuals)
        } catch let error as AccountStoreError {
            modelContext.rollback()
            throw error
        } catch {
            modelContext.rollback()
            throw .persistenceFailed
        }
    }

    public func identityAliases() throws(AccountStoreError)
        -> [AccountIdentityMigration]
    {
        do {
            return try modelContext.fetch(
                FetchDescriptor<AccountIdentityAliasRecord>()
            ).map {
                AccountIdentityMigration(
                    legacyID: AccountID(rawValue: $0.legacyAccountID),
                    canonicalID: AccountID(rawValue: $0.canonicalAccountID)
                )
            }.sorted { $0.legacyID.rawValue < $1.legacyID.rawValue }
        } catch {
            throw .persistenceFailed
        }
    }

    private func migrateLegacyCaches(
        mapping: [String: String]
    ) throws -> [AccountCacheIdentityMigrationResidual] {
        var residuals: [AccountCacheIdentityMigrationResidual] = []
        let decoder = JSONDecoder()

        func residual(
            accountID: String,
            kind: AccountCacheKind,
            cause: AccountCacheIdentityMigrationCause
        ) {
            guard let canonical = mapping[accountID] else { return }
            residuals.append(AccountCacheIdentityMigrationResidual(
                legacyAccountID: AccountID(rawValue: accountID),
                canonicalAccountID: AccountID(rawValue: canonical),
                kind: kind,
                cause: cause
            ))
        }

        for record in try modelContext.fetch(
            FetchDescriptor<CachedLibraryCollectionRecord>()
        ) {
            guard let canonical = mapping[record.accountID] else { continue }
            let records = try modelContext.fetch(
                FetchDescriptor<CachedLibraryCollectionRecord>()
            )
            if let existing = records.first(where: {
                $0.accountID == canonical && $0 !== record
            }) {
                if existing.refreshedAt >= record.refreshedAt {
                    modelContext.delete(record)
                } else {
                    modelContext.delete(existing)
                    record.accountID = canonical
                }
            } else {
                record.accountID = canonical
            }
        }

        func replacementKey(_ key: String, legacy: String, canonical: String)
            -> String?
        {
            let bytes = Array(key.utf8)
            guard let colon = bytes.firstIndex(of: 58), colon > 0,
                let length = Int(String(decoding: bytes[..<colon], as: UTF8.self))
            else { return nil }
            let valueStart = colon + 1
            let valueEnd = valueStart + length
            guard valueEnd <= bytes.count,
                String(decoding: bytes[valueStart..<valueEnd], as: UTF8.self)
                    == legacy
            else { return nil }
            return "\(canonical.utf8.count):\(canonical)"
                + String(decoding: bytes[valueEnd...], as: UTF8.self)
        }

        func migrate<Record: PersistentModel & AnyObject, Value: Decodable & Equatable>(
            _ records: [Record],
            kind: AccountCacheKind,
            account: ReferenceWritableKeyPath<Record, String>,
            key: ReferenceWritableKeyPath<Record, String>,
            payload: KeyPath<Record, Data>,
            timestamp: KeyPath<Record, Date>,
            value: Value.Type,
            identity: (Record) -> [String],
            targetKey: (Record, String, String) -> String?
        ) {
            let targetKeys: [ObjectIdentifier: String] = Dictionary(
                uniqueKeysWithValues: records.compactMap { record in
                    let legacy = record[keyPath: account]
                    guard let canonical = mapping[legacy],
                        let target = targetKey(record, legacy, canonical)
                    else { return nil }
                    return (ObjectIdentifier(record), target)
                }
            )
            var deleted: Set<ObjectIdentifier> = []
            for record in records {
                let recordIdentity = ObjectIdentifier(record)
                guard !deleted.contains(recordIdentity) else { continue }
                let legacy = record[keyPath: account]
                guard let canonical = mapping[legacy] else { continue }
                guard let targetKey = targetKey(record, legacy, canonical)
                else {
                    residual(accountID: legacy, kind: kind, cause: .malformedKey)
                    continue
                }
                guard let decoded = try? decoder.decode(
                    value,
                    from: record[keyPath: payload]
                ) else {
                    residual(accountID: legacy, kind: kind, cause: .invalidPayload)
                    continue
                }
                let collisions = records.filter {
                    let identity = ObjectIdentifier($0)
                    return $0 !== record && !deleted.contains(identity)
                        && ($0[keyPath: key] == targetKey
                            || targetKeys[identity] == targetKey)
                }
                guard let existing = collisions.first else {
                    record[keyPath: account] = canonical
                    record[keyPath: key] = targetKey
                    continue
                }
                guard let existingValue = try? decoder.decode(
                    value,
                    from: existing[keyPath: payload]
                ), identity(record) == identity(existing) else {
                    residual(accountID: legacy, kind: kind, cause: .ambiguousCollision)
                    continue
                }
                let recordDate = record[keyPath: timestamp]
                let existingDate = existing[keyPath: timestamp]
                if recordDate == existingDate && decoded != existingValue {
                    residual(accountID: legacy, kind: kind, cause: .ambiguousCollision)
                } else if recordDate > existingDate {
                    modelContext.delete(existing)
                    deleted.insert(ObjectIdentifier(existing))
                    record[keyPath: account] = canonical
                    record[keyPath: key] = targetKey
                } else {
                    modelContext.delete(record)
                    deleted.insert(recordIdentity)
                }
            }
        }

        migrate(
            try modelContext.fetch(FetchDescriptor<CachedLibraryRecord>()),
            kind: .library,
            account: \.accountID,
            key: \.cacheKey,
            payload: \.payload,
            timestamp: \.refreshedAt,
            value: LibrarySummary.self,
            identity: { [$0.libraryID, String($0.position)] },
            targetKey: { record, legacy, canonical in
                replacementKey(record.cacheKey, legacy: legacy, canonical: canonical)
            }
        )
        migrate(
            try modelContext.fetch(FetchDescriptor<CachedLibraryPageRecord>()),
            kind: .libraryPage,
            account: \.accountID,
            key: \.cacheKey,
            payload: \.payload,
            timestamp: \.refreshedAt,
            value: LibraryItemsPage.self,
            identity: { [$0.libraryID] },
            targetKey: { record, legacy, canonical in
                replacementKey(record.cacheKey, legacy: legacy, canonical: canonical)
            }
        )
        migrate(
            try modelContext.fetch(FetchDescriptor<CachedLibrarySearchRecord>()),
            kind: .librarySearch,
            account: \.accountID,
            key: \.cacheKey,
            payload: \.payload,
            timestamp: \.refreshedAt,
            value: LibrarySearchResults.self,
            identity: { [$0.libraryID] },
            targetKey: { record, legacy, canonical in
                replacementKey(record.cacheKey, legacy: legacy, canonical: canonical)
            }
        )
        migrate(
            try modelContext.fetch(FetchDescriptor<CachedLibraryHomeRecord>()),
            kind: .libraryHome,
            account: \.accountID,
            key: \.cacheKey,
            payload: \.payload,
            timestamp: \.refreshedAt,
            value: [LibraryBookShelf].self,
            identity: { [$0.libraryID] },
            targetKey: { record, legacy, canonical in
                replacementKey(record.cacheKey, legacy: legacy, canonical: canonical)
            }
        )
        migrate(
            try modelContext.fetch(FetchDescriptor<CachedLibraryBookDetailRecord>()),
            kind: .bookDetail,
            account: \.accountID,
            key: \.cacheKey,
            payload: \.payload,
            timestamp: \.refreshedAt,
            value: LibraryBookDetail.self,
            identity: { [$0.userID, $0.libraryID, $0.libraryItemID] },
            targetKey: { record, legacy, canonical in
                replacementKey(record.cacheKey, legacy: legacy, canonical: canonical)
            }
        )
        migrate(
            try modelContext.fetch(FetchDescriptor<CachedChapterTranscriptRecord>()),
            kind: .chapterTranscript,
            account: \.accountID,
            key: \.cacheKey,
            payload: \.payload,
            timestamp: \.updatedAt,
            value: CachedChapterTranscript.self,
            identity: { [$0.libraryItemID, String($0.chapterID)] },
            targetKey: { record, _, canonical in
                [canonical, record.libraryItemID, String(record.chapterID)]
                    .map { "\($0.utf8.count):\($0)" }.joined()
            }
        )
        migrate(
            try modelContext.fetch(
                FetchDescriptor<CachedChapterTranscriptionTaskRecord>()
            ),
            kind: .transcriptionTask,
            account: \.accountID,
            key: \.taskKey,
            payload: \.payload,
            timestamp: \.finishedAt,
            value: CachedChapterTranscriptionTaskState.self,
            identity: { [$0.libraryItemID] },
            targetKey: { record, _, canonical in
                [canonical, record.libraryItemID]
                    .map { "\($0.utf8.count):\($0)" }.joined()
            }
        )
        return residuals
    }
    public func save(
        _ account: ServerAccount,
        makeActive: Bool = false
    ) throws(AccountStoreError) {
        let records = try fetchRecords()
        if let duplicate = records.first(where: {
            $0.serverURL == account.server.url.absoluteString
                && $0.remoteUserID == account.user.id.rawValue
                && $0.accountID != account.id.rawValue
        }) {
            throw .duplicateRemoteAccount(
                existingAccountID: AccountID(
                    rawValue: duplicate.accountID
                )
            )
        }

        let profileData: Data
        do {
            profileData = try JSONEncoder().encode(account)
        } catch {
            throw .profileEncodingFailed
        }

        let shouldActivate = makeActive
            || records.isEmpty
            || !records.contains(where: \.isActiveBrowsingAccount)
        if shouldActivate {
            records.forEach {
                $0.isActiveBrowsingAccount = false
            }
        }
        if let existing = records.first(where: {
            $0.accountID == account.id.rawValue
        }) {
            existing.serverURL = account.server.url.absoluteString
            existing.remoteUserID = account.user.id.rawValue
            existing.profileData = profileData
            if shouldActivate {
                existing.isActiveBrowsingAccount = true
            }
        } else {
            modelContext.insert(ServerAccountRecord(
                accountID: account.id.rawValue,
                serverURL: account.server.url.absoluteString,
                remoteUserID: account.user.id.rawValue,
                profileData: profileData,
                isActiveBrowsingAccount: shouldActivate
            ))
        }
        try saveContext()
    }

    /// Stores an account restored from iCloud without making it usable until
    /// this device has authenticated the expected remote user.
    public func savePendingRestoredAccount(
        _ account: ServerAccount
    ) throws(AccountStoreError) {
        let pending: ServerAccount
        do {
            pending = try account.updatingConnectionState(
                .reauthenticationRequired
            )
        } catch {
            throw .profileEncodingFailed
        }
        try save(pending)
        let records = try fetchRecords()
        guard let record = records.first(where: {
            $0.accountID == pending.id.rawValue
        }) else {
            throw .accountNotFound(pending.id)
        }
        record.isActiveBrowsingAccount = false
        try saveContext()
    }

    public func accounts() throws(AccountStoreError) -> [ServerAccount] {
        try fetchRecords()
            .map(decode)
            .sorted {
                let usernameOrder = $0.user.username.localizedStandardCompare(
                    $1.user.username
                )
                if usernameOrder == .orderedSame {
                    return $0.server.url.absoluteString
                        < $1.server.url.absoluteString
                }
                return usernameOrder == .orderedAscending
            }
    }

    public func account(
        id: AccountID
    ) throws(AccountStoreError) -> ServerAccount? {
        guard let record = try fetchRecords().first(where: {
            $0.accountID == id.rawValue
        }) else {
            return nil
        }
        return try decode(record)
    }

    public func activeAccount() throws(AccountStoreError) -> ServerAccount? {
        guard let record = try fetchRecords().first(where: {
            $0.isActiveBrowsingAccount
        }) else {
            return nil
        }
        return try decode(record)
    }

    public func setActiveAccount(
        id: AccountID
    ) throws(AccountStoreError) {
        let records = try fetchRecords()
        guard records.contains(where: {
            $0.accountID == id.rawValue
        }) else {
            throw .accountNotFound(id)
        }
        records.forEach {
            $0.isActiveBrowsingAccount = $0.accountID == id.rawValue
        }
        try saveContext()
    }

    public func setConnectionState(
        _ state: AccountConnectionState,
        for id: AccountID
    ) throws(AccountStoreError) {
        let records = try fetchRecords()
        guard let record = records.first(where: {
            $0.accountID == id.rawValue
        }) else {
            throw .accountNotFound(id)
        }
        let account = try decode(record)
        let updated: ServerAccount
        do {
            updated = try account.updatingConnectionState(state)
            record.profileData = try JSONEncoder().encode(updated)
        } catch let error as AccountStoreError {
            throw error
        } catch {
            throw .profileEncodingFailed
        }
        try saveContext()
    }

    public func setLocalServer(
        _ localServer: NormalizedServerURL?,
        validated: Bool = false,
        for id: AccountID
    ) throws(AccountStoreError) {
        let records = try fetchRecords()
        guard let record = records.first(where: {
            $0.accountID == id.rawValue
        }) else {
            throw .accountNotFound(id)
        }
        let account = try decode(record)
        do {
            let updated = try account.updatingLocalServer(
                localServer,
                validated: validated
            )
            record.profileData = try JSONEncoder().encode(updated)
        } catch {
            throw .profileEncodingFailed
        }
        try saveContext()
    }

    @discardableResult
    public func removeAccount(
        id: AccountID
    ) throws(AccountStoreError) -> Bool {
        let records = try fetchRecords()
        guard let record = records.first(where: {
            $0.accountID == id.rawValue
        }) else {
            return false
        }
        let removedActiveAccount = record.isActiveBrowsingAccount
        modelContext.delete(record)
        do {
            let aliases = try modelContext.fetch(
                FetchDescriptor<AccountIdentityAliasRecord>()
            ).filter { $0.canonicalAccountID == id.rawValue }
            let legacyIDs = Set(aliases.map(\.legacyAccountID))
            for alias in aliases { modelContext.delete(alias) }
            for cached in try modelContext.fetch(
                FetchDescriptor<CachedLibraryCollectionRecord>()
            ) where legacyIDs.contains(cached.accountID) {
                modelContext.delete(cached)
            }
            for cached in try modelContext.fetch(
                FetchDescriptor<CachedLibraryRecord>()
            ) where legacyIDs.contains(cached.accountID) {
                modelContext.delete(cached)
            }
            for cached in try modelContext.fetch(
                FetchDescriptor<CachedLibraryPageRecord>()
            ) where legacyIDs.contains(cached.accountID) {
                modelContext.delete(cached)
            }
            for cached in try modelContext.fetch(
                FetchDescriptor<CachedLibrarySearchRecord>()
            ) where legacyIDs.contains(cached.accountID) {
                modelContext.delete(cached)
            }
            for cached in try modelContext.fetch(
                FetchDescriptor<CachedLibraryHomeRecord>()
            ) where legacyIDs.contains(cached.accountID) {
                modelContext.delete(cached)
            }
            for cached in try modelContext.fetch(
                FetchDescriptor<CachedLibraryBookDetailRecord>()
            ) where legacyIDs.contains(cached.accountID) {
                modelContext.delete(cached)
            }
            for cached in try modelContext.fetch(
                FetchDescriptor<CachedChapterTranscriptRecord>()
            ) where legacyIDs.contains(cached.accountID) {
                modelContext.delete(cached)
            }
            for cached in try modelContext.fetch(
                FetchDescriptor<CachedChapterTranscriptionTaskRecord>()
            ) where legacyIDs.contains(cached.accountID) {
                modelContext.delete(cached)
            }
        } catch {
            modelContext.rollback()
            throw .persistenceFailed
        }
        if removedActiveAccount,
           let replacement = records
               .filter({ $0 !== record })
               .sorted(by: { $0.accountID < $1.accountID })
               .first
        {
            replacement.isActiveBrowsingAccount = true
        }
        try saveContext()
        return true
    }

    private func fetchRecords() throws(AccountStoreError)
        -> [ServerAccountRecord]
    {
        do {
            return try modelContext.fetch(
                FetchDescriptor<ServerAccountRecord>()
            )
        } catch {
            throw .persistenceFailed
        }
    }

    private func decode(
        _ record: ServerAccountRecord
    ) throws(AccountStoreError) -> ServerAccount {
        do {
            return try JSONDecoder().decode(
                ServerAccount.self,
                from: record.profileData
            )
        } catch {
            throw .invalidStoredAccount(
                AccountID(rawValue: record.accountID)
            )
        }
    }

    private func saveContext() throws(AccountStoreError) {
        do {
            try modelContext.save()
        } catch {
            throw .persistenceFailed
        }
    }
}

extension AuthCoordinator {
    public func loginAndPersistAccount(
        accountID: AccountID,
        discoveredServer: DiscoveredServer,
        username: String,
        password: String,
        expectedUserID: UserID? = nil,
        accountStore: AccountStore,
        makeActive: Bool = true,
        onAuthenticationCompleted: @escaping @Sendable () async -> Void = {}
    ) async throws(AccountOnboardingError) -> ServerAccount {
        guard discoveredServer.authenticationMethods.contains(.local) else {
            throw .localAuthenticationUnavailable
        }

        let authentication: LocalAuthenticationResult
        do {
            authentication = try await Self.authenticateLocally(
                accountID: accountID,
                server: discoveredServer.baseURL,
                username: username,
                password: password,
                expectedUserID: expectedUserID,
                persistCredentials: false,
                transport: transport,
                credentialStore: credentialStore
            )
        } catch let error as LocalAuthenticationError {
            throw .authenticationFailed(error)
        } catch {
            throw .authenticationRequestFailed
        }

        let canonicalID = AccountID.canonical(
            server: discoveredServer.baseURL,
            userID: authentication.account.user.id
        )
        let authenticated = AuthenticatedAccount(
            id: canonicalID,
            server: authentication.account.server,
            user: authentication.account.user
        )
        do {
            let nativeLogin = try NativeLoginCredentials(
                userID: authenticated.user.id,
                username: username,
                password: password
            )
            try await credentialStore.save(
                authentication.tokens,
                nativeLogin: nativeLogin,
                for: canonicalID
            )
        } catch let error as TokenVaultError {
            switch error {
            case .missingEntitlement, .interactionNotAllowed:
                throw .authenticationFailed(.credentialStorageUnavailable)
            default:
                throw .authenticationFailed(.credentialPersistenceFailed)
            }
        } catch {
            throw .authenticationFailed(.credentialPersistenceFailed)
        }

        await onAuthenticationCompleted()

        let account: ServerAccount
        do {
            account = try ServerAccount(
                authenticatedAccount: authenticated,
                discoveredServer: discoveredServer
            )
        } catch let error {
            try await rollbackOnboardingCredentials(
                accountID: canonicalID,
                originalError: .invalidAccount(error)
            )
        }

        do {
            try await accountStore.save(account, makeActive: makeActive)
        } catch let error {
            try await rollbackOnboardingCredentials(
                accountID: canonicalID,
                originalError: .accountPersistenceFailed(error)
            )
        }
        return account
    }

    public func loginForPersistedAccountUpdate(
        previousAccountID: AccountID,
        discoveredServer: DiscoveredServer,
        username: String,
        password: String,
        expectedUserID: UserID,
        onAuthenticationCompleted: @escaping @Sendable () async -> Void = {}
    ) async throws(AccountOnboardingError) -> ServerAccount {
        guard discoveredServer.authenticationMethods.contains(.local) else {
            throw .localAuthenticationUnavailable
        }
        let authentication: LocalAuthenticationResult
        do {
            authentication = try await Self.authenticateLocally(
                accountID: previousAccountID,
                server: discoveredServer.baseURL,
                username: username,
                password: password,
                expectedUserID: expectedUserID,
                persistCredentials: false,
                transport: transport,
                credentialStore: credentialStore
            )
        } catch let error as LocalAuthenticationError {
            throw .authenticationFailed(error)
        } catch {
            throw .authenticationRequestFailed
        }
        let canonicalID = AccountID.canonical(
            server: discoveredServer.baseURL,
            userID: authentication.account.user.id
        )
        let authenticated = AuthenticatedAccount(
            id: canonicalID,
            server: authentication.account.server,
            user: authentication.account.user
        )
        let account: ServerAccount
        do {
            account = try ServerAccount(
                authenticatedAccount: authenticated,
                discoveredServer: discoveredServer
            )
            let nativeLogin = try NativeLoginCredentials(
                userID: authenticated.user.id,
                username: username,
                password: password
            )
            try await credentialStore.save(
                authentication.tokens,
                nativeLogin: nativeLogin,
                for: canonicalID
            )
        } catch let error as ServerAccountValidationError {
            throw .invalidAccount(error)
        } catch let error as TokenVaultError {
            switch error {
            case .missingEntitlement, .interactionNotAllowed:
                throw .authenticationFailed(.credentialStorageUnavailable)
            default:
                throw .authenticationFailed(.credentialPersistenceFailed)
            }
        } catch {
            throw .authenticationFailed(.credentialPersistenceFailed)
        }
        await onAuthenticationCompleted()
        return account
    }

    func rollbackOnboardingCredentials(
        accountID: AccountID,
        originalError: AccountOnboardingError
    ) async throws(AccountOnboardingError) -> Never {
        do {
            try await credentialStore.deleteCredentials(for: accountID)
        } catch {
            throw .credentialRollbackFailed
        }
        throw originalError
    }

    public func signOutPersistedAccount(
        accountID: AccountID,
        accountStore: AccountStore
    ) async throws(AccountLifecycleError) -> LogoutResult {
        guard let account = try await storedAccount(
            id: accountID,
            accountStore: accountStore
        ) else {
            throw .accountNotFound(accountID)
        }
        let result: LogoutResult
        do {
            result = try await logout(
                accountID: accountID,
                server: account.server
            )
        } catch let error as LogoutError {
            throw .logoutFailed(error)
        } catch {
            throw .logoutRequestFailed
        }
        do {
            try await accountStore.setConnectionState(
                .reauthenticationRequired,
                for: accountID
            )
        } catch let error {
            throw .accountStoreFailed(error)
        }
        return result
    }

    public func removePersistedAccount(
        accountID: AccountID,
        accountStore: AccountStore
    ) async throws(AccountLifecycleError) -> LogoutResult {
        guard let account = try await storedAccount(
            id: accountID,
            accountStore: accountStore
        ) else {
            throw .accountNotFound(accountID)
        }
        let result: LogoutResult
        do {
            result = try await logout(
                accountID: accountID,
                server: account.server
            )
        } catch let error as LogoutError {
            throw .logoutFailed(error)
        } catch {
            throw .logoutRequestFailed
        }
        do {
            _ = try await accountStore.removeAccount(id: accountID)
        } catch let error {
            throw .accountStoreFailed(error)
        }
        return result
    }

    public func removePersistedAccountFromDevice(
        accountID: AccountID,
        accountStore: AccountStore
    ) async throws(AccountLifecycleError) -> LogoutResult {
        guard let account = try await storedAccount(
            id: accountID,
            accountStore: accountStore
        ) else {
            throw .accountNotFound(accountID)
        }
        let result: LogoutResult
        do {
            result = try await logoutKeepingNativeLogin(
                accountID: accountID,
                server: account.server
            )
        } catch let error as LogoutError {
            throw .logoutFailed(error)
        } catch {
            throw .logoutRequestFailed
        }
        do {
            _ = try await accountStore.removeAccount(id: accountID)
        } catch let error {
            throw .accountStoreFailed(error)
        }
        return result
    }

    private func storedAccount(
        id: AccountID,
        accountStore: AccountStore
    ) async throws(AccountLifecycleError) -> ServerAccount? {
        do {
            return try await accountStore.account(id: id)
        } catch let error {
            throw .accountStoreFailed(error)
        }
    }
}
