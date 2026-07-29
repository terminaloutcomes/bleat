import BleatCore
import Foundation

enum PlaybackPositionStoreError: Error, Equatable {
    case invalidPosition
    case persistenceFailed
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
        "\(accountID.rawValue.utf8.count):\(accountID.rawValue)"
            + itemID.rawValue
    }
}
