import Foundation
import Network

final class AppNetworkPathMonitor: @unchecked Sendable {
    private let monitor: NWPathMonitor

    init(onChange: @escaping @Sendable () -> Void) {
        monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { _ in
            onChange()
        }
        monitor.start(
            queue: DispatchQueue(
                label: "com.yaleman.Bleat.network-path-monitor",
                qos: .utility
            )
        )
    }

    deinit {
        monitor.cancel()
    }
}
