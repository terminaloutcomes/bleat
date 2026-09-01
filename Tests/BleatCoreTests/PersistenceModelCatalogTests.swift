import Foundation
import SwiftData
import XCTest

@testable import BleatCore

final class PersistenceModelCatalogTests: XCTestCase {
    func testCatalogListsEveryPersistentModelInCore() throws {
        let declared = try Self.declaredModelNames(
            in: Self.coreSourceDirectory()
        )
        let catalogued = Set(
            BleatPersistenceModelCatalog.allModelTypes.map {
                Schema.entityName(for: $0)
            }
        )

        let missing = declared.subtracting(catalogued)
            .sorted()
            .map { "\($0) (declared but not registered)" }
        let extra = catalogued.subtracting(declared)
            .sorted()
            .map { "\($0) (registered but not declared)" }

        XCTAssertTrue(
            missing.isEmpty && extra.isEmpty,
            "Catalog and declared @Model types differ. "
                + "Register new models in BleatPersistenceModelCatalog."
                + (missing.isEmpty
                    ? "" : "\nMissing: \(missing.joined(separator: ", "))")
                + (extra.isEmpty
                    ? "" : "\nExtra: \(extra.joined(separator: ", "))")
        )
    }

    func testCatalogBuildsUsableSchema() throws {
        let schema = Schema(BleatPersistenceModelCatalog.allModelTypes)

        XCTAssertEqual(
            schema.entities.count,
            BleatPersistenceModelCatalog.allModelTypes.count
        )
        _ = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: true
                )
            ]
        )
    }

    func testSchemaRegistersEveryCatalogModelName() throws {
        let schema = Schema(BleatPersistenceModelCatalog.allModelTypes)

        for type in BleatPersistenceModelCatalog.allModelTypes {
            let name = Schema.entityName(for: type)
            XCTAssertNotNil(
                schema.entitiesByName[name],
                "Schema did not register catalog model \(name)"
            )
        }
    }

    private static func coreSourceDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent("BleatCore")
    }

    private static func declaredModelNames(in directory: URL) throws -> Set<
        String
    > {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        var names: Set<String> = []
        let declarationPattern = #"\b(?:class|struct)\b"#
        for file in files {
            let content = try String(contentsOf: file, encoding: .utf8)
            let lines = content.split(whereSeparator: \.isNewline)
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(
                    in: .whitespaces
                )
                guard
                    trimmed.hasPrefix("@Model"),
                    !trimmed.hasPrefix("@ModelActor")
                else {
                    continue
                }
                for following in lines[(index + 1)...] {
                    let followingLine = following.trimmingCharacters(
                        in: .whitespaces
                    )
                    if followingLine.isEmpty
                        || followingLine.hasPrefix("//")
                    {
                        continue
                    }
                    if let keywordRange = followingLine.range(
                        of: declarationPattern,
                        options: .regularExpression
                    ) {
                        let remainder = followingLine[
                            keywordRange.upperBound...
                        ]
                        .drop(while: { $0 == " " })
                        if let nameEnd = remainder.firstIndex(where: {
                            $0 == " " || $0 == "{" || $0 == ":" || $0 == "<"
                        }) {
                            names.insert(String(remainder[..<nameEnd]))
                        }
                    }
                    break
                }
            }
        }
        return names
    }
}
