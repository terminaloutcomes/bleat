import Foundation
import Testing

@testable import BleatCore

@Suite struct PrivateCloudRestoreLocalActivationTests {
    private typealias Activation = PrivateCloudRestoreLocalActivation

    @Test func pendingNeverSelectsAndOnlyMatchingCloudReceiptConfirms()
        async throws
    {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let activation = try Activation(root: root)
        let generation = makeGeneration()
        let backup = try backup(rate: 1.25)
        try await activation.prepare(backup, generation: generation)

        let reopened = try Activation(root: root)
        let pending = try reopened.current()
        #expect(pending.selected == nil)
        #expect(pending.pending == generation)
        #expect(!pending.settingsPending)
        let other = PrivateCloudBackup.binding(
            container: "synthetic", cloudUserRecordName: "other")
        await #expect(throws: Activation.Failure.staleJournal) {
            try await reopened.confirm(
                generation: generation, accountBinding: other,
                verifiedBackup: backup)
        }
        #expect(try await reopened.readState() == pending)

        let binding = try backup.restoreMaterial().accountBinding
        let drifted = try self.backup(rate: 1.5)
        await #expect(throws: Activation.Failure.staleJournal) {
            try await reopened.confirm(
                generation: generation, accountBinding: binding,
                verifiedBackup: drifted)
        }
        #expect(try await reopened.readState() == pending)
        try await reopened.confirm(
            generation: generation, accountBinding: binding,
            verifiedBackup: backup)
        let selected = try Activation(root: root).current()
        #expect(selected.selected == generation)
        #expect(selected.pending == nil)
        #expect(selected.selectedAccountBinding == binding)
        #expect(selected.settingsPending)
        #expect(
            try await reopened.restoredConfiguration(generation: generation)?
                .defaultPlaybackRate == 1.25)
        try await reopened.markSettingsApplied(generation: generation)
        #expect(try !Activation(root: root).current().settingsPending)
        #expect(try Activation(root: root).current().syncResumeRequired)
        try await reopened.markSyncExplicitlyResumed(generation: generation)
        #expect(try !Activation(root: root).current().syncResumeRequired)
    }

    @Test func replacingAgainRetainsPriorMaterializedStore() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let activation = try Activation(root: root)
        let first = makeGeneration()
        let second = makeGeneration()
        let original = try backup(rate: 1.25)
        let replacement = try backup(rate: 1.5)
        let binding = try original.restoreMaterial().accountBinding

        try await activation.prepare(original, generation: first)
        try await activation.confirm(
            generation: first, accountBinding: binding, verifiedBackup: original
        )
        try await activation.markSettingsApplied(generation: first)
        let firstURL = try activation.storeURL(for: first)
        try await activation.prepare(replacement, generation: second)
        let reopened = try Activation(root: root)
        #expect(try reopened.current().selected == first)
        #expect(try reopened.current().pending == second)
        try await reopened.confirm(
            generation: second, accountBinding: binding,
            verifiedBackup: replacement)

        #expect(try Activation(root: root).current().selected == second)
        #expect(
            try await PrivateCloudIsolatedMaterializer.restoredConfiguration(
                storeURL: firstURL)?.defaultPlaybackRate
                == 1.25)
        #expect(
            try await reopened.restoredConfiguration(generation: second)?
                .defaultPlaybackRate == 1.5)
    }

    @Test
    func positivelyAbandonedGenerationDoesNotReplaceSelectionOrEraseFiles()
        async throws
    {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let activation = try Activation(root: root)
        let generation = makeGeneration()
        try await activation.prepare(backup(rate: 1.25), generation: generation)
        let abandonedURL = try activation.storeURL(for: generation)
        await #expect(throws: Activation.Failure.staleJournal) {
            try await activation.abandon(generation: makeGeneration())
        }
        try await activation.abandon(generation: generation)
        let state = try Activation(root: root).current()
        #expect(state.selected == nil)
        #expect(state.pending == nil)
        #expect(FileManager.default.fileExists(atPath: abandonedURL.path))
        let retryBackup = try backup(rate: 1.5)
        try await activation.prepare(retryBackup, generation: generation)
        let retryURL = try activation.storeURL(for: generation)
        #expect(retryURL != abandonedURL)
        try await activation.confirm(
            generation: generation,
            accountBinding: retryBackup.restoreMaterial().accountBinding,
            verifiedBackup: retryBackup)
        #expect(
            try Activation(root: root).storeURL(for: generation) == retryURL)
        #expect(FileManager.default.fileExists(atPath: abandonedURL.path))
        #expect(
            !Activation.isGeneration(
                Activation.generationPrefix + "../default.store"))
        #expect(
            !Activation.isGeneration(
                Activation.generationPrefix + UUID().uuidString.uppercased()))
    }

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "bleat-activation-test-" + UUID().uuidString,
            directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    private func backup(rate: Double) throws -> PrivateCloudBackup {
        let settings = Data(
            """
            {"defaultPlaybackRate":\(rate),"resumeRewindSeconds":10,"skipBackwardSeconds":30,
            "skipForwardSeconds":30,"downloadNetworkPolicy":"wifiOnly",
            "automaticDownloadLookahead":0,"automaticDownloadCleanupPolicy":"afterTwentyFourHours"}
            """.utf8)
        return try PrivateCloudBackup.capture(
            records: [
                .init(
                    kind: .configuration, name: "configuration.singleton",
                    payload: settings)
            ],
            accountBinding: PrivateCloudBackup.binding(
                container: "synthetic", cloudUserRecordName: "owner"))
    }

    private func makeGeneration() -> String {
        Activation.generationPrefix + UUID().uuidString.lowercased()
    }
}
