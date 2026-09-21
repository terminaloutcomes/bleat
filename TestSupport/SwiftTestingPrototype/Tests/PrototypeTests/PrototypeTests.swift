import BleatCore
import Foundation
import SwiftData
import Testing

// Serialize timing-sensitive work; concurrency is exercised explicitly below.
@Suite(.serialized)
struct PrototypeTests {
    @Test func synchronousIdentity() {
        #expect(AccountID(rawValue: "a") != AccountID(rawValue: "b"))
    }

    @Test func typedThrowingValidation() {
        #expect(throws: ServerURLValidationError.empty) {
            try NormalizedServerURL("")
        }
    }

    @Test func bundledFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "server-urls", withExtension: "json"))
        let servers = try JSONDecoder().decode([NormalizedServerURL].self, from: Data(contentsOf: url))
        try #require(servers.count == 2)
        #expect(servers[0] == servers[1])
        #expect(servers[0].url.path == "/audiobookshelf")
    }

    @Test func concurrentActorCalls() async {
        let counter = PrototypeCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { await counter.increment() }
            }
        }
        #expect(await counter.value == 100)
    }

    @Test(.disabled("Intentional prototype skip; must be reported as skipped, never passed"))
    func intentionalSkip() {
        Issue.record("A disabled test body must not execute")
    }

    @Test func swiftDataAccountIsolation() async throws {
        let fixture = try TranscriptFixture()
        let transcript = Self.transcript(segmentCount: 1)
        let account = AccountID(rawValue: "prototype-a")
        let item = LibraryItemID(rawValue: "prototype-book")
        try await fixture.cache.save(transcript, accountID: account, itemID: item)
        let relaunched = ChapterTranscriptCache(modelContainer: fixture.container)
        #expect(try await relaunched.transcripts(accountID: account, itemID: item) == [transcript])
        #expect(try await relaunched.transcripts(accountID: AccountID(rawValue: "prototype-b"), itemID: item).isEmpty)
    }

    @Test func timedTranscriptRoundTrip() async throws {
        let fixture = try TranscriptFixture()
        let transcript = Self.transcript(segmentCount: 10_000)
        let account = AccountID(rawValue: "prototype-performance")
        let item = LibraryItemID(rawValue: "prototype-book")
        let clock = ContinuousClock()
        let start = clock.now
        try await fixture.cache.save(transcript, accountID: account, itemID: item)
        let restored = try await fixture.cache.transcripts(accountID: account, itemID: item)
        let elapsed = start.duration(to: clock.now)
        #expect(restored == [transcript])
        #expect(elapsed > .zero)
        #expect(elapsed < .seconds(10))
        print("perf-summary prototype.transcript.10kSegments.duration=\(elapsed)")
    }

    private static func transcript(segmentCount: Int) -> CachedChapterTranscript {
        CachedChapterTranscript(
            chapterID: 1, chapterTitle: "Prototype", chapterStartMilliseconds: 0,
            chapterEndMilliseconds: Int64(segmentCount * 1_000), localeIdentifier: "en",
            segments: (0..<segmentCount).map {
                CachedTranscriptSegment(startMilliseconds: Int64($0 * 1_000),
                    endMilliseconds: Int64(($0 + 1) * 1_000), text: "Segment \($0)")
            },
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

private actor PrototypeCounter {
    var value = 0
    func increment() { value += 1 }
}

private struct TranscriptFixture {
    let container: ModelContainer
    let cache: ChapterTranscriptCache

    init() throws {
        let schema = Schema([
            CachedChapterTranscriptRecord.self,
            CachedChapterTranscriptionTaskRecord.self,
            CachedChapterTranscriptionJobRecord.self,
        ])
        container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        cache = ChapterTranscriptCache(modelContainer: container)
    }
}
