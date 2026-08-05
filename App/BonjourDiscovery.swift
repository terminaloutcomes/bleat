import BleatCore
import Foundation
import Network
import OSLog
import dnssd

private let bonjourLog = Logger(
    subsystem: "com.yaleman.bleat",
    category: "bonjour-discovery"
)

struct BonjourServiceID: Hashable, Sendable {
    let name: String
    let type: String
    let domain: String
    let interfaceIndex: UInt32
}

struct BonjourDiscoveredService: Hashable, Sendable {
    let id: BonjourServiceID
    let interfaceName: String?

    var name: String { id.name }
    var type: String { id.type }
    var domain: String { id.domain }
    var interfaceIndex: UInt32 { id.interfaceIndex }
}

struct ResolvedBonjourService: Equatable, Sendable {
    let service: BonjourDiscoveredService
    let host: String
    let port: UInt16
    let txt: [String: Data]
    let path: String
    let baseURL: NormalizedServerURL
}

enum BonjourResolutionError: Error, Equatable, Sendable {
    case invalidService
    case missingHostname
    case invalidHostname(String)
    case invalidPort(UInt16)
    case invalidTXTPath
    case invalidURL
    case dnsServiceFailure(Int32)
    case timedOut
}

enum BonjourBrowserEvent: Sendable {
    case ready
    case added(BonjourDiscoveredService)
    case changed(BonjourDiscoveredService)
    case removed(BonjourDiscoveredService)
    case failed(NWError)
}

struct BonjourResolveRequest: Equatable, Sendable {
    let name: String
    let type: String
    let domain: String
    let interfaceIndex: UInt32

    init(
        name: String,
        type: String,
        domain: String,
        interfaceIndex: UInt32
    ) {
        self.name = name
        self.type = type
        self.domain = domain
        self.interfaceIndex = interfaceIndex
    }

    init(service: BonjourDiscoveredService) {
        self.init(
            name: service.name,
            type: service.type,
            domain: service.domain,
            interfaceIndex: service.interfaceIndex
        )
    }
}

@MainActor
final class BonjourServiceBrowser {
    private var browser: NWBrowser?
    private var resultsByID: [BonjourServiceID: NWBrowser.Result] = [:]
    private var generation: UInt64 = 0
    private var eventHandler:
        (@MainActor @Sendable (BonjourBrowserEvent) -> Void)?

    func start(
        onEvent: @escaping @MainActor @Sendable (BonjourBrowserEvent) -> Void
    ) {
        cancel()
        generation &+= 1
        let expectedGeneration = generation
        eventHandler = onEvent

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(
                type: "_audiobookshelf._tcp",
                domain: "local."
            ),
            using: .tcp
        )
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, generation == expectedGeneration else { return }
                switch state {
                case .ready:
                    eventHandler?(.ready)
                case .failed(let error), .waiting(let error):
                    eventHandler?(.failed(error))
                case .setup, .cancelled:
                    break
                @unknown default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self, generation == expectedGeneration else { return }
                replaceResults(with: results)
            }
        }

        self.browser = browser
        browser.start(queue: .global(qos: .userInitiated))
    }

    func cancel() {
        generation &+= 1
        browser?.cancel()
        browser = nil
        resultsByID = [:]
        eventHandler = nil
    }

    private func replaceResults(with results: Set<NWBrowser.Result>) {
        var newResultsByID: [BonjourServiceID: NWBrowser.Result] = [:]
        var servicesByID: [BonjourServiceID: BonjourDiscoveredService] = [:]

        for result in results {
            guard let service = Self.discoveredService(from: result) else {
                continue
            }
            newResultsByID[service.id] = result
            servicesByID[service.id] = service
        }

        for (id, oldResult) in resultsByID {
            guard newResultsByID[id] == nil,
                  let oldService = Self.discoveredService(from: oldResult)
            else {
                continue
            }
            eventHandler?(.removed(oldService))
        }

        for (id, newResult) in newResultsByID {
            guard let service = servicesByID[id] else { continue }
            guard let oldResult = resultsByID[id] else {
                eventHandler?(.added(service))
                continue
            }
            if oldResult.metadata != newResult.metadata {
                eventHandler?(.changed(service))
            }
        }

        resultsByID = newResultsByID
    }

    static func discoveredService(
        from result: NWBrowser.Result
    ) -> BonjourDiscoveredService? {
        guard case let .service(name, type, domain, endpointInterface) =
                result.endpoint,
              !name.isEmpty,
              !type.isEmpty,
              !domain.isEmpty
        else {
            return nil
        }

        let interface = endpointInterface ?? result.interfaces.first
        guard let rawIndex = interface?.index,
              let interfaceIndex = UInt32(exactly: rawIndex),
              interfaceIndex > 0
        else {
            return nil
        }

        return BonjourDiscoveredService(
            id: BonjourServiceID(
                name: name,
                type: type,
                domain: domain,
                interfaceIndex: interfaceIndex
            ),
            interfaceName: interface?.name
        )
    }
}

@MainActor
final class BonjourServiceResolver {
    private var activeResolutions:
        [BonjourServiceID: Task<ResolvedBonjourService, Error>] = [:]

    func resolve(
        _ service: BonjourDiscoveredService
    ) async throws -> ResolvedBonjourService {
        if let active = activeResolutions[service.id] {
            return try await active.value
        }

        let task = Task<ResolvedBonjourService, Error> {
            try await BonjourDNSServiceResolution(service: service).run()
        }
        activeResolutions[service.id] = task
        defer { activeResolutions.removeValue(forKey: service.id) }
        return try await task.value
    }

    func cancel(_ id: BonjourServiceID) {
        activeResolutions.removeValue(forKey: id)?.cancel()
    }

    func cancelAll() {
        let tasks = activeResolutions.values
        activeResolutions = [:]
        for task in tasks {
            task.cancel()
        }
    }
}

private final class BonjourDNSServiceResolution: @unchecked Sendable {
    private let service: BonjourDiscoveredService
    private let timeout: Duration
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<ResolvedBonjourService, Error>?
    private var serviceRef: DNSServiceRef?
    private var timeoutTask: Task<Void, Never>?
    private var completed = false

    init(
        service: BonjourDiscoveredService,
        timeout: Duration = .seconds(5)
    ) {
        self.service = service
        self.timeout = timeout
    }

    func run() async throws -> ResolvedBonjourService {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(continuation: continuation)
            }
        } onCancel: { [self] in
            finish(.failure(CancellationError()))
        }
    }

    private func start(
        continuation: CheckedContinuation<ResolvedBonjourService, Error>
    ) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()

        let request = BonjourResolveRequest(service: service)
        var newServiceRef: DNSServiceRef?
        let result = request.name.withCString { name in
            request.type.withCString { type in
                request.domain.withCString { domain in
                    DNSServiceResolve(
                        &newServiceRef,
                        0,
                        request.interfaceIndex,
                        name,
                        type,
                        domain,
                        Self.callback,
                        Unmanaged.passUnretained(self).toOpaque()
                    )
                }
            }
        }

        guard result == kDNSServiceErr_NoError,
              let newServiceRef
        else {
            finish(.failure(
                BonjourResolutionError.dnsServiceFailure(Int32(result))
            ))
            return
        }

        let queueResult = DNSServiceSetDispatchQueue(
            newServiceRef,
            .global(qos: .userInitiated)
        )
        guard queueResult == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(newServiceRef)
            finish(.failure(
                BonjourResolutionError.dnsServiceFailure(Int32(queueResult))
            ))
            return
        }

        lock.lock()
        if completed {
            lock.unlock()
            DNSServiceRefDeallocate(newServiceRef)
            return
        }
        serviceRef = newServiceRef
        lock.unlock()

        let timeoutTask = Task { [weak self, timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finish(.failure(BonjourResolutionError.timedOut))
        }
        lock.lock()
        if completed {
            lock.unlock()
            timeoutTask.cancel()
        } else {
            self.timeoutTask = timeoutTask
            lock.unlock()
        }
    }

    private static let callback: DNSServiceResolveReply = {
        _, _, _, errorCode, _, hostTarget, port, txtLength, txtRecord, context in
        guard let context else { return }
        let resolution = Unmanaged<BonjourDNSServiceResolution>
            .fromOpaque(context)
            .takeUnretainedValue()
        resolution.handleCallback(
            errorCode: errorCode,
            hostTarget: hostTarget,
            networkPort: port,
            txtLength: txtLength,
            txtRecord: txtRecord
        )
    }

    private func handleCallback(
        errorCode: DNSServiceErrorType,
        hostTarget: UnsafePointer<CChar>?,
        networkPort: UInt16,
        txtLength: UInt16,
        txtRecord: UnsafePointer<UInt8>?
    ) {
        guard errorCode == kDNSServiceErr_NoError else {
            finish(.failure(
                BonjourResolutionError.dnsServiceFailure(Int32(errorCode))
            ))
            return
        }
        guard let hostTarget else {
            finish(.failure(BonjourResolutionError.missingHostname))
            return
        }

        let host = String(cString: hostTarget)
        let port = UInt16(bigEndian: networkPort)
        let txtData: Data
        if txtLength == 0 {
            txtData = Data()
        } else if let txtRecord {
            txtData = Data(bytes: txtRecord, count: Int(txtLength))
        } else {
            finish(.failure(BonjourResolutionError.invalidTXTPath))
            return
        }

        do {
            let resolved = try AudiobookshelfEndpointBuilder.resolvedService(
                service: service,
                host: host,
                port: port,
                txtData: txtData
            )
            finish(.success(resolved))
        } catch let error as BonjourResolutionError {
            finish(.failure(error))
        } catch {
            finish(.failure(BonjourResolutionError.invalidURL))
        }
    }

    private func finish(
        _ result: Result<ResolvedBonjourService, Error>
    ) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        let serviceRef = self.serviceRef
        self.serviceRef = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        if let serviceRef {
            DNSServiceRefDeallocate(serviceRef)
        }
        continuation?.resume(with: result)
    }
}

enum AudiobookshelfEndpointBuilder {
    static func resolvedService(
        service: BonjourDiscoveredService,
        host: String,
        port: UInt16,
        txtData: Data
    ) throws -> ResolvedBonjourService {
        let txt = txtData.isEmpty
            ? [:]
            : NetService.dictionary(fromTXTRecord: txtData)
        let path: String
        if let pathData = txt["path"] {
            guard let value = String(data: pathData, encoding: .utf8) else {
                throw BonjourResolutionError.invalidTXTPath
            }
            path = value
        } else {
            path = "/"
        }

        let baseURL = try AudiobookshelfEndpointBuilder.normalizedURL(
            host: host,
            port: port,
            path: path
        )
        bonjourLog.debug(
            "Resolved service \(service.name, privacy: .private) to \(baseURL.url.absoluteString, privacy: .private)"
        )
        return ResolvedBonjourService(
            service: service,
            host: AudiobookshelfEndpointBuilder.removeDNSRootDot(host),
            port: port,
            txt: txt,
            path: path,
            baseURL: baseURL
        )
    }

    static func normalizedURL(
        host: String,
        port: UInt16,
        path: String
    ) throws -> NormalizedServerURL {
        let cleanHost = removeDNSRootDot(host)
        guard validDNSHostname(cleanHost) else {
            throw BonjourResolutionError.invalidHostname(host)
        }
        guard port > 0 else {
            throw BonjourResolutionError.invalidPort(port)
        }
        guard validPath(path) else {
            throw BonjourResolutionError.invalidTXTPath
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = cleanHost
        if port != 443 {
            components.port = Int(port)
        }
        components.percentEncodedPath = path
        guard let url = components.url else {
            throw BonjourResolutionError.invalidURL
        }
        do {
            return try NormalizedServerURL(url.absoluteString)
        } catch {
            throw BonjourResolutionError.invalidURL
        }
    }

    static func removeDNSRootDot(_ host: String) -> String {
        host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    private static func validDNSHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253,
              host.unicodeScalars.allSatisfy(\.isASCII)
        else {
            return false
        }
        return host.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { label in
                guard !label.isEmpty, label.utf8.count <= 63,
                      label.first != "-", label.last != "-"
                else {
                    return false
                }
                return label.allSatisfy {
                    $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
                }
            }
    }

    private static func validPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              !path.contains("?"), !path.contains("#"),
              let components = URLComponents(
                string: "https://example.invalid\(path)"
              ),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath == path
        else {
            return false
        }
        return true
    }
}
