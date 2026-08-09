import BleatTranscription
import Foundation

@main
struct BleatTranscribeCLI {
    static func main() async {
        do {
            let configuration = try CLIConfiguration.parse(
                arguments: Array(CommandLine.arguments.dropFirst())
            )
            guard FileManager.default.fileExists(
                atPath: configuration.audioFileURL.path
            ) else {
                throw ChapterTranscriptionFailure.audioFileUnreadable(
                    configuration.audioFileURL.lastPathComponent
                )
            }

            writeError("Preparing SpeechTranscriber and language assets…")
            let segments = try await SpeechChapterTranscriber().transcribe(
                ChapterTranscriptionRequest(
                    audioFileURL: configuration.audioFileURL,
                    locale: configuration.locale,
                    chapterStartSeconds: configuration.chapterStartSeconds
                )
            )

            for segment in segments {
                print(CLIOutput.transcriptLine(for: segment))
            }
            writeError("Completed with \(segments.count) final segment(s).")
        } catch CLIConfigurationFailure.helpRequested {
            print(CLIConfiguration.usage)
        } catch {
            writeError("Error: \(error.localizedDescription)")
            writeError(CLIConfiguration.usage)
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
