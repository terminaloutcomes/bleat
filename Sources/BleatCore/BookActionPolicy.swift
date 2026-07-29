import Foundation

public enum LibraryItemAccessDecision: Equatable, Sendable {
    case allowed
    case inaccessibleLibrary
    case inaccessibleTags
    case explicitContentDenied
}

public enum BookAction: CaseIterable, Hashable, Sendable {
    case play
    case download
    case editMetadata
    case editCover
    case deleteFromServer
}

public struct BookActionAvailability: Equatable, Sendable {
    public let access: LibraryItemAccessDecision
    public let visibleActions: Set<BookAction>

    public init(
        user: AuthenticatedUser,
        detail: LibraryBookDetail
    ) {
        access = Self.accessDecision(user: user, detail: detail)
        guard access == .allowed else {
            visibleActions = []
            return
        }

        var actions: Set<BookAction> = [.play]
        if user.permissions.download {
            actions.insert(.download)
        }
        if user.permissions.update {
            actions.insert(.editMetadata)
            if user.permissions.upload {
                actions.insert(.editCover)
            }
        }
        if user.permissions.delete {
            actions.insert(.deleteFromServer)
        }
        visibleActions = actions
    }

    private static func accessDecision(
        user: AuthenticatedUser,
        detail: LibraryBookDetail
    ) -> LibraryItemAccessDecision {
        if !user.permissions.accessAllLibraries,
           !user.accessibleLibraryIDs.contains(detail.libraryID)
        {
            return .inaccessibleLibrary
        }
        if detail.isExplicit,
           !user.permissions.accessExplicitContent
        {
            return .explicitContentDenied
        }
        if !user.permissions.accessAllTags,
           !hasAccessibleTags(user: user, itemTags: detail.tags)
        {
            return .inaccessibleTags
        }
        return .allowed
    }

    private static func hasAccessibleTags(
        user: AuthenticatedUser,
        itemTags: [String]
    ) -> Bool {
        let selected = Set(user.selectedItemTags)
        if user.permissions.selectedTagsNotAccessible {
            return itemTags.allSatisfy { !selected.contains($0) }
        }
        return itemTags.contains { selected.contains($0) }
    }
}
