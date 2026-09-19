import Foundation
import SwiftData
import Testing

@testable import BleatCore

@Suite(.serialized)
final class ChapterTranscriptionJobTests {
    private let account = AccountID(rawValue: "account")
    private let item = LibraryItemID(rawValue: "book")

    @Test
    func testDiskReopenRetainsRunningSelectionAndAtomicCompletion() async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("jobs.store")
        var saved: ChapterTranscriptionJob
        do {
            let cache = ChapterTranscriptCache(
                modelContainer: try container(url: url))
            var job = Self.job()
            try await cache.saveJob(
                job, replacing: nil, accountID: account, itemID: item)
            let initial = job
            job.source = Self.source()
            job.chapters[0].state = .running
            job.revision += 1
            try await cache.saveJob(
                job, replacing: initial, accountID: account, itemID: item)
            let running = job
            job.chapters[0].state = .completed
            job.revision += 1
            try await cache.saveJob(
                job, replacing: running, transcript: Self.transcript(),
                accountID: account, itemID: item)
            let committed = job
            job.chapters[1].state = .running
            job.revision += 1
            try await cache.saveJob(
                job, replacing: committed, accountID: account, itemID: item)
            saved = job
        }
        let reopened = ChapterTranscriptCache(
            modelContainer: try container(url: url))
        let restored = try await reopened.job(accountID: account, itemID: item)
        #expect(restored == saved)
        #expect(restored?.completedChapterIDs == [1])
        #expect(restored?.unfinishedChapters.map(\.id) == [3])
        let transcripts = try await reopened.transcripts(
            accountID: account, itemID: item)
        #expect(
            CachedChapterTranscriptSearch.matches(
                query: "saved", in: transcripts
            ).count == 1)
    }

    @Test
    func testRejectsCompletionWithoutTranscriptAndStaleWrites() async throws {
        let cache = ChapterTranscriptCache(modelContainer: try container())
        let initial = Self.job()
        try await cache.saveJob(
            initial, replacing: nil, accountID: account, itemID: item)
        var next = initial
        next.source = Self.source()
        next.chapters[0].state = .completed
        next.revision += 1
        do {
            try await cache.saveJob(
                next, replacing: initial, accountID: account, itemID: item)
            Issue.record("Completion must require its transcript")
        } catch { #expect(error == .job(.invalidCheckpoint)) }
        let retained = try await cache.job(accountID: account, itemID: item)
        #expect(retained == initial)
        next.chapters[0].state = .running
        try await cache.saveJob(
            next, replacing: initial, accountID: account, itemID: item)
        do {
            try await cache.saveJob(
                next, replacing: initial, accountID: account, itemID: item)
            Issue.record("Stale writes must be rejected")
        } catch { #expect(error == .job(.staleRevision)) }
    }

    @Test
    func testBookAndAccountRemovalDeleteJobsOnlyInTheirScope() async throws {
        let cache = ChapterTranscriptCache(modelContainer: try container())
        let other = AccountID(rawValue: "other")
        try await cache.saveJob(
            Self.job(), replacing: nil, accountID: account, itemID: item)
        try await cache.saveJob(
            Self.job(), replacing: nil, accountID: other, itemID: item)
        let present = try await cache.containsData(
            accountID: account, itemID: item)
        #expect(present)
        try await cache.removeBook(accountID: account, itemID: item)
        let removed = try await cache.job(accountID: account, itemID: item)
        let retained = try await cache.job(accountID: other, itemID: item)
        #expect(removed == nil)
        #expect(retained != nil)
        try await cache.removeAccount(other)
        let absent = try await cache.containsData(
            accountID: other, itemID: item)
        #expect(!(absent))
    }

    @Test
    func testCurrentStoreUpgradesWithoutInventingLegacyJobs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("upgrade.store")
        do {
            let schema = Schema(
                versionedSchema: BleatPersistenceSchemaV0_1_4.self)
            let old = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: url)])
            let cache = ChapterTranscriptCache(modelContainer: old)
            try await cache.save(
                Self.transcript(), accountID: account, itemID: item)
            try await cache.saveTaskState(
                CachedChapterTranscriptionTaskState(
                    taskID: UUID(), selectedChapterIDs: [1, 3],
                    completedChapterIDs: [1], currentChapterID: 3,
                    outcome: .cancelled, failure: .cancelled,
                    startedAt: .distantPast, finishedAt: Date(),
                    durationMilliseconds: 1), accountID: account, itemID: item)
        }
        let schema = Schema(versionedSchema: BleatPersistenceSchemaCurrent.self)
        let upgraded = try ModelContainer(
            for: schema,
            migrationPlan: BleatPersistenceSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: url)])
        let cache = ChapterTranscriptCache(modelContainer: upgraded)
        let legacy = try await cache.taskState(accountID: account, itemID: item)
        let job = try await cache.job(accountID: account, itemID: item)
        let transcripts = try await cache.transcripts(
            accountID: account, itemID: item)
        #expect(legacy?.completedChapterIDs == [1])
        #expect(job == nil)
        #expect(transcripts.count == 1)
        try await cache.saveJob(
            Self.job(), replacing: nil, accountID: account, itemID: item)
    }

    @Test
    func testReadOnlyCommitFailureRollsBackTranscriptAndCheckpoint()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("readonly.store")
        var running = Self.job()
        do {
            let cache = ChapterTranscriptCache(
                modelContainer: try container(url: url))
            try await cache.saveJob(
                running, replacing: nil, accountID: account, itemID: item)
            let initial = running
            running.source = Self.source()
            running.chapters[0].state = .running
            running.revision += 1
            try await cache.saveJob(
                running, replacing: initial, accountID: account, itemID: item)
        }
        do {
            let schema = Schema([
                CachedChapterTranscriptRecord.self,
                CachedChapterTranscriptionTaskRecord.self,
                CachedChapterTranscriptionJobRecord.self,
            ])
            let readOnly = try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration(
                        schema: schema, url: url, allowsSave: false)
                ])
            let cache = ChapterTranscriptCache(modelContainer: readOnly)
            var completed = running
            completed.chapters[0].state = .completed
            completed.revision += 1
            do {
                try await cache.saveJob(
                    completed, replacing: running,
                    transcript: Self.transcript(), accountID: account,
                    itemID: item)
                Issue.record("Read-only store must reject the transaction")
            } catch { #expect(error == .persistenceFailed) }
            let job = try await cache.job(accountID: account, itemID: item)
            let transcripts = try await cache.transcripts(
                accountID: account, itemID: item)
            #expect(job == running)
            #expect(transcripts.isEmpty)
        }
        let cache = ChapterTranscriptCache(
            modelContainer: try container(url: url))
        let job = try await cache.job(accountID: account, itemID: item)
        let transcripts = try await cache.transcripts(
            accountID: account, itemID: item)
        #expect(job == running)
        #expect(transcripts.isEmpty)
    }

    @Test
    func testIdentityMigrationMovesJobAndPreservesConflictingJobs() async throws
    {
        let schema = Schema(BleatPersistenceModelCatalog.currentModelTypes)
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            ])
        let cache = ChapterTranscriptCache(modelContainer: container)
        let store = AccountStore(modelContainer: container)
        let canonical = AccountID(rawValue: "canonical")
        let original = Self.job()
        try await cache.saveJob(
            original, replacing: nil, accountID: account, itemID: item)
        _ = try await store.applyIdentityMigrations([
            AccountIdentityMigration(legacyID: account, canonicalID: canonical)
        ])
        let moved = try await cache.job(accountID: canonical, itemID: item)
        let old = try await cache.job(accountID: account, itemID: item)
        #expect(moved == original)
        #expect(old == nil)
        let secondLegacy = AccountID(rawValue: "second-legacy")
        let conflicting = Self.job()
        try await cache.saveJob(
            conflicting, replacing: nil, accountID: secondLegacy, itemID: item)
        _ = try await store.applyIdentityMigrations([
            AccountIdentityMigration(
                legacyID: secondLegacy, canonicalID: canonical)
        ])
        let preserved = try await cache.job(
            accountID: secondLegacy, itemID: item)
        let unchanged = try await cache.job(accountID: canonical, itemID: item)
        #expect(preserved == conflicting)
        #expect(unchanged == original)
    }

    @Test
    func testStaleCheckpointCannotRecreateDeletedJob() async throws {
        let cache = ChapterTranscriptCache(modelContainer: try container())
        let original = Self.job()
        try await cache.saveJob(
            original, replacing: nil, accountID: account, itemID: item)
        try await cache.removeBook(accountID: account, itemID: item)
        var next = original
        next.revision += 1
        do {
            try await cache.saveJob(
                next, replacing: original, accountID: account, itemID: item)
            Issue.record("Deleted job must not be recreated by a stale update")
        } catch { #expect(error == .job(.staleRevision)) }
    }

    @Test
    func testRejectsMalformedCheckpointWithoutHidingTranscriptText()
        async throws
    {
        let container = try container()
        let cache = ChapterTranscriptCache(modelContainer: container)
        try await cache.save(
            Self.transcript(), accountID: account, itemID: item)
        let context = ModelContext(container)
        let key = [account.rawValue, item.rawValue].map {
            "\($0.utf8.count):\($0)"
        }.joined()
        context.insert(
            CachedChapterTranscriptionJobRecord(
                jobKey: key, accountID: account.rawValue,
                libraryItemID: item.rawValue, payload: Data("{}".utf8),
                updatedAt: Date()))
        try context.save()
        do {
            _ = try await cache.job(accountID: account, itemID: item)
            Issue.record("Incomplete checkpoint must be rejected")
        } catch { #expect(error == .job(.invalidCheckpoint)) }
        let transcripts = try await cache.transcripts(
            accountID: account, itemID: item)
        #expect(transcripts.count == 1)
    }

    @MainActor
    @Test
    func testPersistenceOperationsStayOffMainThreadWhenCreatedOnMainActor()
        async throws
    {
        let cache = ChapterTranscriptCache(modelContainer: try container())
        let wasMain = try await cache.saveJobAndInspectThread(
            Self.job(), accountID: account, itemID: item)
        #expect(!(wasMain))
    }

    @Test
    func testRejectsExhaustedRevisionWithoutOverflow() async throws {
        let cache = ChapterTranscriptCache(modelContainer: try container())
        var job = Self.job()
        job.revision = Int.max
        #expect(!(job.isValid))
        do {
            try await cache.saveJob(
                job, replacing: nil, accountID: account, itemID: item)
            Issue.record("Exhausted revisions must be rejected")
        } catch { #expect(error == .job(.invalidCheckpoint)) }
    }

    private func container(url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([
            CachedChapterTranscriptRecord.self,
            CachedChapterTranscriptionTaskRecord.self,
            CachedChapterTranscriptionJobRecord.self,
        ])
        let configuration =
            url.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func job() -> ChapterTranscriptionJob {
        ChapterTranscriptionJob(
            localeIdentifier: "en-AU",
            chapters: [
                ChapterTranscriptionJobChapter(id: 1, start: 0, end: 1),
                ChapterTranscriptionJobChapter(id: 3, start: 1, end: 2),
            ])
    }

    private static func source() -> ChapterTranscriptionSourceIdentity {
        ChapterTranscriptionSourceIdentity(
            downloadID: DownloadID(rawValue: "download"),
            tracks: [
                ChapterTranscriptionSourceTrack(
                    index: 0, inode: nil, expectedBytes: 5, observedBytes: 5,
                    start: 0, duration: 2, validator: nil, fileIdentifier: 1,
                    modifiedAt: Date(timeIntervalSince1970: 1))
            ])
    }

    private static func transcript() -> CachedChapterTranscript {
        CachedChapterTranscript(
            chapterID: 1, chapterTitle: "One", chapterStartMilliseconds: 0,
            chapterEndMilliseconds: 1_000, localeIdentifier: "en-AU",
            segments: [
                CachedTranscriptSegment(
                    startMilliseconds: 0, endMilliseconds: 500,
                    text: "Saved chapter")
            ])
    }
}

extension ChapterTranscriptCache {
    fileprivate func saveJobAndInspectThread(
        _ job: ChapterTranscriptionJob, accountID: AccountID,
        itemID: LibraryItemID
    ) throws -> Bool {
        let wasMain = Thread.isMainThread
        try saveJob(job, replacing: nil, accountID: accountID, itemID: itemID)
        return wasMain
    }
}
