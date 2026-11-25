#if DEBUG
    import Darwin
    import Foundation
    import SwiftData

    /// Debug-only, persistent isolated test target. No iCloud, app vault or
    /// normal persistence configuration can be supplied to this type.
    public actor PrivateCloudIsolatedRestore {
        public enum Failure: Error, Sendable {
            case rejected, indeterminate, invalidTarget, capacity
        }

        public struct Review: Sendable {
            public let plan: PrivateCloudBackup.ReplacePlan
            fileprivate let backup: PrivateCloudBackup
            fileprivate let expected: PrivateCloudGenerationRestore.Preview
        }

        public struct Result: Sendable {
            public let restored: PrivateCloudBackup.Preview
            public let unchanged: Bool
            public let inspection: PrivateCloudIsolatedMaterializer.Inspection?
        }

        fileprivate static let binding = PrivateCloudBackup.binding(
            container: "Bleat.CloudRestore.IsolatedLocalTest",
            cloudUserRecordName: "local-test-target-v1"
        )

        static let modelTypes: [any PersistentModel.Type] = [
            IsolatedRestoreSelector.self, IsolatedRestoreStage.self,
            IsolatedRestoreEntry.self,
        ]

        private let storeLock: FileHandle
        private let transport: IsolatedRestoreTransport
        private let coordinator: PrivateCloudGenerationRestore

        public init(directory: URL) throws {
            let root = directory.appendingPathComponent(
                "Bleat-Isolated-iCloud-Restore-v1", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
            // The app owner supplies only its Caches root; UI tests use
            // their disposable temporary root. Neither is a cloud document
            // or normal app-store directory.
            #if os(iOS)
                try FileManager.default.setAttributes(
                    [
                        .protectionKey: FileProtectionType
                            .completeUntilFirstUserAuthentication
                    ],
                    ofItemAtPath: root.path
                )
            #endif
            let lockURL = root.appendingPathComponent("owner.lock")
            let descriptor = open(
                lockURL.path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600
            )
            guard descriptor >= 0 else { throw Failure.invalidTarget }
            let lock = FileHandle(
                fileDescriptor: descriptor, closeOnDealloc: true)
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw Failure.invalidTarget
            }

            let url = root.appendingPathComponent(
                "Bleat-Isolated-iCloud-Restore-Test-v1.store")
            let schema = Schema(Self.modelTypes)
            let model = try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration(
                        schema: schema, url: url, cloudKitDatabase: .none
                    )
                ]
            )
            let transport = IsolatedRestoreTransport(modelContainer: model)
            self.storeLock = lock
            self.transport = transport
            coordinator = PrivateCloudGenerationRestore(transport: transport)
        }

        public static func syntheticUITestExport() throws -> Data {
            let settings = Data(
                """
                {"defaultPlaybackRate":1,"resumeRewindSeconds":10,"skipBackwardSeconds":30,
                "skipForwardSeconds":30,"downloadNetworkPolicy":"wifiOnly",
                "automaticDownloadLookahead":0,"automaticDownloadCleanupPolicy":"afterTwentyFourHours"}
                """.utf8)
            let source = PrivateCloudBackup.binding(
                container: "synthetic-test-source",
                cloudUserRecordName: "synthetic-test-user")
            return try PrivateCloudBackup.capture(
                records: [
                    .init(
                        kind: .configuration, name: "configuration.singleton",
                        payload: settings)
                ],
                accountBinding: source
            ).encoded()
        }

        public func preview(_ data: Data) async throws -> Review {
            let backup = try PrivateCloudBackup.decode(data)
                .reboundForIsolatedTesting(to: Self.binding)
            let expected = try await coordinator.preview(backup)
            if expected.plan.create + expected.plan.replace
                + expected.plan.remove > 0
            {
                try await transport.requireSpaceForStage()
            }
            return Review(
                plan: expected.plan, backup: backup, expected: expected)
        }

        public func replace(_ review: Review) async throws -> Result {
            let outcome = try await coordinator.restore(
                review.backup, reviewed: review.expected)
            switch outcome {
            case .unchanged, .published:
                let actual = try await transport.readbackArchive()
                guard
                    try actual.restoreMaterial()
                        == review.backup.restoreMaterial()
                else {
                    throw Failure.indeterminate
                }
                return Result(
                    restored: try actual.preview(),
                    unchanged: outcome == .unchanged,
                    inspection: try await transport.activeInspection())
            case .conflict:
                throw Failure.rejected
            case .indeterminate:
                throw Failure.indeterminate
            }
        }

        public func readback() async throws -> PrivateCloudBackup.Preview {
            try await transport.readbackArchive().preview()
        }

        public func inspection() async throws
            -> PrivateCloudIsolatedMaterializer.Inspection?
        {
            try await transport.activeInspection()
        }

        func testReadbackArchive() async throws -> PrivateCloudBackup {
            try await transport.readbackArchive()
        }

        func testRetainedArchives() async throws -> [PrivateCloudBackup] {
            try await transport.retainedArchives()
        }
    }

    @Model
    private final class IsolatedRestoreSelector {
        @Attribute(.unique) var key: String = "active"
        var generation: UUID
        var revision: UUID

        init(generation: UUID, revision: UUID) {
            self.generation = generation
            self.revision = revision
        }
    }

    @Model
    private final class IsolatedRestoreStage {
        @Attribute(.unique) var id: UUID
        var sealed: Bool = false

        init(id: UUID) { self.id = id }
    }

    @Model
    private final class IsolatedRestoreEntry {
        @Attribute(.unique) var key: String
        var generation: UUID
        var name: String
        var kind: String
        @Attribute(.externalStorage) var payload: Data

        init(generation: UUID, entry: PrivateCloudBackup.Entry) {
            key = "\(generation.uuidString).\(entry.name)"
            self.generation = generation
            name = entry.name
            kind = entry.kind.rawValue
            payload = entry.payload
        }
    }

    /// All synchronous SwiftData access stays on the owning persistence
    /// actor. The dedicated store is single-owner; normal app stores and sync
    /// engines never open it.
    @ModelActor
    private actor IsolatedRestoreTransport: PrivateCloudGenerationRestore
            .Transport
    {
        typealias Restore = PrivateCloudGenerationRestore
        typealias Failure = PrivateCloudIsolatedRestore.Failure
        private let session = Restore.TargetSession(
            accountBinding: PrivateCloudIsolatedRestore.binding, epoch: UUID()
        )

        func readActive() async throws -> Restore.ActiveState { try active() }

        func scan(
            _ generation: Restore.Generation,
            in requested: Restore.TargetSession
        ) async throws
            -> [PrivateCloudBackup.Entry]
        {
            try require(requested)
            return try scan(generation)
        }

        func requireSpaceForStage() throws {
            guard
                try modelContext.fetchCount(
                    FetchDescriptor<IsolatedRestoreStage>()) < 8
            else {
                throw Failure.capacity
            }
        }

        func createStage(
            _ generation: Restore.Generation,
            in requested: Restore.TargetSession
        ) async throws {
            try require(requested)
            guard case .staged(let id) = generation, try stage(id) == nil else {
                throw Failure.invalidTarget
            }
            // Keep past generations instead of guessing which is safe to delete.
            try requireSpaceForStage()
            modelContext.insert(IsolatedRestoreStage(id: id))
            try save()
        }

        func appendStage(
            _ records: [PrivateCloudBackup.Entry],
            to generation: Restore.Generation,
            in requested: Restore.TargetSession
        ) async throws {
            try require(requested)
            guard case .staged(let id) = generation, let stage = try stage(id),
                !stage.sealed,
                generation != (try active().pointer.generation)
            else { throw Failure.invalidTarget }
            for entry in records {
                modelContext.insert(
                    IsolatedRestoreEntry(generation: id, entry: entry))
            }
            try save()
        }

        func sealStage(
            _ generation: Restore.Generation,
            in requested: Restore.TargetSession
        ) async throws {
            try require(requested)
            guard case .staged(let id) = generation, let stage = try stage(id),
                !stage.sealed
            else {
                throw Failure.invalidTarget
            }
            let root = try materializedDirectory(id)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false)
            let entries = try readRows(id)
            _ = try await PrivateCloudIsolatedMaterializer.materialize(
                entries, directory: root)
            try require(requested)
            stage.sealed = true
            try save()
        }

        func publish(
            _ new: Restore.Pointer, replacing expected: Restore.ActiveState
        ) async throws
            -> Restore.PublishResult
        {
            try require(expected.session)
            guard try active() == expected,
                case .staged(let id) = new.generation,
                try stage(id)?.sealed == true
            else { return .rejected }
            if let selector = try selector() {
                selector.generation = id
                selector.revision = new.revision
            } else {
                modelContext.insert(
                    IsolatedRestoreSelector(
                        generation: id, revision: new.revision))
            }
            try save()
            return .accepted
        }

        func readbackArchive() throws -> PrivateCloudBackup {
            try PrivateCloudBackup.capture(
                records: scan(active().pointer.generation),
                accountBinding: session.accountBinding
            )
        }

        func activeInspection() async throws -> PrivateCloudIsolatedMaterializer
            .Inspection?
        {
            guard case .staged(let id) = try active().pointer.generation else {
                return nil
            }
            return try await PrivateCloudIsolatedMaterializer.inspect(
                directory: materializedDirectory(id))
        }

        private func materializedDirectory(_ id: UUID) throws -> URL {
            guard let configuration = modelContainer.configurations.first else {
                throw Failure.invalidTarget
            }
            return configuration.url.deletingLastPathComponent()
                .appendingPathComponent(
                    "Generation-\(id.uuidString)", isDirectory: true
                )
        }

        func retainedArchives() throws -> [PrivateCloudBackup] {
            let current = try active().pointer.generation
            return try modelContext.fetch(
                FetchDescriptor<IsolatedRestoreStage>()
            )
            .filter { $0.sealed && Restore.Generation.staged($0.id) != current }
            .map {
                try PrivateCloudBackup.capture(
                    records: scan(.staged($0.id)),
                    accountBinding: session.accountBinding
                )
            }
        }

        private func require(_ requested: Restore.TargetSession) throws {
            guard session == requested else { throw Failure.invalidTarget }
            modelContext.autosaveEnabled = false
            try Task.checkCancellation()
        }

        private func active() throws -> Restore.ActiveState {
            let selector = try selector()
            let revision = selector?.revision ?? session.epoch
            return Restore.ActiveState(
                session: session, fenceReady: true,
                pointer: Restore.Pointer(
                    generation: selector.map { .staged($0.generation) }
                        ?? .legacy,
                    revision: revision
                ),
                writeRevision: revision
            )
        }

        private func selector() throws -> IsolatedRestoreSelector? {
            let found = try modelContext.fetch(
                FetchDescriptor<IsolatedRestoreSelector>())
            guard found.count <= 1 else { throw Failure.invalidTarget }
            return found.first
        }

        private func stage(_ id: UUID) throws -> IsolatedRestoreStage? {
            try modelContext.fetch(
                FetchDescriptor<IsolatedRestoreStage>(
                    predicate: #Predicate { $0.id == id }
                )
            ).first
        }

        private func scan(_ generation: Restore.Generation) throws
            -> [PrivateCloudBackup.Entry]
        {
            guard case .staged(let id) = generation else { return [] }
            guard try stage(id)?.sealed == true else {
                throw Failure.invalidTarget
            }
            return try readRows(id)
        }

        private func readRows(_ id: UUID) throws -> [PrivateCloudBackup.Entry] {
            // Independent ModelContext bypasses staged writer's object cache.
            let reader = ModelContext(modelContainer)
            reader.autosaveEnabled = false
            let records = try reader.fetch(
                FetchDescriptor<IsolatedRestoreEntry>(
                    predicate: #Predicate { $0.generation == id }
                ))
            return try records.map {
                guard let kind = PrivateCloudBackup.Kind(rawValue: $0.kind)
                else { throw Failure.invalidTarget }
                return PrivateCloudBackup.Entry(
                    kind: kind, name: $0.name, payload: $0.payload)
            }
        }

        private func save() throws {
            do { try modelContext.save() } catch {
                modelContext.rollback()
                throw error
            }
        }
    }
#endif
