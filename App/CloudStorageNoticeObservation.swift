import Foundation

final class CloudStorageNoticeObservation {
    private let token: any NSObjectProtocol

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { @Sendable _ in
            Task { @MainActor in onChange() }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
