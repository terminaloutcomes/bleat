import Foundation

/// Model-only restore. There is deliberately no CloudKit adapter or Settings
/// entry point. The transport must enforce a write fence, not merely compare
/// a selector record in a different database or zone.
actor PrivateCloudGenerationRestore {
    enum Generation: Equatable, Hashable, Sendable {
        case legacy
        case staged(UUID)
    }

    struct Pointer: Equatable, Sendable {
        let generation: Generation
        let revision: UUID
    }

    struct TargetSession: Equatable, Sendable {
        let accountBinding: String
        /// Must change on every account transition, even away and back.
        let epoch: UUID
    }

    struct ActiveState: Equatable, Sendable {
        let session: TargetSession
        /// A live adapter must never set this for an unfenced legacy writer.
        let fenceReady: Bool
        var accountBinding: String { session.accountBinding }
        let pointer: Pointer
        /// Must change with every ordinary write admitted to the active store.
        /// A legacy writer that bypasses this makes the contract unavailable.
        let writeRevision: UUID
    }

    enum PublishResult: Equatable, Sendable {
        case accepted
        case rejected
        case unknown
    }

    protocol Transport: Sendable {
        func readActive() async throws -> ActiveState

        /// A separate read of the specified store, not a copy of caller input.
        func scan(_ generation: Generation, in session: TargetSession)
            async throws
            -> [PrivateCloudBackup.Entry]

        /// Create only a fresh, isolated, non-active stage. No legacy mutation.
        func createStage(_ generation: Generation, in session: TargetSession)
            async throws

        /// Append to the specified unsealed stage only.
        func appendStage(
            _ records: [PrivateCloudBackup.Entry], to generation: Generation,
            in session: TargetSession
        ) async throws

        /// Seal against all writers, including this staging session.
        func sealStage(_ generation: Generation, in session: TargetSession)
            async throws

        /// Must linearize with ordinary active-generation writes. Compare the
        /// whole expected state, not just pointer revision, and select only a
        /// sealed stage belonging to this account. This can never write or
        /// delete records in the old generation.
        func publish(_ new: Pointer, replacing expected: ActiveState)
            async throws -> PublishResult
    }

    enum Failure: Error, Equatable, Sendable {
        case accountMismatch
        case writeFenceUnavailable
        case stalePreview
        case stagingFailed
        case verificationFailed
        case operationInProgress
        case publicationPending
    }

    struct Preview: Equatable, Sendable {
        let plan: PrivateCloudBackup.ReplacePlan
        fileprivate let expected: ActiveState
        fileprivate let currentDigest: String
        fileprivate let desiredDigest: String
    }

    struct Receipt: Equatable, Sendable {
        fileprivate let expected: ActiveState
        fileprivate let selected: Pointer
    }

    enum Outcome: Equatable, Sendable {
        case unchanged
        case conflict
        case published(Receipt)
        case indeterminate(Receipt)
    }

    private static let batchRecordLimit = 100
    private static let batchPayloadLimit = 1_000_000
    private let transport: any Transport
    private var restoring = false
    private var outstandingReceipt: Receipt?

    init(transport: any Transport) {
        self.transport = transport
    }

    func preview(_ backup: PrivateCloudBackup) async throws -> Preview {
        let desired = try backup.restoreMaterial()
        let expected = try await transport.readActive()
        guard expected.accountBinding == desired.accountBinding else {
            throw Failure.accountMismatch
        }
        guard expected.fenceReady else { throw Failure.writeFenceUnavailable }
        let previous = try await readCurrent(for: expected)
        return Preview(
            plan: try backup.planReplacing(previous),
            expected: expected,
            currentDigest: try previous.restoreMaterial().digest,
            desiredDigest: desired.digest
        )
    }

    /// An explicit reviewed preview is required; real confirmation and the
    /// durable, user-owned recovery export belong above this rehearsal.
    func restore(_ backup: PrivateCloudBackup, reviewed: Preview) async throws
        -> Outcome
    {
        guard !restoring else { throw Failure.operationInProgress }
        guard outstandingReceipt == nil else {
            throw Failure.publicationPending
        }
        restoring = true
        defer { restoring = false }
        let desired = try backup.restoreMaterial()
        guard desired.accountBinding == reviewed.expected.accountBinding else {
            throw Failure.accountMismatch
        }
        guard desired.digest == reviewed.desiredDigest else {
            throw Failure.stalePreview
        }
        let previous = try await readCurrent(for: reviewed.expected)
        guard try previous.restoreMaterial().digest == reviewed.currentDigest
        else {
            throw Failure.stalePreview
        }
        if desired.digest == reviewed.currentDigest { return .unchanged }
        try Task.checkCancellation()

        let generation = Generation.staged(UUID())
        let candidate = Pointer(generation: generation, revision: UUID())
        do {
            try await transport.createStage(
                generation, in: reviewed.expected.session)
            var records: [PrivateCloudBackup.Entry] = []
            var bytes = 0
            for entry in desired.records {
                try Task.checkCancellation()
                if !records.isEmpty,
                    records.count == Self.batchRecordLimit
                        || bytes + entry.payload.count > Self.batchPayloadLimit
                {
                    try await transport.appendStage(
                        records, to: generation, in: reviewed.expected.session)
                    records = []
                    bytes = 0
                }
                records.append(entry)
                bytes += entry.payload.count
            }
            if !records.isEmpty {
                try await transport.appendStage(
                    records, to: generation, in: reviewed.expected.session)
            }
            try await transport.sealStage(
                generation, in: reviewed.expected.session)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.stagingFailed
        }

        do {
            let staged = try await transport.scan(
                generation, in: reviewed.expected.session)
            let checked = try PrivateCloudBackup.capture(
                records: staged, accountBinding: desired.accountBinding
            )
            guard try checked.restoreMaterial() == desired else {
                throw Failure.verificationFailed
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.verificationFailed
        }

        // A stale review cannot publish even if an adapter happens to accept
        // target conflicts. The final transport CAS still covers this check's
        // race window.
        guard try await transport.readActive() == reviewed.expected else {
            return .conflict
        }
        try Task.checkCancellation()
        let receipt = Receipt(expected: reviewed.expected, selected: candidate)
        outstandingReceipt = receipt
        let result: PublishResult
        do {
            result = try await transport.publish(
                candidate, replacing: reviewed.expected)
        } catch {
            // Once requested, even cancellation does not prove no commit.
            return await resolve(receipt)
        }
        switch result {
        case .accepted:
            outstandingReceipt = nil
            return .published(receipt)
        case .rejected:
            outstandingReceipt = nil
            return .conflict
        case .unknown: return await resolve(receipt)
        }
    }

    /// Read-only reconciliation. Seeing the old or a different selection is
    /// not proof of no commit: a request may still arrive, or be superseded.
    func resolve(_ receipt: Receipt) async -> Outcome {
        guard let current = try? await transport.readActive(),
            current.session == receipt.expected.session,
            current.pointer == receipt.selected
        else { return .indeterminate(receipt) }
        if outstandingReceipt == receipt { outstandingReceipt = nil }
        return .published(receipt)
    }

    private func readCurrent(for expected: ActiveState) async throws
        -> PrivateCloudBackup
    {
        guard try await transport.readActive() == expected else {
            throw Failure.stalePreview
        }
        let entries = try await transport.scan(
            expected.pointer.generation, in: expected.session)
        guard try await transport.readActive() == expected else {
            throw Failure.stalePreview
        }
        return try PrivateCloudBackup.capture(
            records: entries, accountBinding: expected.accountBinding)
    }
}
