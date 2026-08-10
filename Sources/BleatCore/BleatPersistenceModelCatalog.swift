import SwiftData

public enum BleatPersistenceModelCatalog {
    public static let allModelTypes: [any PersistentModel.Type] = [
        ServerAccountRecord.self,
        CachedLibraryCollectionRecord.self,
        CachedLibraryRecord.self,
        CachedLibraryPageRecord.self,
        CachedLibrarySearchRecord.self,
        CachedLibraryHomeRecord.self,
        CachedLibraryBookDetailRecord.self,
        CachedChapterTranscriptRecord.self,
        CachedChapterTranscriptionTaskRecord.self,
        ListeningSliceRecord.self,
        CompletionMilestoneRecord.self,
        RemoteListeningSessionRecord.self,
        StatisticsSessionAccountingRecord.self,
    ]
}
