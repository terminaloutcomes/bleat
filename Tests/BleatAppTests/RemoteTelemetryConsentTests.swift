import Foundation
import XCTest

@testable import Bleat

@MainActor
final class RemoteTelemetryConsentTests: XCTestCase {
    func testConsentDefaultsOffAndPersistsOnlyExplicitChanges() throws {
        let suite = "RemoteTelemetryConsentTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = RemoteTelemetryConsentStore(defaults: defaults)
        XCTAssertFalse(first.isEnabled)
        XCTAssertNil(
            defaults.object(forKey: RemoteTelemetryConsentStore.enabledKey)
        )

        first.setEnabled(true)
        let restored = RemoteTelemetryConsentStore(defaults: defaults)
        XCTAssertTrue(restored.isEnabled)
        XCTAssertEqual(
            defaults.persistentDomain(forName: suite)?.keys.sorted(),
            [RemoteTelemetryConsentStore.enabledKey]
        )

        restored.setEnabled(false)
        XCTAssertFalse(
            RemoteTelemetryConsentStore(defaults: defaults).isEnabled
        )
    }

    func testAppModelDoesNotInitializeRemoteTelemetryWhileDisabled() throws {
        let suite = "RemoteTelemetryConsentTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = RecordingRemoteTelemetryConsentController()

        let model = AppModel(
            service: UnavailableAppService(),
            remoteTelemetryConsentStore: RemoteTelemetryConsentStore(
                defaults: defaults
            ),
            remoteTelemetryConsentController: controller
        )

        XCTAssertFalse(model.remoteTelemetryEnabled)
        XCTAssertEqual(controller.values, [])
    }

    func testPersistedOptInInitializesRemoteTelemetry() throws {
        let suite = "RemoteTelemetryConsentTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RemoteTelemetryConsentStore(defaults: defaults)
        store.setEnabled(true)
        let controller = RecordingRemoteTelemetryConsentController()

        let model = AppModel(
            service: UnavailableAppService(),
            remoteTelemetryConsentStore: store,
            remoteTelemetryConsentController: controller
        )

        XCTAssertTrue(model.remoteTelemetryEnabled)
        XCTAssertEqual(controller.values, [true])
    }

    func testEnableAndWithdrawalPersistBeforeNotifyingRuntime() throws {
        let suite = "RemoteTelemetryConsentTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = RecordingRemoteTelemetryConsentController(
            defaultsSuiteName: suite
        )
        let model = AppModel(
            service: UnavailableAppService(),
            remoteTelemetryConsentStore: RemoteTelemetryConsentStore(
                defaults: defaults
            ),
            remoteTelemetryConsentController: controller
        )

        model.setRemoteTelemetryEnabled(true)
        XCTAssertTrue(model.remoteTelemetryEnabled)
        model.setRemoteTelemetryEnabled(false)
        XCTAssertFalse(model.remoteTelemetryEnabled)

        XCTAssertEqual(controller.values, [true, false])
        XCTAssertEqual(controller.persistedValues, [true, false])
        XCTAssertFalse(
            defaults.bool(forKey: RemoteTelemetryConsentStore.enabledKey)
        )
    }

    func testUnavailableRuntimeCannotChangeConsentOrCoreState() throws {
        let suite = "RemoteTelemetryConsentTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(
            service: UnavailableAppService(),
            remoteTelemetryConsentStore: RemoteTelemetryConsentStore(
                defaults: defaults
            ),
            remoteTelemetryConsentController:
                UnavailableRemoteTelemetryConsentController()
        )
        let phase = model.phase

        model.setRemoteTelemetryEnabled(true)

        XCTAssertTrue(model.remoteTelemetryEnabled)
        XCTAssertEqual(model.phase, phase)
        XCTAssertTrue(
            defaults.bool(forKey: RemoteTelemetryConsentStore.enabledKey)
        )
    }

    func testRapidConsentChangesEndWithImmediateWithdrawal() throws {
        let suite = "RemoteTelemetryConsentTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = RecordingRemoteTelemetryConsentController()
        let model = AppModel(
            service: UnavailableAppService(),
            remoteTelemetryConsentStore: RemoteTelemetryConsentStore(
                defaults: defaults
            ),
            remoteTelemetryConsentController: controller
        )

        model.setRemoteTelemetryEnabled(true)
        model.setRemoteTelemetryEnabled(false)

        XCTAssertEqual(controller.values, [true, false])
        XCTAssertFalse(model.remoteTelemetryEnabled)
        XCTAssertFalse(
            defaults.bool(forKey: RemoteTelemetryConsentStore.enabledKey)
        )
    }
}

@MainActor
private final class RecordingRemoteTelemetryConsentController:
    RemoteTelemetryConsentApplying
{
    private let defaultsSuiteName: String?
    private(set) var values: [Bool] = []
    private(set) var persistedValues: [Bool] = []

    init(defaultsSuiteName: String? = nil) {
        self.defaultsSuiteName = defaultsSuiteName
    }

    func applyRemoteTelemetryConsent(_ enabled: Bool) {
        values.append(enabled)
        if let defaultsSuiteName,
            let defaults = UserDefaults(suiteName: defaultsSuiteName)
        {
            persistedValues.append(
                defaults.bool(
                    forKey: RemoteTelemetryConsentStore.enabledKey
                )
            )
        }
    }
}

@MainActor
private struct UnavailableRemoteTelemetryConsentController:
    RemoteTelemetryConsentApplying
{
    func applyRemoteTelemetryConsent(_ enabled: Bool) {
        // A telemetry runtime owns and contains its own failures.
    }
}
