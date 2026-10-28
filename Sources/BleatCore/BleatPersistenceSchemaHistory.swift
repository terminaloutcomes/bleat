import Foundation
import SwiftData

/// The persisted model shapes shipped in each release. Keep the historical
/// types immutable: SwiftData uses them to identify stores created by that
/// release before applying the migration plan.
public enum BleatPersistenceSchemaV0_1_1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { .init(0, 1, 1) }

    public static var models: [any PersistentModel.Type] {
        [
            ServerAccountRecord.self,
            CachedLibraryCollectionRecord.self,
            CachedLibraryRecord.self,
            CachedLibraryPageRecord.self,
            CachedLibrarySearchRecord.self,
            CachedLibraryHomeRecord.self,
            CachedLibraryBookDetailRecord.self,
            CachedChapterTranscriptRecord.self,
            ListeningSliceRecord.self,
            CompletionMilestoneRecord.self,
            RemoteListeningSessionRecord.self,
            StatisticsSessionAccountingRecord.self,
        ]
    }

    @Model public final class ServerAccountRecord {
        @Attribute(.unique) var accountID: String
        var serverURL: String
        var remoteUserID: String
        var profileData: Data
        var isActiveBrowsingAccount: Bool

        init(
            accountID: String = "",
            serverURL: String = "",
            remoteUserID: String = "",
            profileData: Data = Data(),
            isActiveBrowsingAccount: Bool = false
        ) {
            self.accountID = accountID
            self.serverURL = serverURL
            self.remoteUserID = remoteUserID
            self.profileData = profileData
            self.isActiveBrowsingAccount = isActiveBrowsingAccount
        }
    }

    @Model public final class CachedLibraryCollectionRecord {
        @Attribute(.unique) var accountID: String
        var refreshedAt: Date
        init(accountID: String = "", refreshedAt: Date = .distantPast) {
            self.accountID = accountID
            self.refreshedAt = refreshedAt
        }
    }

    @Model public final class CachedLibraryRecord {
        @Attribute(.unique) var cacheKey: String
        var accountID: String
        var libraryID: String
        var position: Int
        var payload: Data
        var refreshedAt: Date
        init() {
            cacheKey = ""
            accountID = ""
            libraryID = ""
            position = 0
            payload = Data()
            refreshedAt = .distantPast
        }
    }

    @Model public final class CachedLibraryPageRecord {
        @Attribute(.unique) var cacheKey: String
        var accountID: String
        var libraryID: String
        var payload: Data
        var refreshedAt: Date
        init() {
            cacheKey = ""
            accountID = ""
            libraryID = ""
            payload = Data()
            refreshedAt = .distantPast
        }
    }

    @Model public final class CachedLibrarySearchRecord {
        @Attribute(.unique) var cacheKey: String
        var accountID: String
        var libraryID: String
        var payload: Data
        var refreshedAt: Date
        init() {
            cacheKey = ""
            accountID = ""
            libraryID = ""
            payload = Data()
            refreshedAt = .distantPast
        }
    }

    @Model public final class CachedLibraryHomeRecord {
        @Attribute(.unique) var cacheKey: String
        var accountID: String
        var libraryID: String
        var payload: Data
        var refreshedAt: Date
        init() {
            cacheKey = ""
            accountID = ""
            libraryID = ""
            payload = Data()
            refreshedAt = .distantPast
        }
    }

    @Model public final class CachedLibraryBookDetailRecord {
        @Attribute(.unique) var cacheKey: String
        var accountID: String
        var userID: String
        var libraryID: String
        var libraryItemID: String
        var payload: Data
        var refreshedAt: Date
        init() {
            cacheKey = ""
            accountID = ""
            userID = ""
            libraryID = ""
            libraryItemID = ""
            payload = Data()
            refreshedAt = .distantPast
        }
    }

    @Model public final class CachedChapterTranscriptRecord {
        @Attribute(.unique) var cacheKey: String
        var accountID: String
        var libraryItemID: String
        var chapterID: Int
        var payload: Data
        var updatedAt: Date
        init() {
            cacheKey = ""
            accountID = ""
            libraryItemID = ""
            chapterID = 0
            payload = Data()
            updatedAt = .distantPast
        }
    }

    @Model public final class ListeningSliceRecord {
        @Attribute(.unique) var eventID: UUID
        var accountID: String
        var itemID: String
        var sessionID: String
        var startedAt: Date
        var endedAt: Date
        var startPosition: Double
        var endPosition: Double
        var realSeconds: Double
        var audiobookSeconds: Double
        var playbackRate: Double
        var chapterID: Int?
        var chapterTitle: String?
        var chapterStart: Double?
        var chapterEnd: Double?
        var title: String
        var author: String
        var duration: Double
        init() {
            eventID = UUID()
            accountID = ""
            itemID = ""
            sessionID = ""
            startedAt = .distantPast
            endedAt = .distantPast
            startPosition = 0
            endPosition = 0
            realSeconds = 0
            audiobookSeconds = 0
            playbackRate = 1
            title = ""
            author = ""
            duration = 0
        }
    }

    @Model public final class CompletionMilestoneRecord {
        @Attribute(.unique) var eventID: UUID
        var accountID: String
        var itemID: String
        var completedAt: Date
        var duration: Double
        var title: String
        var author: String
        var evidence: String
        init() {
            eventID = UUID()
            accountID = ""
            itemID = ""
            completedAt = .distantPast
            duration = 0
            title = ""
            author = ""
            evidence = ""
        }
    }

    @Model public final class RemoteListeningSessionRecord {
        @Attribute(.unique) var compositeID: String
        var sessionID: String
        var accountID: String
        var itemID: String
        var startedAt: Date
        var updatedAt: Date
        var realSeconds: Double
        var currentTime: Double
        var duration: Double
        var title: String
        var author: String
        init() {
            compositeID = ""
            sessionID = ""
            accountID = ""
            itemID = ""
            startedAt = .distantPast
            updatedAt = .distantPast
            realSeconds = 0
            currentTime = 0
            duration = 0
            title = ""
            author = ""
        }
    }

    @Model public final class StatisticsSessionAccountingRecord {
        @Attribute(.unique) var compositeID: String
        var accountID: String
        var sessionID: String
        var confirmedRealSeconds: Double
        var uncertainRealSeconds: Double
        var updatedAt: Date
        init() {
            compositeID = ""
            accountID = ""
            sessionID = ""
            confirmedRealSeconds = 0
            uncertainRealSeconds = 0
            updatedAt = .distantPast
        }
    }
}

public enum BleatPersistenceSchemaV0_1_2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { .init(0, 1, 2) }

    public static var models: [any PersistentModel.Type] {
        BleatPersistenceSchemaV0_1_1.models + [
            CachedChapterTranscriptionTaskRecord.self
        ]
    }

    @Model public final class CachedChapterTranscriptionTaskRecord {
        @Attribute(.unique) var taskKey: String
        var accountID: String
        var libraryItemID: String
        var payload: Data
        var finishedAt: Date
        init(
            taskKey: String = "",
            accountID: String = "",
            libraryItemID: String = "",
            payload: Data = Data(),
            finishedAt: Date = .distantPast
        ) {
            self.taskKey = taskKey
            self.accountID = accountID
            self.libraryItemID = libraryItemID
            self.payload = payload
            self.finishedAt = finishedAt
        }
    }
}

public enum BleatPersistenceSchemaV0_1_3: VersionedSchema {
    public static var versionIdentifier: Schema.Version { .init(0, 1, 3) }
    public static var models: [any PersistentModel.Type] {
        BleatPersistenceSchemaV0_1_2.models
    }
}

public enum BleatPersistenceSchemaV0_1_7: VersionedSchema {
    public static var versionIdentifier: Schema.Version { .init(0, 1, 7) }
    public static let models: [any PersistentModel.Type] = [
        ServerAccountRecord.self,
        AccountIdentityAliasRecord.self,
        CachedLibraryCollectionRecord.self,
        CachedLibraryRecord.self,
        CachedLibraryPageRecord.self,
        CachedLibrarySearchRecord.self,
        CachedLibraryHomeRecord.self,
        CachedLibraryBookDetailRecord.self,
        CachedChapterTranscriptRecord.self,
        CachedChapterTranscriptionTaskRecord.self,
        CachedChapterTranscriptionJobRecord.self,
        ListeningSliceRecord.self,
        CompletionMilestoneRecord.self,
        RemoteListeningSessionRecord.self,
        PrivateCloudStatisticsDeletionRecord.self,
        StatisticsSessionAccountingRecord.self,
        StatisticsHistoryImportRecord.self,
        StatisticsSnapshotRecord.self,
    ]

    @Model
    public final class ListeningSliceRecord {
        #Index<ListeningSliceRecord>([\.privateCloudSynchronized])

        @Attribute(.unique)
        var eventID: UUID
        var accountID: String
        var itemID: String
        var sessionID: String
        var startedAt: Date
        var endedAt: Date
        var startPosition: Double
        var endPosition: Double
        var realSeconds: Double
        var audiobookSeconds: Double
        var playbackRate: Double
        var chapterID: Int?
        var chapterTitle: String?
        var chapterStart: Double?
        var chapterEnd: Double?
        var title: String
        var author: String
        var duration: Double
        var privateCloudSynchronized: Bool?

        init(_ slice: ListeningSlice) {
            eventID = slice.id
            accountID = slice.accountID.rawValue
            itemID = slice.itemID.rawValue
            sessionID = slice.sessionID.rawValue
            startedAt = slice.startedAt
            endedAt = slice.endedAt
            startPosition = slice.startPosition
            endPosition = slice.endPosition
            realSeconds = slice.realSeconds
            audiobookSeconds = slice.audiobookSeconds
            playbackRate = slice.playbackRate
            chapterID = slice.chapterID
            chapterTitle = slice.chapterTitle
            chapterStart = slice.chapterStart
            chapterEnd = slice.chapterEnd
            title = slice.title
            author = slice.author
            duration = slice.duration
            privateCloudSynchronized = false
        }

        var domainValue: ListeningSlice {
            ListeningSlice(
                id: eventID,
                accountID: AccountID(rawValue: accountID),
                itemID: LibraryItemID(rawValue: itemID),
                sessionID: PlaybackSessionID(rawValue: sessionID),
                startedAt: startedAt,
                endedAt: endedAt,
                startPosition: startPosition,
                endPosition: endPosition,
                realSeconds: realSeconds,
                audiobookSeconds: audiobookSeconds,
                playbackRate: playbackRate,
                chapterID: chapterID,
                chapterTitle: chapterTitle,
                chapterStart: chapterStart,
                chapterEnd: chapterEnd,
                title: title,
                author: author,
                duration: duration
            )
        }
    }

}

public enum BleatPersistenceSchemaV0_1_4: VersionedSchema {
    public static var versionIdentifier: Schema.Version { .init(0, 1, 4) }
    public static var models: [any PersistentModel.Type] {
        BleatPersistenceSchemaV0_1_7.models.filter {
            $0 != CachedChapterTranscriptionJobRecord.self
                && $0 != StatisticsHistoryImportRecord.self
                && $0 != StatisticsSnapshotRecord.self
        }
    }
}

public enum BleatPersistenceSchemaV0_1_5: VersionedSchema {
    public static var versionIdentifier: Schema.Version { .init(0, 1, 5) }
    public static var models: [any PersistentModel.Type] {
        BleatPersistenceSchemaV0_1_7.models.filter {
            $0 != StatisticsHistoryImportRecord.self
                && $0 != StatisticsSnapshotRecord.self
        }
    }
}

public enum BleatPersistenceSchemaV0_1_6: VersionedSchema {
    public static var versionIdentifier: Schema.Version { .init(0, 1, 6) }
    public static var models: [any PersistentModel.Type] {
        BleatPersistenceSchemaV0_1_7.models.filter {
            $0 != StatisticsSnapshotRecord.self
        }
    }
}

public enum BleatPersistenceSchemaV0_1_8: VersionedSchema {
    public static var versionIdentifier: Schema.Version { .init(0, 1, 8) }
    public static let models: [any PersistentModel.Type] = [
        ServerAccountRecord.self,
        AccountIdentityAliasRecord.self,
        CachedLibraryCollectionRecord.self,
        CachedLibraryRecord.self,
        CachedLibraryPageRecord.self,
        CachedLibrarySearchRecord.self,
        CachedLibraryHomeRecord.self,
        CachedLibraryBookDetailRecord.self,
        CachedChapterTranscriptRecord.self,
        CachedChapterTranscriptionTaskRecord.self,
        CachedChapterTranscriptionJobRecord.self,
        ListeningSliceRecord.self,
        CompletionMilestoneRecord.self,
        RemoteListeningSessionRecord.self,
        PrivateCloudStatisticsDeletionRecord.self,
        StatisticsSessionAccountingRecord.self,
        StatisticsHistoryImportRecord.self,
        StatisticsSnapshotRecord.self,
        PrivateCloudRecordMetadata.self,
        PrivateCloudStateRecord.self,
    ]
}

public enum BleatPersistenceSchemaV0_1_9: VersionedSchema {
    public static var versionIdentifier: Schema.Version { .init(0, 1, 9) }
    public static var models: [any PersistentModel.Type] {
        [

            ServerAccountRecord.self,
            FinishedProgressCheckpointRecord.self,
            AccountIdentityAliasRecord.self,
            CachedLibraryCollectionRecord.self,
            CachedLibraryRecord.self,
            CachedLibraryPageRecord.self,
            CachedLibrarySearchRecord.self,
            CachedLibraryHomeRecord.self,
            CachedLibraryBookDetailRecord.self,
            CachedChapterTranscriptRecord.self,
            CachedChapterTranscriptionTaskRecord.self,
            CachedChapterTranscriptionJobRecord.self,
            ListeningSliceRecord.self,
            CompletionMilestoneRecord.self,
            RemoteListeningSessionRecord.self,
            PrivateCloudStatisticsDeletionRecord.self,
            StatisticsSessionAccountingRecord.self,
            StatisticsHistoryImportRecord.self,
            StatisticsSnapshotRecord.self,
            PrivateCloudRecordMetadata.self,
            PrivateCloudStateRecord.self,
        ]
    }
    @Model
    public final class ListeningSliceRecord {
        #Index<ListeningSliceRecord>([\.privateCloudSynchronized])

        @Attribute(.unique)
        var eventID: UUID
        var accountID: String
        var itemID: String
        var sessionID: String
        var startedAt: Date
        var endedAt: Date
        var startPosition: Double
        var endPosition: Double
        var realSeconds: Double
        var audiobookSeconds: Double
        var playbackRate: Double
        var chapterID: Int?
        var chapterTitle: String?
        var chapterStart: Double?
        var chapterEnd: Double?
        var title: String
        var author: String
        var duration: Double
        var recordingFormat: ListeningRecordingFormat?
        var isFinalized: Bool?
        var privateCloudSynchronized: Bool?

        init(_ slice: ListeningSlice) {
            eventID = slice.id
            accountID = slice.accountID.rawValue
            itemID = slice.itemID.rawValue
            sessionID = slice.sessionID.rawValue
            startedAt = slice.startedAt
            endedAt = slice.endedAt
            startPosition = slice.startPosition
            endPosition = slice.endPosition
            realSeconds = slice.realSeconds
            audiobookSeconds = slice.audiobookSeconds
            playbackRate = slice.playbackRate
            chapterID = slice.chapterID
            chapterTitle = slice.chapterTitle
            chapterStart = slice.chapterStart
            chapterEnd = slice.chapterEnd
            title = slice.title
            author = slice.author
            duration = slice.duration
            recordingFormat = slice.recordingFormat
            isFinalized = slice.recordingState != .active
            privateCloudSynchronized = false
        }

        var domainValue: ListeningSlice {
            ListeningSlice(
                id: eventID,
                accountID: AccountID(rawValue: accountID),
                itemID: LibraryItemID(rawValue: itemID),
                sessionID: PlaybackSessionID(rawValue: sessionID),
                startedAt: startedAt,
                endedAt: endedAt,
                startPosition: startPosition,
                endPosition: endPosition,
                realSeconds: realSeconds,
                audiobookSeconds: audiobookSeconds,
                playbackRate: playbackRate,
                chapterID: chapterID,
                chapterTitle: chapterTitle,
                chapterStart: chapterStart,
                chapterEnd: chapterEnd,
                title: title,
                author: author,
                duration: duration, recordingFormat: recordingFormat,
                recordingState: recordingFormat == nil
                    ? nil : (isFinalized == false ? .active : .finalized)
            )
        }
    }

}

public enum BleatPersistenceSchemaCurrent: VersionedSchema {
    public static var versionIdentifier: Schema.Version { .init(0, 1, 10) }
    public static var models: [any PersistentModel.Type] {
        BleatPersistenceModelCatalog.currentModelTypes
    }
}

public enum BleatPersistenceSchemaMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [
            BleatPersistenceSchemaV0_1_1.self,
            BleatPersistenceSchemaV0_1_2.self,
            BleatPersistenceSchemaV0_1_4.self,
            BleatPersistenceSchemaV0_1_5.self,
            BleatPersistenceSchemaV0_1_6.self,
            BleatPersistenceSchemaV0_1_7.self,
            BleatPersistenceSchemaV0_1_8.self,
            BleatPersistenceSchemaV0_1_9.self,
            BleatPersistenceSchemaCurrent.self,
        ]
    }

    public static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: BleatPersistenceSchemaV0_1_1.self,
                toVersion: BleatPersistenceSchemaV0_1_2.self
            ),
            .lightweight(
                fromVersion: BleatPersistenceSchemaV0_1_2.self,
                toVersion: BleatPersistenceSchemaV0_1_4.self
            ),
            .lightweight(
                fromVersion: BleatPersistenceSchemaV0_1_4.self,
                toVersion: BleatPersistenceSchemaV0_1_5.self
            ),
            .lightweight(
                fromVersion: BleatPersistenceSchemaV0_1_5.self,
                toVersion: BleatPersistenceSchemaV0_1_6.self
            ),
            .lightweight(
                fromVersion: BleatPersistenceSchemaV0_1_6.self,
                toVersion: BleatPersistenceSchemaV0_1_7.self
            ),
            .lightweight(
                fromVersion: BleatPersistenceSchemaV0_1_7.self,
                toVersion: BleatPersistenceSchemaV0_1_8.self
            ),
            .lightweight(
                fromVersion: BleatPersistenceSchemaV0_1_8.self,
                toVersion: BleatPersistenceSchemaV0_1_9.self
            ),
            .lightweight(
                fromVersion: BleatPersistenceSchemaV0_1_9.self,
                toVersion: BleatPersistenceSchemaCurrent.self
            ),
        ]
    }
}

public enum BleatPersistenceSchemaHistory {
    public static let currentModelTypes = BleatPersistenceModelCatalog
        .currentModelTypes
}
