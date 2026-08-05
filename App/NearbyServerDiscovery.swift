import BleatCore
import Foundation
import Network

enum NearbyServerServiceType: String, CaseIterable, Sendable {
    case https = "_https._tcp"
    case audiobookshelf = "_audiobookshelf._tcp"
}

struct NearbyServerAdvertisement: Equatable, Sendable {
    let name: String
    let serviceType: NearbyServerServiceType
    let host: String
    let port: UInt16
    let path: String?
}

struct NearbyServerResult: Identifiable, Equatable, Sendable {
    let name: String
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
        update: @escaping @MainActor @Sendable (
            NearbyServerDiscoveryState
        ) -> Void
    )
    func cancel()
}

enum NearbyServerAdvertisementMapper {
    static func serverURL(
        for advertisement: NearbyServerAdvertisement
    ) throws(NearbyServerDiscoveryFailure) -> NormalizedServerURL {
        guard !advertisement.host.isEmpty,
              advertisement.port > 0,
              advertisement.host.rangeOfCharacter(
                from: .whitespacesAndNewlines
              ) == nil
        else {
            throw .invalidAdvertisement
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = advertisement.host
        if advertisement.port != 443 {
            components.port = Int(advertisement.port)
        }

        if advertisement.serviceType == .audiobookshelf,
           let path = advertisement.path
        {
            guard path.hasPrefix("/"),
                  !path.hasPrefix("//"),
                  !path.contains("?"),
                  !path.contains("#"),
                  URLComponents(string: "https://example.invalid\(path)")?
                    .percentEncodedPath == path
            else {
                throw .invalidAdvertisement
            }
            components.percentEncodedPath = path
        }

        guard let value = components.string else {
            throw .invalidAdvertisement
        }
        do {
            return try NormalizedServerURL(value)
        } catch {
            throw .invalidAdvertisement
        }
    }

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
        return byURL.values.sorted(by: {
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            if nameOrder == .orderedSame {
                return $0.server.baseURL.url.absoluteString
                    < $1.server.baseURL.url.absoluteString
            }
            return nameOrder == .orderedAscending
        })
    }
}

@MainActor
final class BonjourNearbyServerDiscovery: NearbyServerDiscovering {
    private let verifier: @Sendable (NormalizedServerURL) async throws
        -> DiscoveredServer
    private var browsers: [NWBrowser] = []
    private var resolvers: [NearbyServiceResolver] = []
    private var results: [NearbyServerResult] = []
    private var generation: UInt64 = 0
    private var settledServiceCount = 0
    private var verificationFailureCount = 0
    private var update: (@MainActor @Sendable (
        NearbyServerDiscoveryState
    ) -> Void)?
    private var noResultsTask: Task<Void, Never>?

    init(
        verifier: @escaping @Sendable (NormalizedServerURL) async throws
            -> DiscoveredServer = { server in
                try await ServerDiscoveryClient(
                    transport: URLSessionHTTPTransport(routesRequests: false)
                ).discover(server)
            }
    ) {
        self.verifier = verifier
    }

    func start(
        update: @escaping @MainActor @Sendable (
            NearbyServerDiscoveryState
        ) -> Void
    ) {
        cancel()
        generation &+= 1
        let currentGeneration = generation
        self.update = update
        results = []
        settledServiceCount = 0
        verificationFailureCount = 0
        update(.searching)

        for serviceType in NearbyServerServiceType.allCases {
            let descriptor = NWBrowser.Descriptor.bonjour(
                type: serviceType.rawValue,
                domain: "local."
            )
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let browser = NWBrowser(for: descriptor, using: parameters)
            browser.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleBrowserState(
                        state,
                        generation: currentGeneration
                    )
                }
            }
            browser.browseResultsChangedHandler = {
                [weak self] browserResults, _ in
                Task { @MainActor [weak self] in
                    self?.handle(
                        browserResults,
                        generation: currentGeneration
                    )
                }
            }
            browsers.append(browser)
            browser.start(queue: .global(qos: .userInitiated))
        }

        noResultsTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled,
                  let self,
                  generation == currentGeneration,
                  results.isEmpty,
                  settledServiceCount == 0
            else {
                return
            }
            update(.noResults)
        }
    }

    func cancel() {
        generation &+= 1
        noResultsTask?.cancel()
        noResultsTask = nil
        browsers.forEach { $0.cancel() }
        browsers = []
        resolvers.forEach { $0.cancel() }
        resolvers = []
        results = []
        update = nil
    }

    private func handleBrowserState(
        _ state: NWBrowser.State,
        generation expectedGeneration: UInt64
    ) {
        guard generation == expectedGeneration else { return }
        switch state {
        case .failed(let error), .waiting(let error):
            update?(.failed(Self.failure(for: error)))
        case .ready, .setup, .cancelled:
            break
        @unknown default:
            update?(.failed(.localNetworkUnavailable))
        }
    }

    private func handle(
        _ browserResults: Set<NWBrowser.Result>,
        generation expectedGeneration: UInt64
    ) {
        guard generation == expectedGeneration else { return }
        for browserResult in browserResults {
            guard case let .service(name, type, _, _) = browserResult.endpoint,
                  let serviceType = NearbyServerServiceType(rawValue: type),
                  !resolvers.contains(where: {
                    $0.endpoint == browserResult.endpoint
                  })
            else {
                continue
            }
            let path: String?
            do {
                path = try Self.path(
                    from: browserResult.metadata,
                    serviceType: serviceType
                )
            } catch let failure {
                settledServiceCount += 1
                if results.isEmpty {
                    update?(.failed(failure))
                }
                continue
            }
            let resolver = NearbyServiceResolver(
                endpoint: browserResult.endpoint,
                name: name,
                serviceType: serviceType,
                path: path
            ) { [weak self] resolution in
                guard let self, generation == expectedGeneration else {
                    return
                }
                await resolved(
                    resolution,
                    generation: expectedGeneration
                )
            }
            resolvers.append(resolver)
            resolver.start()
        }
    }

    private func resolved(
        _ resolution: Result<NearbyServerAdvertisement, NearbyServerDiscoveryFailure>,
        generation expectedGeneration: UInt64
    ) async {
        guard generation == expectedGeneration else { return }
        settledServiceCount += 1
        switch resolution {
        case .failure(let failure):
            if results.isEmpty {
                update?(.failed(failure))
            }
        case .success(let advertisement):
            let server: NormalizedServerURL
            do {
                server = try NearbyServerAdvertisementMapper.serverURL(
                    for: advertisement
                )
            } catch let failure {
                if results.isEmpty {
                    update?(.failed(failure))
                }
                return
            }
            do {
                let discovered = try await verifier(server)
                guard generation == expectedGeneration else { return }
                results.append(
                    NearbyServerResult(
                        name: advertisement.name,
                        server: discovered
                    )
                )
                results = NearbyServerAdvertisementMapper.deduplicated(results)
                update?(.results(results))
            } catch {
                guard generation == expectedGeneration else { return }
                verificationFailureCount += 1
                if results.isEmpty,
                   verificationFailureCount == settledServiceCount
                {
                    update?(.failed(.serverVerificationFailed))
                }
            }
        }
    }

    static func path(
        from metadata: NWBrowser.Result.Metadata,
        serviceType: NearbyServerServiceType
    ) throws(NearbyServerDiscoveryFailure) -> String? {
        guard serviceType == .audiobookshelf,
              case .bonjour(let record) = metadata
        else {
            return nil
        }
        switch record.getEntry(for: "path") {
        case .some(.string(let value)):
            return value
        case .some(.data(let data)):
            return try utf8Path(from: data)
        case .some(.empty):
            return nil
        case .some(.none), nil:
            return nil
        @unknown default:
            return nil
        }
    }

    static func utf8Path(
        from data: Data
    ) throws(NearbyServerDiscoveryFailure) -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw .invalidAdvertisement
        }
        return value
    }

    private static func failure(
        for error: NWError
    ) -> NearbyServerDiscoveryFailure {
        guard case .posix(let code) = error else {
            return .localNetworkUnavailable
        }
        switch code {
        case .EACCES, .EPERM:
            return NearbyServerDiscoveryFailure.permissionDenied
        case .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH, .ENODEV:
            return NearbyServerDiscoveryFailure.localNetworkUnavailable
        default:
            return NearbyServerDiscoveryFailure.resolutionFailed
        }
    }
}

@MainActor
private final class NearbyServiceResolver {
    let endpoint: NWEndpoint
    private let name: String
    private let serviceType: NearbyServerServiceType
    private let path: String?
    private let completion: @MainActor @Sendable (
        Result<NearbyServerAdvertisement, NearbyServerDiscoveryFailure>
    ) async -> Void
    private var connection: NWConnection?
    private var completed = false

    init(
        endpoint: NWEndpoint,
        name: String,
        serviceType: NearbyServerServiceType,
        path: String?,
        completion: @escaping @MainActor @Sendable (
            Result<NearbyServerAdvertisement, NearbyServerDiscoveryFailure>
        ) async -> Void
    ) {
        self.endpoint = endpoint
        self.name = name
        self.serviceType = serviceType
        self.path = path
        self.completion = completion
    }

    func start() {
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                await self?.handle(state)
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    func cancel() {
        completed = true
        connection?.cancel()
        connection = nil
    }

    private func handle(_ state: NWConnection.State) async {
        guard !completed else { return }
        switch state {
        case .ready:
            guard case let .hostPort(host, port) =
                    connection?.currentPath?.remoteEndpoint
            else {
                await finish(.failure(.resolutionFailed))
                return
            }
            await finish(.success(NearbyServerAdvertisement(
                name: name,
                serviceType: serviceType,
                host: Self.hostString(host),
                port: port.rawValue,
                path: path
            )))
        case .failed:
            await finish(.failure(.resolutionFailed))
        case .cancelled, .setup, .preparing, .waiting:
            break
        @unknown default:
            await finish(.failure(.resolutionFailed))
        }
    }

    private func finish(
        _ result: Result<NearbyServerAdvertisement, NearbyServerDiscoveryFailure>
    ) async {
        guard !completed else { return }
        completed = true
        connection?.cancel()
        connection = nil
        await completion(result)
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let value, _): value
        case .ipv4(let address): address.debugDescription
        case .ipv6(let address): address.debugDescription
        @unknown default: host.debugDescription
        }
    }
}

@MainActor
final class UnavailableNearbyServerDiscovery: NearbyServerDiscovering {
    func start(
        update: @escaping @MainActor @Sendable (
            NearbyServerDiscoveryState
        ) -> Void
    ) {
        update(.failed(.localNetworkUnavailable))
    }

    func cancel() {}
}
