import Foundation

enum CLIConfigurationFailure: Error, Equatable {
    case helpRequested
    case invalidArguments(String)
}

extension CLIConfigurationFailure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .helpRequested:
            nil
        case .invalidArguments(let message):
            message
        }
    }
}

struct CLIConfiguration: Equatable {
    let audioFileURL: URL
    let locale: Locale
    let chapterStartSeconds: Double

    static let usage = """
        Usage: bleat-transcribe [options] <chapter-audio-file>

          --locale <identifier>       Speech locale (default: en-AU)
          --chapter-start <seconds>   Chapter start on the whole-book timeline (default: 0)
          -h, --help                  Show this help
        """

    static func parse(arguments: [String]) throws -> CLIConfiguration {
        var localeIdentifier = "en-AU"
        var chapterStartSeconds = 0.0
        var audioPath: String?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                throw CLIConfigurationFailure.helpRequested
            case "--locale":
                index += 1
                guard index < arguments.count else {
                    throw CLIConfigurationFailure.invalidArguments(
                        "--locale requires an identifier."
                    )
                }
                localeIdentifier = arguments[index]
            case "--chapter-start":
                index += 1
                guard index < arguments.count,
                    let value = Double(arguments[index]),
                    value.isFinite,
                    value >= 0
                else {
                    throw CLIConfigurationFailure.invalidArguments(
                        "--chapter-start requires a finite, non-negative number of seconds."
                    )
                }
                chapterStartSeconds = value
            default:
                guard !argument.hasPrefix("-") else {
                    throw CLIConfigurationFailure.invalidArguments(
                        "Unknown option: \(argument)"
                    )
                }
                guard audioPath == nil else {
                    throw CLIConfigurationFailure.invalidArguments(
                        "Provide exactly one chapter audio file."
                    )
                }
                audioPath = argument
            }
            index += 1
        }

        guard let audioPath else {
            throw CLIConfigurationFailure.invalidArguments(
                "A chapter audio file is required."
            )
        }
        guard !localeIdentifier.isEmpty else {
            throw CLIConfigurationFailure.invalidArguments(
                "--locale must not be empty."
            )
        }

        return CLIConfiguration(
            audioFileURL: URL(fileURLWithPath: audioPath),
            locale: Locale(identifier: localeIdentifier),
            chapterStartSeconds: chapterStartSeconds
        )
    }
}
