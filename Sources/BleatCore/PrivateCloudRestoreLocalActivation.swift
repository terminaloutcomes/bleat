import Foundation
import SwiftData

/// Device-local handoff between a verified CloudKit generation and a fresh
/// app store. The caller owns the Application Support directory supplied here.
/// Never point this at iCloud Documents or at the ordinary store file.
public struct PrivateCloudRestoreLocalActivation: Sendable {
    public struct State: Equatable, Sendable {
        public let selected: String?
        public let selectedAccountBinding: String?
        fileprivate let selectedAttempt: String?
        public let pending: String?
        public let pendingAccountBinding: String?
        fileprivate let pendingAttempt: String?
        fileprivate let pendingDigest: String?
        public let settingsPending: Bool
        public let syncResumeRequired: Bool
    }

    public enum Failure: String, Error, Sendable {
        case invalidGeneration, invalidJournal, staleJournal, pendingRestore
    }

    public static let generationPrefix = "BleatRestoredData-"

    private let root: URL
    private let container: ModelContainer
    private let journal: JournalOwner

    /// The directory must already exist. The app's existing synchronous store
    /// initialization owns directory creation.
    public init(root: URL) throws {
        guard root.isFileURL else { throw Failure.invalidJournal }
        self.root = root
        let schema = Schema([ActivationRow.self])
        let url = root.appending(path: "BleatRestoreActivation-v1.store")
        container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(
                    schema: schema, url: url, cloudKitDatabase: .none)
            ]
        )
        journal = JournalOwner(modelContainer: container)
    }

    public static func isGeneration(_ candidate: String) -> Bool {
        guard candidate.hasPrefix(generationPrefix) else { return false }
        let suffix = String(candidate.dropFirst(generationPrefix.count))
        return UUID(uuidString: suffix)?.uuidString.lowercased() == suffix
    }

    /// Bootstrap-only read, before the asynchronous service exists. No missing
    /// or unreadable selected store is treated as a fresh legacy store.
    public func current() throws -> State {
        let state = try Self.read(from: ModelContext(container))
        if let selected = state.selected, let attempt = state.selectedAttempt {
            let values = try storeURL(for: selected, attempt: attempt)
                .resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
            guard values.isRegularFile == true, values.isSymbolicLink != true
            else {
                throw Failure.invalidJournal
            }
        }
        return state
    }

    public func readState() async throws -> State {
        try await journal.read()
    }

    public func storeURL(for generation: String) throws -> URL {
        guard Self.isGeneration(generation) else {
            throw Failure.invalidGeneration
        }
        let state = try Self.read(from: ModelContext(container))
        let attempt =
            state.selected == generation
            ? state.selectedAttempt
            : state.pending == generation ? state.pendingAttempt : nil
        guard let attempt else { throw Failure.staleJournal }
        return try storeURL(for: generation, attempt: attempt)
    }

    private func storeURL(for generation: String, attempt: String) throws -> URL
    {
        guard Self.isGeneration(generation), Self.isCanonicalUUID(attempt)
        else {
            throw Failure.invalidGeneration
        }
        return root.appending(
            path: generation + "-" + attempt + ".materialized.store")
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    /// Materialize the already validated cloud payload in a fresh local store,
    /// then commit pending before the caller is allowed to attempt server CAS.
    /// A crash before this returns can leave an unreferenced store, never a
    /// selected one or copied old sync queues.
    public func prepare(_ backup: PrivateCloudBackup, generation: String)
        async throws
    {
        let attempt = UUID().uuidString.lowercased()
        let destination = try storeURL(for: generation, attempt: attempt)
        let material = try backup.restoreMaterial()
        let before = try await journal.read()
        guard before.pending == nil, before.selected != generation else {
            throw Failure.pendingRestore
        }
        _ = try await PrivateCloudIsolatedMaterializer.materialize(
            material.records, storeURL: destination
        )
        try Task.checkCancellation()
        try await journal.prepare(
            generation: generation, accountBinding: material.accountBinding,
            attempt: attempt, digest: material.digest, expected: before
        )
    }

    /// Only call after the server independently confirms this exact generation
    /// and CloudKit account binding. Unknown outcomes remain pending.
    public func confirm(
        generation: String, accountBinding: String,
        verifiedBackup: PrivateCloudBackup
    ) async throws {
        let verified = try verifiedBackup.restoreMaterial()
        let state = try await journal.read()
        guard state.pending == generation, let attempt = state.pendingAttempt,
            state.pendingAccountBinding == accountBinding,
            verified.accountBinding == accountBinding,
            state.pendingDigest == verified.digest
        else { throw Failure.staleJournal }
        // Opening the store also verifies that its settings receipt is present.
        _ = try await PrivateCloudIsolatedMaterializer.restoredConfiguration(
            storeURL: storeURL(for: generation, attempt: attempt))
        try await journal.confirm(
            generation: generation, binding: accountBinding,
            attempt: attempt, digest: verified.digest)
    }

    /// Only call when the transport positively established a failed CAS or a
    /// pre-publication abort. No generated or previously selected data is removed.
    public func abandon(generation: String) async throws {
        try await journal.abandon(generation: generation)
    }

    public func restoredConfiguration(generation: String) async throws
        -> CloudConfigurationSnapshot?
    {
        let state = try await journal.read()
        guard state.selected == generation, let attempt = state.selectedAttempt
        else {
            throw Failure.staleJournal
        }
        return try await PrivateCloudIsolatedMaterializer.restoredConfiguration(
            storeURL: storeURL(for: generation, attempt: attempt))
    }

    public func markSettingsApplied(generation: String) async throws {
        try await journal.markSettingsApplied(generation: generation)
    }

    public func markSyncExplicitlyResumed(generation: String) async throws {
        try await journal.markSyncExplicitlyResumed(generation: generation)
    }

    fileprivate static func read(from context: ModelContext) throws -> State {
        let rows = try context.fetch(FetchDescriptor<ActivationRow>())
        guard rows.count <= 1 else { throw Failure.invalidJournal }
        let row = rows.first
        let state = State(
            selected: row?.selected,
            selectedAccountBinding: row?.selectedAccountBinding,
            selectedAttempt: row?.selectedAttempt,
            pending: row?.pending,
            pendingAccountBinding: row?.pendingAccountBinding,
            pendingAttempt: row?.pendingAttempt,
            pendingDigest: row?.pendingDigest,
            settingsPending: row?.settingsPending ?? false,
            syncResumeRequired: row?.syncResumeRequired ?? false
        )
        guard state.selected.map(Self.isGeneration) != false,
            state.pending.map(Self.isGeneration) != false,
            (state.selected == nil) == (state.selectedAccountBinding == nil),
            (state.pending == nil) == (state.pendingAccountBinding == nil),
            (state.pending == nil) == (state.pendingDigest == nil),
            (state.selected == nil) == (state.selectedAttempt == nil),
            (state.pending == nil) == (state.pendingAttempt == nil),
            state.selectedAttempt.map(Self.isCanonicalUUID) != false,
            state.pendingAttempt.map(Self.isCanonicalUUID) != false,
            state.pendingDigest.map(Self.validBinding) != false,
            state.selectedAccountBinding.map(Self.validBinding) != false,
            state.pendingAccountBinding.map(Self.validBinding) != false,
            state.selected == nil || state.selected != state.pending,
            (!state.settingsPending && !state.syncResumeRequired)
                || state.selected != nil
        else { throw Failure.invalidJournal }
        return state
    }

    private static func validBinding(_ binding: String) -> Bool {
        binding.utf8.count == 64
            && binding.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}

@Model
private final class ActivationRow {
    var selected: String?
    var selectedAccountBinding: String?
    var selectedAttempt: String?
    var pending: String?
    var pendingAccountBinding: String?
    var pendingAttempt: String?
    var pendingDigest: String?
    var settingsPending: Bool = false
    var syncResumeRequired: Bool = false

    init() {}
}

private actor JournalOwner {
    typealias Activation = PrivateCloudRestoreLocalActivation

    // Construct ModelContexts only in the persistence operations below.
    // Creating a context in this composition initializer could bind it to
    // MainActor when LiveAppService is launched by the SwiftUI bootstrap.
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func read() throws -> Activation.State {
        try Activation.read(from: ModelContext(modelContainer))
    }

    func prepare(
        generation: String, accountBinding: String, attempt: String,
        digest: String,
        expected: Activation.State
    ) throws {
        guard try read() == expected, expected.pending == nil else {
            throw Activation.Failure.staleJournal
        }
        try update { row in
            row.pending = generation
            row.pendingAccountBinding = accountBinding
            row.pendingAttempt = attempt
            row.pendingDigest = digest
        }
    }

    func confirm(
        generation: String, binding: String, attempt: String, digest: String
    ) throws {
        let state = try read()
        guard state.pending == generation,
            state.pendingAccountBinding == binding,
            state.pendingAttempt == attempt,
            state.pendingDigest == digest
        else {
            throw Activation.Failure.staleJournal
        }
        try update { row in
            row.selected = generation
            row.selectedAccountBinding = binding
            row.selectedAttempt = attempt
            row.pending = nil
            row.pendingAccountBinding = nil
            row.pendingAttempt = nil
            row.pendingDigest = nil
            row.settingsPending = true
            row.syncResumeRequired = true
        }
    }

    func abandon(generation: String) throws {
        guard try read().pending == generation else {
            throw Activation.Failure.staleJournal
        }
        try update { row in
            row.pending = nil
            row.pendingAccountBinding = nil
            row.pendingAttempt = nil
            row.pendingDigest = nil
        }
    }

    func markSettingsApplied(generation: String) throws {
        guard try read().selected == generation else {
            throw Activation.Failure.staleJournal
        }
        try update { $0.settingsPending = false }
    }

    func markSyncExplicitlyResumed(generation: String) throws {
        let state = try read()
        guard state.selected == generation, state.pending == nil,
            !state.settingsPending
        else {
            throw Activation.Failure.staleJournal
        }
        try update { $0.syncResumeRequired = false }
    }

    private func update(_ action: (ActivationRow) -> Void) throws {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let rows = try context.fetch(FetchDescriptor<ActivationRow>())
        guard rows.count <= 1 else { throw Activation.Failure.invalidJournal }
        let row: ActivationRow
        if let existing = rows.first {
            row = existing
        } else {
            row = ActivationRow()
            context.insert(row)
        }
        action(row)
        let expected = Activation.State(
            selected: row.selected,
            selectedAccountBinding: row.selectedAccountBinding,
            selectedAttempt: row.selectedAttempt,
            pending: row.pending,
            pendingAccountBinding: row.pendingAccountBinding,
            pendingAttempt: row.pendingAttempt,
            pendingDigest: row.pendingDigest,
            settingsPending: row.settingsPending,
            syncResumeRequired: row.syncResumeRequired
        )
        try context.save()
        guard try read() == expected else {
            throw Activation.Failure.invalidJournal
        }
    }
}
