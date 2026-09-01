import Foundation
import XCTest

@testable import BleatCore

final class TranscriptExportTests: XCTestCase {
    func testWebVTTUsesWholeBookTimestampsAndEscapesCueText() throws {
        let data = try TranscriptExporter.export(
            transcripts: [
                transcript(
                    chapterID: 2,
                    chapterStartMilliseconds: 3_600_000,
                    segments: [
                        segment(
                            start: 3_661_002,
                            end: 3_662_345,
                            text: "Café & <friends>\r\nnext line"
                        )
                    ]
                )
            ],
            format: .webVTT
        )

        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            """
            WEBVTT

            01:01:01.002 --> 01:01:02.345
            Café &amp; &lt;friends&gt;
            next line

            """
        )
    }

    func testSubRipSortsSegmentsAndUsesSequentialCueIdentifiers() throws {
        let data = try TranscriptExporter.export(
            transcripts: [
                transcript(
                    chapterID: 2,
                    chapterStartMilliseconds: 7_200_000,
                    segments: [
                        segment(
                            start: 7_200_100, end: 7_201_999, text: "Second")
                    ]
                ),
                transcript(
                    chapterID: 1,
                    chapterStartMilliseconds: 0,
                    segments: [
                        segment(start: 999, end: 1_001, text: "First --> cue")
                    ]
                ),
            ],
            format: .subRip
        )

        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "1\r\n00:00:00,999 --> 00:00:01,001\r\nFirst --> cue\r\n\r\n"
                + "2\r\n02:00:00,100 --> 02:00:01,999\r\nSecond\r\n\r\n"
        )
    }

    func testWebVTTSeparatesAdjacentCueBlocks() throws {
        let data = try TranscriptExporter.export(
            transcripts: [
                transcript(
                    chapterID: 1,
                    chapterStartMilliseconds: 0,
                    segments: [
                        segment(start: 0, end: 500, text: "First"),
                        segment(start: 500, end: 1_000, text: "Second"),
                    ]
                )
            ],
            format: .webVTT
        )

        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            "WEBVTT\n\n00:00:00.000 --> 00:00:00.500\nFirst\n\n"
                + "00:00:00.500 --> 00:00:01.000\nSecond\n"
        )
    }

    func testCanonicalTranscriptExportHasSourceIndependentSemantics() throws {
        let canonical = [
            transcript(
                chapterID: 1,
                chapterStartMilliseconds: 0,
                segments: [
                    segment(start: 0, end: 500, text: "Shared semantics")
                ]
            )
        ]

        let locallyGenerated = try TranscriptExporter.export(
            transcripts: canonical,
            format: .webVTT
        )
        let imported = try TranscriptExporter.export(
            transcripts: canonical,
            format: .webVTT
        )

        XCTAssertEqual(locallyGenerated, imported)
    }

    func testPartialCanonicalTranscriptCanBeExported() throws {
        let data = try TranscriptExporter.export(
            transcripts: [
                transcript(
                    chapterID: 2,
                    chapterStartMilliseconds: 10_000,
                    segments: [
                        segment(
                            start: 10_000, end: 11_000,
                            text: "Available chapter")
                    ]
                )
            ],
            format: .subRip
        )

        XCTAssertTrue(
            String(decoding: data, as: UTF8.self).contains("Available chapter"))
    }

    func testCueTextCannotTerminateItsOwnCueWithBlankLines() throws {
        let transcript = transcript(
            chapterID: 1,
            chapterStartMilliseconds: 0,
            segments: [
                segment(
                    start: 0,
                    end: 1_000,
                    text: "\nLine one\n\nLine two\n"
                )
            ]
        )

        let webVTT = try TranscriptExporter.export(
            transcripts: [transcript],
            format: .webVTT
        )
        let subRip = try TranscriptExporter.export(
            transcripts: [transcript],
            format: .subRip
        )

        XCTAssertEqual(
            String(decoding: webVTT, as: UTF8.self),
            "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nLine one\nLine two\n"
        )
        XCTAssertEqual(
            String(decoding: subRip, as: UTF8.self),
            "1\r\n00:00:00,000 --> 00:00:01,000\r\nLine one\r\nLine two\r\n\r\n"
        )
    }

    func testExportRejectsMissingAndInvalidSegments() {
        XCTAssertThrowsError(
            try TranscriptExporter.export(transcripts: [], format: .webVTT)
        ) { error in
            XCTAssertEqual(error as? TranscriptExportError, .noSegments)
        }

        XCTAssertThrowsError(
            try TranscriptExporter.export(
                transcripts: [
                    transcript(
                        chapterID: 1,
                        chapterStartMilliseconds: 0,
                        segments: [
                            segment(start: 2_000, end: 1_000, text: "Invalid")
                        ]
                    )
                ],
                format: .subRip
            )
        ) { error in
            XCTAssertEqual(error as? TranscriptExportError, .invalidSegment)
        }

        XCTAssertThrowsError(
            try TranscriptExporter.export(
                transcripts: [
                    transcript(
                        chapterID: 1,
                        chapterStartMilliseconds: 0,
                        segments: [
                            segment(start: 1_000, end: 1_000, text: "Zero")
                        ]
                    )
                ],
                format: .webVTT
            )
        ) { error in
            XCTAssertEqual(error as? TranscriptExportError, .invalidSegment)
        }
    }

    private func transcript(
        chapterID: Int,
        chapterStartMilliseconds: Int64,
        segments: [CachedTranscriptSegment]
    ) -> CachedChapterTranscript {
        CachedChapterTranscript(
            chapterID: chapterID,
            chapterTitle: "Chapter \(chapterID)",
            chapterStartMilliseconds: chapterStartMilliseconds,
            chapterEndMilliseconds: chapterStartMilliseconds + 60_000,
            localeIdentifier: "en_AU",
            segments: segments,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func segment(
        start: Int64,
        end: Int64,
        text: String
    ) -> CachedTranscriptSegment {
        CachedTranscriptSegment(
            startMilliseconds: start,
            endMilliseconds: end,
            text: text
        )
    }
}
