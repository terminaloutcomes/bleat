import Testing

@testable import BleatTranscription

@Suite("Whole-book transcript timeline")
struct WholeBookTranscriptTimelineTests {
    @Test("adds chapter offset and stores integer milliseconds")
    func addsChapterOffset() {
        let segment = WholeBookTranscriptTimeline.segment(
            relativeStartSeconds: 1.2344,
            relativeDurationSeconds: 2.5,
            chapterStartSeconds: 3_600,
            text: "Chapter text"
        )

        #expect(
            segment
                == TranscriptSegment(
                    startMilliseconds: 3_601_234,
                    endMilliseconds: 3_603_734,
                    text: "Chapter text"
                )
        )
    }

    @Test(
        "rejects invalid time values",
        arguments: [
            (Double.nan, 1.0, 0.0),
            (0.0, -1.0, 0.0),
            (0.0, 1.0, Double.infinity),
        ]
    )
    func rejectsInvalidTimes(
        relativeStart: Double,
        duration: Double,
        chapterStart: Double
    ) {
        #expect(
            WholeBookTranscriptTimeline.segment(
                relativeStartSeconds: relativeStart,
                relativeDurationSeconds: duration,
                chapterStartSeconds: chapterStart,
                text: "Text"
            ) == nil
        )
    }
}
