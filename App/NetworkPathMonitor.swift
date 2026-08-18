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
        isExpensive: Bool
    ) {
        self.availability = availability
        self.isConstrained = isConstrained
        self.isExpensive = isExpensive
    }

    init(path: NWPath) {
        availability = path.status == .satisfied ? .satisfied : .unavailable
        isConstrained = path.isConstrained
        isExpensive = path.isExpensive
    }
}

final class AppNetworkPathMonitor: @unchecked Sendable {
    private let monitor: NWPathMonitor

    init(onChange: @escaping @Sendable (AppNetworkPathState) -> Void) {
        monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            onChange(AppNetworkPathState(path: path))
        }
        monitor.start(
            queue: DispatchQueue(
                label: "com.terminaloutcomes.Bleat.network-path-monitor",
                qos: .utility
            )
        )
    }

    deinit {
        monitor.cancel()
    }
}
