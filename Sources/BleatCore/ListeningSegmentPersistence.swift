import Foundation
import SwiftData

/// Transient physical cleanup, separate from permanent logical reset anchors.
@Model
public final class ListeningSegmentCleanupRecord {
    @Attribute(.unique) var recordName: String
    var accountID: String
    var requiredReceiptIDs: [UUID]

    init(recordName: String, accountID: String, requiredReceiptIDs: [UUID]) {
        self.recordName = recordName
        self.accountID = accountID
        self.requiredReceiptIDs = requiredReceiptIDs
    }
}

enum ListeningSegmentPersistence {
    static func rows(_ context: ModelContext) throws -> [ListeningSliceRecord] {
        try context.fetch(FetchDescriptor<ListeningSliceRecord>())
    }

    static func physical(_ context: ModelContext) throws -> [ListeningSlice] {
        try rows(context).map { try $0.validatedValue() }
    }

    static func insert(_ value: ListeningSlice, in context: ModelContext) throws
    {
        let id = value.id
        if let previous = try context.fetch(
            FetchDescriptor<ListeningSliceRecord>(
                predicate: #Predicate { $0.eventID == id })
        ).first {
            let stored = try previous.validatedValue()
            let equal =
                stored.lineage != nil || value.lineage != nil
                ? ListeningSegmentCodec.equivalentRepresentation(stored, value)
                : ListeningSegmentCodec.equivalent(stored, value)
            guard previous.accountID == value.accountID.rawValue, equal else {
                throw ListeningSegmentFailure(
                    .resolution,
                    previous.accountID == value.accountID.rawValue
                        ? .sourceConflict : .globalIdentityCollision)
            }
            return
        }
        if value.lineage != nil {
            context.insert(
                try ListeningSliceRecord(
                    encodedSegment: ListeningSegmentCodec.encode(value)))
        } else {
            context.insert(ListeningSliceRecord(value))
        }
    }

    static func enqueue(
        name: String, accountID: AccountID, requiring ids: Set<UUID>,
        in context: ModelContext
    ) throws {
        let existing = try context.fetch(
            FetchDescriptor<ListeningSegmentCleanupRecord>(
                predicate: #Predicate { $0.recordName == name })
        ).first
        if let existing {
            guard existing.accountID == accountID.rawValue else {
                throw ListeningSegmentFailure(
                    .retirement, .globalIdentityCollision)
            }
            existing.requiredReceiptIDs = Set(existing.requiredReceiptIDs)
                .union(ids).sorted { $0.uuidString < $1.uuidString }
        } else {
            context.insert(
                ListeningSegmentCleanupRecord(
                    recordName: name,
                    accountID: accountID.rawValue,
                    requiredReceiptIDs: ids.sorted {
                        $0.uuidString < $1.uuidString
                    }))
        }
    }

    static func redirectDependencies(
        from oldID: UUID, to newIDs: Set<UUID>, in context: ModelContext
    ) throws {
        for row in try context.fetch(
            FetchDescriptor<ListeningSegmentCleanupRecord>())
        where row.requiredReceiptIDs.contains(oldID) {
            row.requiredReceiptIDs = Set(row.requiredReceiptIDs).subtracting([
                oldID
            ]).union(newIDs)
                .sorted { $0.uuidString < $1.uuidString }
        }
    }

    /// Supplemental anchors commit with import/reset and before a bridge can be
    /// discarded. Physical cloud cleanup additionally waits for their receipts.
    static func reconcile(
        _ context: ModelContext, canonicalProtocolEnabled: Bool
    ) throws -> ListeningSegmentResolution {
        var resolution = try ListeningSegmentCodec.resolve(physical(context))
        for supplement in resolution.supplements {
            for envelope in try ListeningSegmentCodec.resetEnvelopes(
                accountID: supplement.accountID, action: supplement.action,
                ids: supplement.ids)
            {
                try insert(envelope, in: context)
            }
        }
        if !resolution.supplements.isEmpty {
            resolution = try ListeningSegmentCodec.resolve(physical(context))
        }
        let resets = resolution.resetEnvelopes
        let stored = try physical(context)
        let requiresReceipts =
            canonicalProtocolEnabled
            || stored.contains { $0.lineage?.kind == .observations }
        for row in try rows(context) {
            let value = try row.validatedValue()
            guard value.lineage?.kind != .resetAnchors else { continue }
            let ids = try ListeningSegmentCodec.sourceIDs(value)
            let removals = resolution.removals.filter {
                $0.accountID == value.accountID && !$0.ids.isDisjoint(with: ids)
            }
            guard !removals.isEmpty else { continue }
            let actions = Set(removals.map(\.actionID))
            let required = Set(
                resets.filter {
                    $0.accountID == value.accountID
                        && $0.lineage?.resetAction.map {
                            actions.contains($0.id)
                        } == true
                }.map(\.id))
            guard !required.isEmpty else {
                throw ListeningSegmentFailure(
                    .retirement, .incompleteReplacement)
            }
            try redirectDependencies(from: value.id, to: required, in: context)
            let name = "slice.\(value.id.uuidString.lowercased())"
            if requiresReceipts {
                try enqueue(
                    name: name, accountID: value.accountID, requiring: required,
                    in: context)
            } else {
                if try context.fetch(
                    FetchDescriptor<PrivateCloudStatisticsDeletionRecord>(
                        predicate: #Predicate { $0.recordName == name })
                ).isEmpty {
                    context.insert(
                        PrivateCloudStatisticsDeletionRecord(
                            recordName: name, recordType: "ListeningSlice",
                            accountID: value.accountID.rawValue))
                }
            }
            context.delete(row)
        }
        return resolution
    }

    static func canRemove(
        _ target: ListeningSlice, alternatives: [ListeningSlice]
    ) throws -> Bool {
        guard target.lineage?.kind != .resetAnchors else { return false }
        let original = try ListeningSegmentCodec.contributions(target)
        let result = try ListeningSegmentCodec.resolve(alternatives)
        // One remaining logical group must preserve the connectivity too; a
        // union of disconnected subsets is insufficient to retire a bridge.
        return result.groups.contains { group in
            group.value.accountID == target.accountID
                && original.allSatisfy { group.sources[$0.id] == $0 }
        }
    }
}
