import BleatCore
import Foundation

@main
struct CloudHistoryCommand {
    private enum Failure: String, Error {
        case usage, unreadableInput, invalidAccountScope, privateOutputExists,
            outputFailed
    }

    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch let error as PrivateCloudHistoryArchive.Failure {
            stop(error.rawValue)
        } catch let error as Failure {
            stop(error.rawValue, usage: error == .usage)
        } catch is CancellationError {
            stop("cancelled")
        } catch {
            stop("operationFailed")
        }
    }

    private static func run(_ arguments: [String]) async throws {
        guard arguments.count >= 2 else { throw Failure.usage }
        let mode = arguments[0]
        let archive = try PrivateCloudHistoryArchive.decode(read(arguments[1]))
        switch (mode, arguments.count) {
        case ("preview", 2):
            try printJSON(archive.preview())
        case ("private-scope-file", 3):
            try writePrivateScope(
                archive.sourceAccountIDs().map(\.rawValue).sorted(),
                destination: arguments[2]
            )
        case ("replay", 3):
            let bytes = try read(arguments[2], limit: 8 * 1024 * 1024)
            guard
                let scope = try? JSONDecoder().decode(
                    [String].self, from: bytes),
                scope.count == Set(scope).count
            else { throw Failure.invalidAccountScope }
            // Never print private listening totals or record identifiers.
            let report = try await archive.replaySummary(
                confirmedAccountIDs: Set(scope.map(AccountID.init(rawValue:)))
            )
            try printJSON(report)
        default:
            throw Failure.usage
        }
    }

    private static func read(
        _ path: String,
        limit: Int = PrivateCloudHistoryArchive.maximumArchiveBytes
    ) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unreadableInput }
        let handle = FileHandle(
            fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
            information.st_mode & S_IFMT == S_IFREG
        else { throw Failure.unreadableInput }
        guard information.st_size <= limit else {
            throw PrivateCloudHistoryArchive.Failure.archiveTooLarge
        }
        var data = Data()
        while true {
            let part: Data?
            do {
                part = try handle.read(
                    upToCount: min(64 * 1024, limit - data.count + 1))
            } catch { throw Failure.unreadableInput }
            guard let part, !part.isEmpty else { return data }
            data.append(part)
            guard data.count <= limit else {
                throw PrivateCloudHistoryArchive.Failure.archiveTooLarge
            }
        }
    }

    private static func writePrivateScope(
        _ scope: [String], destination: String
    ) throws {
        let data = try encode(scope)
        let descriptor = open(
            destination, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw Failure.privateOutputExists }
            throw Failure.outputFailed
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try file.write(contentsOf: data)
            try file.close()
        } catch {
            // Do not remove a path that could have changed since exclusive open.
            throw Failure.outputFailed
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        print(String(decoding: try encode(value), as: UTF8.self))
    }

    private static func stop(_ category: String, usage: Bool = false) -> Never {
        var message = "bleat-cloud-history: \(category)\n"
        if usage {
            message += """
                Usage:
                  bleat-cloud-history preview ARCHIVE.json
                  bleat-cloud-history private-scope-file ARCHIVE.json PRIVATE-SCOPE.json
                  bleat-cloud-history replay ARCHIVE.json CONFIRMED-SCOPE.json

                """
        }
        FileHandle.standardError.write(Data(message.utf8))
        exit(1)
    }
}
