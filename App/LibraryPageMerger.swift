import BleatCore

/// Performs pagination deduplication and page assembly away from the UI actor.
///
/// `AppModel` publishes the completed page on the main actor, but constructing
/// the ID set and merged item array can grow with the loaded library and must
/// not block UI interactions.
actor LibraryPageMerger {
    func merge(
        current: LibraryItemsPage,
        next: LibraryItemsPage
    ) async -> LibraryItemsPage {
        let existingIDs = Set(current.items.map(\.id))
        let newItems = next.items.filter { !existingIDs.contains($0.id) }
        let merged = LibraryItemsPage(
            items: current.items + newItems,
            total: next.total,
            page: next.page,
            limit: next.limit
        )
        await Task.yield()
        return merged
    }
}
