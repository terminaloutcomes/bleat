import BleatCore
import Foundation
import Network
import dnssd

struct NearbyServerResult: Identifiable, Equatable, Sendable {
    let name: String
    let resolution: ResolvedBonjourService
    let server: DiscoveredServer

    var id: NormalizedServerURL { server.baseURL }
}

enum NearbyServerDiscoveryFailure: Error, Equatable, Sendable {
    case permissionDenied
    case localNetworkUnavailable
    case resolutionFailed
    case invalidAdvertisement
    case serverVerificationFailed

    var title: String {
        switch self {
        case .permissionDenied: "Local network access denied"
        case .localNetworkUnavailable: "Local network unavailable"
        case .resolutionFailed: "Could not resolve nearby servers"
        case .invalidAdvertisement: "Invalid server advertisement"
        case .serverVerificationFailed: "No verified servers"
        }
    }

    var message: String {
        switch self {
        case .permissionDenied:
            "Allow Local Network access in Settings to find nearby servers."
        case .localNetworkUnavailable:
            "Connect to a local network and try again."
        case .resolutionFailed:
            "Bleat could not resolve the advertised server."
        case .invalidAdvertisement:
            "A nearby service did not provide a valid HTTPS address."
        case .serverVerificationFailed:
            "Nearby services were found, but none identified as a supported Audiobookshelf server over trusted HTTPS."
        }
    }
}

enum NearbyServerDiscoveryState: Equatable, Sendable {
    case idle
    case searching
    case results([NearbyServerResult])
    case noResults
    case failed(NearbyServerDiscoveryFailure)
}

@MainActor
protocol NearbyServerDiscovering: AnyObject {
    func start(
        update:
            @escaping @MainActor @Sendable (
                NearbyServerDiscoveryState
            ) -> Void
    )
    func cancel()
}

enum NearbyServerAdvertisementMapper {
    static func deduplicated(
        _ results: [NearbyServerResult]
    ) -> [NearbyServerResult] {
        var byURL: [NormalizedServerURL: NearbyServerResult] = [:]
        for result in results {
            let existing = byURL[result.server.baseURL]
            if existing == nil
                || result.name.localizedStandardCompare(existing?.name ?? "")
                    == .orderedAscending
            {
                byURL[result.server.baseURL] = result
            }
        }
        return byURL.values.sorted {
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            if nameOrder == .orderedSame {
                return $0.server.baseURL.url.absoluteString
                    < $1.server.baseURL.url.absoluteString
            }
            return nameOrder == .orderedAscending
        }
    }
}

@MainActor
final class BonjourNearbyServerDiscovery: NearbyServerDiscovering {
    private let verifier:
        @Sendable (NormalizedServerURL) async throws -> DiscoveredServer
    private let browser: BonjourServiceBrowser
    private let resolver: BonjourServiceResolver
    private var services: Set<BonjourServiceID> = []
    private var settledServices: Set<BonjourServiceID> = []
    private var resultsByService: [BonjourServiceID: NearbyServerResult] = [:]
    private var failuresByService:
        [BonjourServiceID: NearbyServerDiscoveryFailure] = [:]
    private var resolutionTasks: [BonjourServiceID: Task<Void, Never>] = [:]
    private var browserFailure: NearbyServerDiscoveryFailure?
    private var noResultsTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var update:
        (@MainActor @Sendable (NearbyServerDiscoveryState) -> Void)?

    init(
        browser: BonjourServiceBrowser = BonjourServiceBrowser(),
        resolver: BonjourServiceResolver = BonjourServiceResolver(),
        verifier:
            @escaping @Sendable (NormalizedServerURL) async throws
            -> DiscoveredServer = { server in
                try await ServerDiscoveryClient(
                    transport: URLSessionHTTPTransport(routesRequests: false)
                ).discover(server)
            }
    ) {
        self.browser = browser
        self.resolver = resolver
        self.verifier = verifier
    }

    func start(
        update:
            @escaping @MainActor @Sendable (
                NearbyServerDiscoveryState
            ) -> Void
    ) {
        cancel()
        generation &+= 1
        let expectedGeneration = generation
        self.update = update
        update(.searching)

        browser.start { [weak self] event in
            guard let self, generation == expectedGeneration else { return }
            handle(event, generation: expectedGeneration)
        }
    }

    func cancel() {
        generation &+= 1
        noResultsTask?.cancel()
        noResultsTask = nil
        browser.cancel()
        resolver.cancelAll()
        for task in resolutionTasks.values {
            task.cancel()
        }
        resolutionTasks = [:]
        services = []
        settledServices = []
        resultsByService = [:]
        failuresByService = [:]
        browserFailure = nil
        update = nil
    }

    private func handle(
        _ event: BonjourBrowserEvent,
        generation expectedGeneration: UInt64
    ) {
        guard generation == expectedGeneration else { return }
        switch event {
        case .ready:
            browserFailure = nil
            scheduleNoResults(generation: expectedGeneration)
        case .added(let service):
            services.insert(service.id)
            failuresByService.removeValue(forKey: service.id)
            startResolution(for: service, generation: expectedGeneration)
        case .changed(let service):
            services.insert(service.id)
            settledServices.remove(service.id)
            resultsByService.removeValue(forKey: service.id)
            failuresByService.removeValue(forKey: service.id)
            resolver.cancel(service.id)
            resolutionTasks.removeValue(forKey: service.id)?.cancel()
            startResolution(for: service, generation: expectedGeneration)
        case .removed(let service):
            services.remove(service.id)
            settledServices.remove(service.id)
            resultsByService.removeValue(forKey: service.id)
            failuresByService.removeValue(forKey: service.id)
            resolver.cancel(service.id)
            resolutionTasks.removeValue(forKey: service.id)?.cancel()
            publishCurrentResultsOrSearch()
        case .failed(let error):
            noResultsTask?.cancel()
            noResultsTask = nil
            let failure = Self.failure(for: error)
            browserFailure = failure
            update?(.failed(failure))
        }
    }

    private func startResolution(
        for service: BonjourDiscoveredService,
        generation expectedGeneration: UInt64
    ) {
        guard resolutionTasks[service.id] == nil else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { resolutionTasks.removeValue(forKey: service.id) }
            do {
                let resolved = try await resolver.resolve(service)
                guard generation == expectedGeneration,
                    services.contains(service.id)
                else {
                    return
                }
                let discovered = try await verifier(resolved.baseURL)
                guard generation == expectedGeneration,
                    services.contains(service.id)
                else {
                    return
                }
                settledServices.insert(service.id)
                failuresByService.removeValue(forKey: service.id)
                resultsByService[service.id] = NearbyServerResult(
                    name: service.name,
                    resolution: resolved,
                    server: discovered
                )
                publishCurrentResultsOrSearch()
            } catch is CancellationError {
                return
            } catch {
                guard generation == expectedGeneration,
                    services.contains(service.id)
                else {
                    return
                }
                settledServices.insert(service.id)
                failuresByService[service.id] = Self.failure(for: error)
                publishCurrentResultsOrSearch()
            }
        }
        resolutionTasks[service.id] = task
    }

    private func scheduleNoResults(
        generation expectedGeneration: UInt64
    ) {
        noResultsTask?.cancel()
        noResultsTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled,
                let self,
                generation == expectedGeneration,
                browserFailure == nil,
                services.isEmpty,
                resultsByService.isEmpty
            else {
                return
            }
            update?(.noResults)
        }
    }

    private func publishCurrentResultsOrSearch() {
        let results = NearbyServerAdvertisementMapper.deduplicated(
            Array(resultsByService.values)
        )
        if !results.isEmpty {
            update?(.results(results))
        } else if !services.isEmpty,
            settledServices.isSuperset(of: services),
            let failure = services.compactMap({ failuresByService[$0] })
                .first
        {
            update?(.failed(failure))
        } else if browserFailure == nil {
            update?(.searching)
        }
    }

    static func failure(
        for error: Error
    ) -> NearbyServerDiscoveryFailure {
        if let error = error as? BonjourResolutionError {
            switch error {
            case .invalidService, .missingHostname, .invalidHostname,
                .invalidPort, .invalidTXTPath, .invalidURL:
                return .invalidAdvertisement
            case .dnsServiceFailure, .timedOut:
                return .resolutionFailed
            }
        }
        if let error = error as? NWError {
            return failure(for: error)
        }
        return .serverVerificationFailed
    }

    static func failure(
        for error: NWError
    ) -> NearbyServerDiscoveryFailure {
        switch error {
        case .dns(let code):
            switch code {
            case Int32(kDNSServiceErr_PolicyDenied),
                Int32(kDNSServiceErr_NotPermitted):
                return .permissionDenied
            default:
                return .localNetworkUnavailable
            }
        case .posix(let code):
            switch code {
            case .EACCES, .EPERM:
                return .permissionDenied
            case .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH, .ENODEV:
                return .localNetworkUnavailable
            default:
                return .resolutionFailed
            }
        default:
            return .localNetworkUnavailable
        }
    }
}

@MainActor
final class UnavailableNearbyServerDiscovery: NearbyServerDiscovering {
    func start(
        update:
            @escaping @MainActor @Sendable (
                NearbyServerDiscoveryState
            ) -> Void
    ) {
        update(.failed(.localNetworkUnavailable))
    }

    func cancel() {}
}

@MainActor
final class NoResultsNearbyServerDiscovery: NearbyServerDiscovering {
    func start(
        update:
            @escaping @MainActor @Sendable (
                NearbyServerDiscoveryState
            ) -> Void
    ) {
        update(.noResults)
    }

    func cancel() {}
}
