import Foundation
import XCTest

@testable import Bleat

@MainActor
final class RemoteTelemetryConsentTests: XCTestCase {
    func testSystemAppAttestRequiresEnabledEffectiveBuildMode() {
        XCTAssertEqual(
            RemoteTelemetryAttesterSelection.resolve(
                appAttestMode: "enabled",
                requestedMode: "app-attest"
            ),
            .appAttest
        )
        XCTAssertEqual(
            RemoteTelemetryAttesterSelection.resolve(
                appAttestMode: "disabled",
                requestedMode: "app-attest"
            ),
            .unavailable
        )
        XCTAssertEqual(
            RemoteTelemetryAttesterSelection.resolve(
                appAttestMode: nil,
                requestedMode: "app-attest"
            ),
            .unavailable
        )
    }

    #if DEBUG
        func testDevelopmentAttesterIgnoresAppAttestBuildMode() {
            XCTAssertEqual(
                RemoteTelemetryAttesterSelection.resolve(
                    appAttestMode: "disabled",
                    requestedMode: "fake"
                ),
                .development
            )
        }
    #endif

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
            [
                RemoteTelemetryConsentStore.enabledKey,
                RemoteTelemetryConsentStore.generationKey,
            ]
        )
        XCTAssertNotNil(restored.storageGeneration)

        restored.setEnabled(false)
        XCTAssertFalse(
            RemoteTelemetryConsentStore(defaults: defaults).isEnabled
        )
        XCTAssertNil(
            defaults.object(forKey: RemoteTelemetryConsentStore.generationKey)
        )
    }

    func testAppModelRequestsOrphanCleanupWithoutEnablingTelemetry() throws {
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
        XCTAssertEqual(controller.values, [false])
        XCTAssertEqual(controller.storageGenerations, [nil])
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
        XCTAssertEqual(controller.storageGenerations.count, 1)
        XCTAssertNotNil(controller.storageGenerations[0])
    }

    func testWithdrawalInvalidatesPersistedGenerationBeforeReenable() throws {
        let suite = "RemoteTelemetryConsentTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RemoteTelemetryConsentStore(defaults: defaults)

        let withdrawnGeneration = try XCTUnwrap(store.setEnabled(true))
        XCTAssertEqual(store.storageGeneration, withdrawnGeneration)

        XCTAssertEqual(store.setEnabled(false), withdrawnGeneration)
        XCTAssertNil(store.storageGeneration)
        XCTAssertNil(
            defaults.object(forKey: RemoteTelemetryConsentStore.generationKey)
        )

        let currentGeneration = try XCTUnwrap(
            RemoteTelemetryConsentStore(defaults: defaults).setEnabled(true)
        )
        XCTAssertNotEqual(currentGeneration, withdrawnGeneration)
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

        XCTAssertEqual(controller.values, [false, true, false])
        XCTAssertEqual(controller.persistedValues, [false, true, false])
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

        XCTAssertEqual(controller.values, [false, true, false])
        XCTAssertFalse(model.remoteTelemetryEnabled)
        XCTAssertFalse(
            defaults.bool(forKey: RemoteTelemetryConsentStore.enabledKey)
        )
    }

    func testReviewedAppOperationsEmitTypedTelemetryWithoutDomainValues()
        async throws
    {
        let tracer = RecordingRemoteTelemetryTracer()
        let model = AppModel(
            service: UnavailableAppService(),
            remoteTelemetryTracer: tracer
        )

        await model.start()
        _ = await model.login(
            serverAddress: "https://private.example/secret-path",
            username: "private-user",
            password: "private-password"
        )
        await model.refreshLibrariesForPullToRefresh()

        XCTAssertEqual(
            tracer.spans,
            [
                RecordedRemoteTelemetrySpan(
                    operation: .appLaunch,
                    source: nil,
                    retryBucket: .none,
                    outcome: .failed(.localStorage)
                ),
                RecordedRemoteTelemetrySpan(
                    operation: .accountConnection,
                    source: .remote,
                    retryBucket: .none,
                    outcome: .failed(.localStorage)
                ),
                RecordedRemoteTelemetrySpan(
                    operation: .libraryRefresh,
                    source: .remote,
                    retryBucket: .none,
                    outcome: .failed(.authentication)
                ),
            ]
        )
        let description = String(describing: tracer.spans)
        XCTAssertFalse(description.contains("private.example"))
        XCTAssertFalse(description.contains("private-user"))
        XCTAssertFalse(description.contains("private-password"))
    }

    func testSceneLifecycleIsForwardedToTelemetryRuntime() {
        let controller = RecordingRemoteTelemetryConsentController()
        let model = AppModel(
            service: UnavailableAppService(),
            remoteTelemetryConsentController: controller
        )

        model.setRemoteTelemetryForeground(false)
        model.setRemoteTelemetryForeground(true)

        XCTAssertEqual(controller.foregroundValues, [false, true])
    }
}

@MainActor
private final class RecordingRemoteTelemetryConsentController:
    RemoteTelemetryConsentApplying
{
    private let defaultsSuiteName: String?
    private(set) var values: [Bool] = []
    private(set) var persistedValues: [Bool] = []
    private(set) var foregroundValues: [Bool] = []
    private(set) var storageGenerations: [UUID?] = []

    init(defaultsSuiteName: String? = nil) {
        self.defaultsSuiteName = defaultsSuiteName
    }

    func applyRemoteTelemetryConsent(
        _ enabled: Bool,
        storageGeneration: UUID?
    ) {
        values.append(enabled)
        storageGenerations.append(storageGeneration)
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

    func setRemoteTelemetryForeground(_ foreground: Bool) {
        foregroundValues.append(foreground)
    }
}

@MainActor
private struct UnavailableRemoteTelemetryConsentController:
    RemoteTelemetryConsentApplying
{
    func applyRemoteTelemetryConsent(
        _ enabled: Bool,
        storageGeneration: UUID?
    ) {
        // A telemetry runtime owns and contains its own failures.
    }
}
