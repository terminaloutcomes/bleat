import BleatCore
import Observation
import SwiftUI

enum AppRootTab: Hashable, Sendable {
    case home
    case library
    case search
    case downloads
    case settings
}

enum DeepLinkPresentationFailure: Equatable, Sendable {
    case signInRequired
    case unavailable

    var message: String {
        switch self {
        case .signInRequired:
            "Sign in before opening this link."
        case .unavailable:
            "This link is not available for the selected account or library."
        }
    }
}

struct SeriesDestination: Hashable, Sendable {
    let libraryID: LibraryID
    let id: SeriesID
    let name: String
}

@MainActor
@Observable
final class AppNavigationCoordinator {
    private struct BrowseContext {
        let account: ServerAccount?
        let library: LibrarySummary?
        let filter: LibraryBrowseFilter

        @MainActor
        init(model: AppModel) {
            account = model.account
            library = model.selectedLibrary
            filter = model.libraryBrowseFilter
        }
    }

    private enum RouteApplicationOutcome {
        case applied
        case unavailable
        case superseded
    }

    var selectedTab: AppRootTab = .home
    var homePath = NavigationPath()
    var libraryPath = NavigationPath()
    var searchPath = NavigationPath()
    var downloadsPath = NavigationPath()
    var settingsPath = NavigationPath()
    var searchQuery = ""
    var searchScope: DeepLinkSearchScope = .all
    var showsPlayer = false
    var pendingRoute: DeepLinkRoute?
    var deepLinkFailure: DeepLinkPresentationFailure?
    @ObservationIgnored
    private var pendingRouteGeneration: UInt64 = 0
    @ObservationIgnored
    private var isApplyingPendingRoute = false

    func receive(url: URL) {
        guard let route = try? DeepLinkParser.parse(url) else {
            return
        }
        pendingRouteGeneration &+= 1
        pendingRoute = route
    }

    func applyPendingRoute(model: AppModel) async {
        guard !isApplyingPendingRoute else { return }
        isApplyingPendingRoute = true
        defer {
            isApplyingPendingRoute = false
        }

        while let route = pendingRoute {
            guard model.phase == .signedIn else {
                deepLinkFailure = .signInRequired
                return
            }
            guard model.isNavigationReady else { return }
            let generation = pendingRouteGeneration
            let context = BrowseContext(model: model)
            let outcome = await apply(
                route,
                model: model,
                generation: generation
            )

            switch outcome {
            case .applied:
                guard isCurrentRouteGeneration(generation) else {
                    await restore(context, in: model)
                    continue
                }
                pendingRoute = nil
                return
            case .unavailable:
                guard isCurrentRouteGeneration(generation) else {
                    await restore(context, in: model)
                    continue
                }
                pendingRoute = nil
                deepLinkFailure = .unavailable
                return
            case .superseded:
                await restore(context, in: model)
            }
        }
    }

    private func apply(
        _ route: DeepLinkRoute,
        model: AppModel,
        generation: UInt64
    ) async -> RouteApplicationOutcome {
        let scopeResolved = await resolveScope(
            for: route,
            model: model,
            generation: generation
        )
        guard isCurrentRouteGeneration(generation) else {
            return .superseded
        }
        guard scopeResolved else {
            return .unavailable
        }

        switch route {
        case .home:
            selectedTab = .home
            homePath = NavigationPath()
        case .library:
            selectedTab = .library
            libraryPath = NavigationPath()
        case .downloads:
            selectedTab = .downloads
            downloadsPath = NavigationPath()
        case let .search(query, scope, _):
            selectedTab = .search
            searchPath = NavigationPath()
            searchQuery = query
            searchScope = scope
        case let .author(id, target):
            guard let libraryID = target.libraryID ?? model.selectedLibrary?.id
            else {
                return .unavailable
            }
            let author = await model.resolveAuthor(id, in: libraryID)
            guard isCurrentRouteGeneration(generation) else {
                return .superseded
            }
            guard let author else { return .unavailable }
            await showAuthor(
                id: author.id,
                name: author.name,
                libraryID: libraryID,
                model: model,
                routeGeneration: generation
            )
            guard isCurrentRouteGeneration(generation) else {
                return .superseded
            }
        case let .series(id, target):
            guard let libraryID = target.libraryID ?? model.selectedLibrary?.id
            else {
                return .unavailable
            }
            let series = await model.resolveSeries(id, in: libraryID)
            guard isCurrentRouteGeneration(generation) else {
                return .superseded
            }
            guard let series else { return .unavailable }
            selectedTab = .library
            libraryPath = NavigationPath()
            showSeries(
                id: series.id,
                name: series.name,
                libraryID: libraryID,
                from: .library
            )
        case let .book(id, target):
            guard let libraryID = target.libraryID ?? model.selectedLibrary?.id
            else {
                return .unavailable
            }
            let book = await model.resolveBook(id, in: libraryID)
            guard isCurrentRouteGeneration(generation) else {
                return .superseded
            }
            guard let book else { return .unavailable }
            selectedTab = .library
            libraryPath = NavigationPath()
            libraryPath.append(book)
        case let .settings(destination):
            selectedTab = .settings
            settingsPath = NavigationPath()
            if destination != .root {
                settingsPath.append(destination)
            }
        case .nowPlaying:
            guard model.playback.hasActiveBook else {
                return .unavailable
            }
            showsPlayer = true
        }
        return .applied
    }

    func pathBinding(for tab: AppRootTab) -> Binding<NavigationPath> {
        Binding(
            get: { [weak self] in
                guard let self else { return NavigationPath() }
                return switch tab {
                case .home: homePath
                case .library: libraryPath
                case .search: searchPath
                case .downloads: downloadsPath
                case .settings: settingsPath
                }
            },
            set: { [weak self] path in
                guard let self else { return }
                switch tab {
                case .home: homePath = path
                case .library: libraryPath = path
                case .search: searchPath = path
                case .downloads: downloadsPath = path
                case .settings: settingsPath = path
                }
            }
        )
    }

    func showAuthor(
        id: AuthorID,
        name: String,
        libraryID: LibraryID,
        model: AppModel,
        routeGeneration: UInt64? = nil
    ) async {
        guard case .loaded(let libraries) = model.libraries,
              let library = libraries.first(where: { $0.id == libraryID })
        else {
            return
        }
        if model.selectedLibrary?.id != libraryID {
            await model.selectLibrary(library)
            guard isCurrentRouteGeneration(routeGeneration) else { return }
        }
        await model.setLibraryBrowseFilter(.author(id: id, name: name))
        guard isCurrentRouteGeneration(routeGeneration) else { return }
        selectedTab = .library
        libraryPath = NavigationPath()
    }

    func showSeries(
        id: SeriesID,
        name: String,
        libraryID: LibraryID,
        from tab: AppRootTab
    ) {
        let destination = SeriesDestination(
            libraryID: libraryID,
            id: id,
            name: name
        )
        switch tab {
        case .home:
            homePath.append(destination)
        case .library:
            libraryPath.append(destination)
        case .search:
            searchPath.append(destination)
        case .downloads:
            downloadsPath.append(destination)
        case .settings:
            settingsPath.append(destination)
        }
    }

    private func resolveScope(
        for route: DeepLinkRoute,
        model: AppModel,
        generation: UInt64
    ) async -> Bool {
        let target: DeepLinkScope?
        switch route {
        case let .search(_, _, routeTarget), let .book(_, routeTarget),
            let .author(_, routeTarget), let .series(_, routeTarget):
            target = routeTarget
        case .home, .library, .downloads, .settings(_), .nowPlaying:
            target = nil
        }
        guard let target else { return true }
        if let accountID = target.accountID,
           model.account?.id != accountID
        {
            guard isCurrentRouteGeneration(generation) else { return false }
            guard let account = model.accounts.first(where: { $0.id == accountID }) else {
                return false
            }
            await model.switchAccount(to: account)
            guard isCurrentRouteGeneration(generation),
                  model.account?.id == accountID,
                  model.isNavigationReady
            else {
                return false
            }
        }
        if let libraryID = target.libraryID {
            guard isCurrentRouteGeneration(generation) else { return false }
            guard case .loaded(let libraries) = model.libraries,
                  let library = libraries.first(where: { $0.id == libraryID })
            else {
                return false
            }
            if model.selectedLibrary?.id != libraryID {
                await model.selectLibrary(library)
                guard isCurrentRouteGeneration(generation) else {
                    return false
                }
            }
        }
        return isCurrentRouteGeneration(generation)
            && model.selectedLibrary != nil
    }

    private func isCurrentRouteGeneration(_ generation: UInt64?) -> Bool {
        guard let generation else { return true }
        return pendingRouteGeneration == generation
    }

    private func restore(_ context: BrowseContext, in model: AppModel) async {
        guard let account = context.account else { return }
        if model.account?.id != account.id {
            await model.switchAccount(to: account)
        }
        guard model.account?.id == account.id else { return }

        if let library = context.library,
           model.selectedLibrary?.id != library.id
        {
            await model.selectLibrary(library)
        }
        guard model.selectedLibrary?.id == context.library?.id else { return }

        if model.libraryBrowseFilter != context.filter {
            await model.setLibraryBrowseFilter(context.filter)
        }
    }
}
