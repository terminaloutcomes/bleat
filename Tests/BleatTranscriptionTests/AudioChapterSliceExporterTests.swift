#if canImport(AVFoundation)
    import AVFoundation
    import Foundation
    import Testing
    @testable import BleatTranscription

    @Suite("Audio chapter slice exporter")
    struct AudioChapterSliceExporterTests {
        @Test("exports a bounded AAC chapter as a readable M4A")
        func exportsBoundedChapter() async throws {
            let sourceURL = temporaryURL(extension: "m4a")
            try writeSilence(to: sourceURL, durationSeconds: 1)
            let outputURL = try await AudioChapterSliceExporter.export(
                sourceURL: sourceURL,
                startSeconds: 0.25,
                durationSeconds: 0.5
            )
            defer {
                try? FileManager.default.removeItem(at: sourceURL)
                try? FileManager.default.removeItem(at: outputURL)
            }

            let outputFile = try AVAudioFile(forReading: outputURL)
            let duration =
                Double(outputFile.length)
                / outputFile.processingFormat.sampleRate
            #expect(duration > 0.45)
            #expect(duration < 0.55)

            let input = try SpeechChapterTranscriber.inputMetadata(
                audioFile: outputFile,
                fileURL: outputURL
            )
            #expect(input.durationMilliseconds > 450)
            #expect(input.durationMilliseconds < 550)
            #expect(input.byteCount > 0)
            #expect(input.container == .m4a)
            #expect(input.codec == .aac)
            #expect(input.sampleRateHz == 44_100)
            #expect(input.channelCount == 2)
        }

        @Test("transcodes an MP3 chapter into a readable M4A")
        func exportsMP3Chapter() async throws {
            let sourceURL = temporaryURL(extension: "mp3")
            let fixture = try #require(
                Data(base64Encoded: Self.silentMP3Fixture)
            )
            try fixture.write(to: sourceURL)
            let outputURL = try await AudioChapterSliceExporter.export(
                sourceURL: sourceURL,
                startSeconds: 0,
                durationSeconds: 0.2
            )
            defer {
                try? FileManager.default.removeItem(at: sourceURL)
                try? FileManager.default.removeItem(at: outputURL)
            }

            let outputFile = try AVAudioFile(forReading: outputURL)
            let input = try SpeechChapterTranscriber.inputMetadata(
                audioFile: outputFile,
                fileURL: outputURL
            )
            #expect(input.durationMilliseconds > 100)
            #expect(input.durationMilliseconds < 400)
            #expect(input.container == .m4a)
            #expect(input.codec == .aac)
        }

        private static let silentMP3Fixture =
            "SUQzBAAAAAAAIlRTU0UAAAAOAAADTGF2ZjYzLjEuMTAxAAAAAAAAAAAAAAD/+0DAAAAAAAAAAAAAAAAAAAAAAABJbmZvAAAADwAAAAsAAAUzADc3Nzc3Nzc3N0tLS0tLS0tLS19fX19fX19fX3Nzc3Nzc3Nzc4eHh4eHh4eHh5ubm5ubm5ubm6+vr6+vr6+vr8PDw8PDw8PDw9fX19fX19fX1+vr6+vr6+vr6////////////wAAAABMYXZjNjMuMS4AAAAAAAAAAAAAAAAkBC8AAAAAAAAFM/UBbxkAAAAAAP/7EMQAA8AAAaQAAAAgAAA0gAAABExBTUU0LjBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVMQU1FNC4wVVVV//sSxCmDwAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVMQU1FNC4wVVVV//sQxFODwAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUU0LjBVVVX/+xLEfQPAAAGkAAAAIAAANIAAAARVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUxBTUU0LjBVVVX/+xDEpwPAAAGkAAAAIAAANIAAAARVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVTEFNRTQuMFVVVf/7EsTQg8AAAaQAAAAgAAA0gAAABFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVf/7EMTWA8AAAaQAAAAgAAA0gAAABFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sSxNWDwAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//sQxNYDwAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVX/+xLE1YPAAAGkAAAAIAAANIAAAARVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVX/+xDE1gPAAAGkAAAAIAAANIAAAARVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVQ=="

        @Test("rejects a chapter start beyond the file")
        func rejectsOutOfRangeChapter() async throws {
            let sourceURL = temporaryURL(extension: "m4a")
            defer {
                try? FileManager.default.removeItem(at: sourceURL)
            }
            try writeSilence(to: sourceURL, durationSeconds: 1)

            await #expect(throws: AudioChapterSliceExportFailure.invalidRange) {
                try await AudioChapterSliceExporter.export(
                    sourceURL: sourceURL,
                    startSeconds: 2,
                    durationSeconds: 0.5
                )
            }
        }

        private func temporaryURL(extension pathExtension: String) -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(pathExtension)
        }

        private func writeSilence(
            to url: URL,
            durationSeconds: Double
        ) throws {
            let sampleRate = 44_100.0
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ]
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(
                (durationSeconds * sampleRate).rounded()
            )
            let buffer = try #require(
                AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: frameCount
                )
            )
            buffer.frameLength = frameCount
            try file.write(from: buffer)
        }
    }
#endif
