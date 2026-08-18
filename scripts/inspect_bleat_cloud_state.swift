import CloudKit
import Foundation

final class InspectionDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    func handleEvent(
        _ event: CKSyncEngine.Event,
        syncEngine: CKSyncEngine
    ) async {}

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        nil
    }
}

@main
struct InspectBleatCloudState {
    static func main() async throws {
        let url = URL(fileURLWithPath: "/tmp/bleat-cloud-state.json")
        let data = try Data(contentsOf: url)
        let serialization = try JSONDecoder().decode(
            CKSyncEngine.State.Serialization.self,
            from: data
        )
        let delegate = InspectionDelegate()
        var configuration = CKSyncEngine.Configuration(
            database: CKContainer(
                identifier: "iCloud.com.terminaloutcomes.Bleat"
            ).privateCloudDatabase,
            stateSerialization: serialization,
            delegate: delegate
        )
        configuration.automaticallySync = false
        let engine = CKSyncEngine(configuration)
        print(
            "pending_database_changes=\(engine.state.pendingDatabaseChanges.count)"
        )
        print(
            "pending_record_changes=\(engine.state.pendingRecordZoneChanges.count)"
        )
    }
}
