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
        self.init(
            user: user,
            libraryID: detail.libraryID,
            isExplicit: detail.isExplicit,
            tags: detail.tags
        )
    }

    public init(
        user: AuthenticatedUser,
        summary: LibraryBookSummary
    ) {
        self.init(
            user: user,
            libraryID: summary.libraryID,
            isExplicit: summary.isExplicit,
            tags: summary.tags
        )
    }

    private init(
        user: AuthenticatedUser,
        libraryID: LibraryID,
        isExplicit: Bool,
        tags: [String]
    ) {
        access = Self.accessDecision(
            user: user,
            libraryID: libraryID,
            isExplicit: isExplicit,
            tags: tags
        )
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
        libraryID: LibraryID,
        isExplicit: Bool,
        tags: [String]
    ) -> LibraryItemAccessDecision {
        if !user.permissions.accessAllLibraries,
           !user.accessibleLibraryIDs.contains(libraryID)
        {
            return .inaccessibleLibrary
        }
        if isExplicit,
           !user.permissions.accessExplicitContent
        {
            return .explicitContentDenied
        }
        if !user.permissions.accessAllTags,
           !hasAccessibleTags(user: user, itemTags: tags)
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
