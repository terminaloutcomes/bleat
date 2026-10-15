import BleatCore
import Darwin
import Foundation
import Network

enum AppNetworkAvailability: Equatable, Sendable {
    case unknown
    case satisfied
    case unavailable
}

struct AppNetworkPathState: Equatable, Sendable {
    let availability: AppNetworkAvailability
    let isConstrained: Bool
    let isExpensive: Bool
    let routing: AppNetworkRoutingState?
    let linkQuality: AppNetworkLinkQuality
    var endpointRevision: Int = 0

    static let unknown = AppNetworkPathState(
        availability: .unknown,
        isConstrained: false,
        isExpensive: false
    )

    var allowsRealtimeUpdates: Bool {
        availability == .satisfied && !isConstrained
    }

    init(
        availability: AppNetworkAvailability,
        isConstrained: Bool,
        isExpensive: Bool,
        routing: AppNetworkRoutingState? = nil,
        linkQuality: AppNetworkLinkQuality = .unknown
    ) {
        self.availability = availability
        self.isConstrained = isConstrained
        self.isExpensive = isExpensive
        self.routing = routing
        self.linkQuality = linkQuality
    }

    init(path: NWPath) {
        availability = path.status == .satisfied ? .satisfied : .unavailable
        isConstrained = path.isConstrained
        isExpensive = path.isExpensive
        routing = AppNetworkRoutingState(path: path)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch path.linkQuality {
            case .good: linkQuality = .good
            case .moderate: linkQuality = .moderate
            case .minimal: linkQuality = .minimal
            case .unknown: linkQuality = .unknown
            @unknown default: linkQuality = .unknown
            }
        } else {
            linkQuality = .unknown
        }
    }

    func change(from previous: Self) -> DiagnosticNetworkReason {
        if availability != previous.availability {
            switch availability {
            case .unknown: return .initialPath
            case .unavailable: return .connectivityLost
            case .satisfied:
                return previous.availability == .unknown
                    ? .initialPath : .connectivityRecovered
            }
        }
        if isConstrained != previous.isConstrained {
            return isConstrained ? .lowDataModeEntered : .lowDataModeExited
        }
        if routing != previous.routing {
            switch routing?.addresses {
            case .enumerationFailed: return .routeAddressEnumerationFailed
            case .decodingFailed: return .routeAddressDecodingFailed
            case .available, nil: return .routingChanged
            }
        }
        if isExpensive != previous.isExpensive { return .costChanged }
        if endpointRevision != previous.endpointRevision {
            return .endpointChanged
        }
        return linkQuality == previous.linkQuality
            ? .duplicatePath : .qualityOnly
    }
}

enum AppNetworkLinkQuality: Equatable, Sendable {
    case unknown, minimal, moderate, good
}

// This is an in-memory routing snapshot, never a trust decision or diagnostic payload.
// In particular, interface names alone do not identify a Wi-Fi network.
struct AppNetworkRoutingState: Equatable, Sendable {
    struct Interface: Equatable, Sendable {
        let index: Int
        let type: NWInterface.InterfaceType
        var isUsed = true
    }

    struct Address: Hashable, Sendable {
        let interface: String
        let host: NWEndpoint.Host
    }

    let interfaces: [Interface]
    let gateways: Set<NWEndpoint>
    enum AddressSnapshot: Equatable, Sendable {
        case available(Set<Address>)
        case enumerationFailed
        case decodingFailed
    }

    let addresses: AddressSnapshot
    let supportsIPv4: Bool
    let supportsIPv6: Bool
    let supportsDNS: Bool

    init(
        interfaces: [Interface], gateways: Set<NWEndpoint>,
        addresses: Set<Address> = [], supportsIPv4: Bool = true,
        supportsIPv6: Bool = true, supportsDNS: Bool = true
    ) {
        self.interfaces = interfaces
        self.gateways = gateways
        self.addresses = .available(addresses)
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.supportsDNS = supportsDNS
    }

    init(path: NWPath) {
        interfaces = path.availableInterfaces.map {
            Interface(
                index: $0.index, type: $0.type,
                isUsed: path.usesInterfaceType($0.type))
        }
        gateways = Set(path.gateways)
        supportsIPv4 = path.supportsIPv4
        supportsIPv6 = path.supportsIPv6
        supportsDNS = path.supportsDNS
        var addresses: Set<Address> = []
        var head: UnsafeMutablePointer<ifaddrs>?
        var snapshotFailure: AddressSnapshot?
        if getifaddrs(&head) == 0 {
            defer { freeifaddrs(head) }
            let names = Set(path.availableInterfaces.map(\.name))
            var cursor = head
            while let entry = cursor {
                defer { cursor = entry.pointee.ifa_next }
                guard let name = entry.pointee.ifa_name,
                    let address = entry.pointee.ifa_addr
                else { continue }
                let interface = String(cString: name)
                guard names.contains(interface),
                    address.pointee.sa_family == AF_INET
                        || address.pointee.sa_family == AF_INET6
                else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    address, socklen_t(address.pointee.sa_len),
                    &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
                ) == 0 {
                    addresses.insert(
                        Address(
                            interface: interface,
                            host: NWEndpoint.Host(
                                String(
                                    decoding: host.prefix { $0 != 0 }.map {
                                        UInt8(bitPattern: $0)
                                    },
                                    as: UTF8.self))))
                } else {
                    snapshotFailure = .decodingFailed
                }
            }
        } else {
            snapshotFailure = .enumerationFailed
        }
        self.addresses = snapshotFailure ?? .available(addresses)
    }
}

final class AppNetworkPathMonitor: @unchecked Sendable {
    private let monitor: NWPathMonitor
    let updates: AsyncStream<AppNetworkPathState>

    init() {
        monitor = NWPathMonitor()
        let stream = AsyncStream<AppNetworkPathState>.makeStream()
        updates = stream.stream
        monitor.pathUpdateHandler = Self.makePathUpdateHandler {
            stream.continuation.yield($0)
        }
        monitor.start(
            queue: DispatchQueue(
                label: "com.terminaloutcomes.Bleat.network-path-monitor",
                qos: .utility
            )
        )
    }

    // The same adapter is exercised off-actor in tests. Serial stream consumption
    // preserves rapid callback order without one unstructured task per notification.
    static func makePathUpdateHandler(
        snapshot: @escaping @Sendable (NWPath) -> AppNetworkPathState = {
            AppNetworkPathState(path: $0)
        },
        onChange: @escaping @Sendable (AppNetworkPathState) -> Void
    ) -> @Sendable (NWPath) -> Void {
        { @Sendable path in onChange(snapshot(path)) }
    }

    deinit {
        monitor.cancel()
    }
}
