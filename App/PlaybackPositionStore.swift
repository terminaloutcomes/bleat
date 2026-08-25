import BleatCore
import Foundation

enum PlaybackPositionStoreError: Error, Equatable {
    case invalidPosition
    case persistenceFailed
}

enum DownloadedPositionDecision: Equatable {
    case local(Double)
    case server(Double)
    case conflict(local: Double, server: Double)
}

enum DownloadedPositionReconciler {
    static func decide(
        savedPosition: Double?,
        baseline: LibraryBookProgress?,
        remote: LibraryBookProgress?,
        duration: Double
    ) -> DownloadedPositionDecision {
        let baselineTime = baseline?.currentTime ?? 0
        let localTime = min(
            max(savedPosition ?? baselineTime, 0),
            duration
        )
        guard let remote else {
            return .local(localTime)
        }
        let serverTime = min(max(remote.currentTime, 0), duration)
        let localChanged =
            savedPosition != nil && abs(localTime - baselineTime) > 1
        let serverChanged =
            remote.lastUpdateMilliseconds
            > (baseline?.lastUpdateMilliseconds ?? 0)
            && abs(serverTime - baselineTime) > 1
        if localChanged, serverChanged, abs(localTime - serverTime) > 1 {
            return .conflict(local: localTime, server: serverTime)
        }
        if serverChanged, !localChanged {
            return .server(serverTime)
        }
        return .local(localTime)
    }
}

@MainActor
final class PlaybackPositionStore {
    static let shared = PlaybackPositionStore(defaults: .standard)

    private let defaults: UserDefaults
    private let storageKey = "bleat.playbackPositions.v1"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func position(
        accountID: AccountID,
        itemID: LibraryItemID
    ) -> Double? {
        storedPositions()[key(accountID: accountID, itemID: itemID)]
    }

    func save(
        _ position: Double,
        accountID: AccountID,
        itemID: LibraryItemID
    ) throws(PlaybackPositionStoreError) {
        guard position.isFinite, position >= 0 else {
            throw .invalidPosition
        }
        var positions = storedPositions()
        positions[key(accountID: accountID, itemID: itemID)] = position
        guard
            let data = try? JSONEncoder().encode(positions)
        else {
            throw .persistenceFailed
        }
        defaults.set(data, forKey: storageKey)
    }

    func migrateAccountIdentity(
        from legacyID: AccountID,
        to canonicalID: AccountID
    ) throws(PlaybackPositionStoreError) {
        let legacyPrefix = accountPrefix(legacyID)
        let canonicalPrefix = accountPrefix(canonicalID)
        var positions = storedPositions()
        for key in positions.keys where key.hasPrefix(legacyPrefix) {
            guard let value = positions.removeValue(forKey: key) else {
                continue
            }
            let migratedKey = canonicalPrefix
                + key.dropFirst(legacyPrefix.count)
            positions[migratedKey] = max(positions[migratedKey] ?? 0, value)
        }
        guard let data = try? JSONEncoder().encode(positions) else {
            throw .persistenceFailed
        }
        defaults.set(data, forKey: storageKey)
    }

    private func storedPositions() -> [String: Double] {
        guard
            let data = defaults.data(forKey: storageKey),
            let positions = try? JSONDecoder().decode(
                [String: Double].self,
                from: data
            )
        else {
            return [:]
        }
        return positions.filter { $0.value.isFinite && $0.value >= 0 }
    }

    private func key(
        accountID: AccountID,
        itemID: LibraryItemID
    ) -> String {
        accountPrefix(accountID) + itemID.rawValue
    }

    private func accountPrefix(_ accountID: AccountID) -> String {
        "\(accountID.rawValue.utf8.count):\(accountID.rawValue)"
    }
}
