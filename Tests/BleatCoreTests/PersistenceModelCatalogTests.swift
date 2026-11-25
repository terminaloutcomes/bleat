import Foundation
import SwiftData
import Testing

@testable import BleatCore

@Suite(.serialized)
final class PersistenceModelCatalogTests {
    private static var storeModelTypes: [[any PersistentModel.Type]] {
        let app = BleatPersistenceModelCatalog.currentModelTypes
        let activation = PrivateCloudRestoreLocalActivation.modelTypes
        #if DEBUG
            return [app, activation, PrivateCloudIsolatedRestore.modelTypes]
        #else
            return [app, activation]
        #endif
    }

    private static func modelNames(
        _ models: [any PersistentModel.Type]
    ) -> Set<String> {
        Set(models.map { Schema.entityName(for: $0) })
    }

    @Test
    func testCatalogListsEveryPersistentModelInCore() throws {
        let declared = try Self.declaredModelNames(
            in: Self.coreSourceDirectory()
        )
        let stores = Self.storeModelTypes
        let catalogued = Self.modelNames(stores.flatMap { $0 })
        #expect(
            catalogued.count == stores.reduce(0) { $0 + $1.count },
            "A model is registered more than once across the stores"
        )

        let activation = Self.modelNames(
            PrivateCloudRestoreLocalActivation.modelTypes)
        #expect(activation == ["ActivationRow"])
        #if DEBUG
            let isolated = Self.modelNames(
                PrivateCloudIsolatedRestore.modelTypes)
            #expect(
                isolated
                    == [
                        "IsolatedRestoreEntry", "IsolatedRestoreSelector",
                        "IsolatedRestoreStage",
                    ])
        #endif

        let missing = declared.subtracting(catalogued)
            .sorted()
            .map { "\($0) (declared but not registered)" }
        let extra = catalogued.subtracting(declared)
            .sorted()
            .map { "\($0) (registered but not declared)" }

        #expect(
            missing.isEmpty && extra.isEmpty,
            Comment(
                rawValue:
                    "Store registrations and declared @Model types differ."
                    + (missing.isEmpty
                        ? "" : "\nMissing: \(missing.joined(separator: ", "))")
                    + (extra.isEmpty
                        ? "" : "\nExtra: \(extra.joined(separator: ", "))")))
    }

    @Test
    func testCatalogBuildsUsableSchema() throws {
        for models in Self.storeModelTypes {
            let schema = Schema(models)
            #expect(schema.entities.count == models.count)
            _ = try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration(
                        schema: schema, isStoredInMemoryOnly: true)
                ]
            )
        }
    }

    @Test
    func testSchemaRegistersEveryCatalogModelName() throws {
        for models in Self.storeModelTypes {
            let schema = Schema(models)
            #expect(Set(schema.entitiesByName.keys) == Self.modelNames(models))
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
            #if !DEBUG
                // This entire source file is excluded from Release.
                if file.lastPathComponent == "PrivateCloudIsolatedRestore.swift"
                {
                    continue
                }
            #endif
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
