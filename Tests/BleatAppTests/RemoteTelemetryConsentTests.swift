import BleatCore
import Foundation
import XCTest

@testable import Bleat

@MainActor
final class RemoteTelemetryConsentTests: XCTestCase {
    #if os(macOS)
        func testNativeMacOSDoesNotCreateTelemetryTokenProvider() {
            XCTAssertNil(RemoteTelemetryController().tokenProvider)
        }
    #endif

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

    func testAppModelRefreshesTelemetryTokenAvailability() async {
        let controller = RecordingRemoteTelemetryConsentController()
        let model = AppModel(
            service: UnavailableAppService(),
            remoteTelemetryConsentController: controller
        )
        controller.tokenAvailability = .available

        model.setRemoteTelemetryEnabled(true)
        await model.refreshRemoteTelemetryTokenAvailability()

        XCTAssertEqual(model.remoteTelemetryTokenAvailability, .available)
        XCTAssertEqual(controller.tokenAvailabilityRequests, 1)

        model.setRemoteTelemetryEnabled(false)

        XCTAssertEqual(
            model.remoteTelemetryTokenAvailability,
            .disabled
        )
    }

    func testTelemetryTokenAvailabilityLabelsRemainDistinct() {
        let values: [(TelemetryTokenAvailability, String)] = [
            (.available, "Available"),
            (.acquiring, "Acquiring"),
            (.missing, "Missing"),
            (.expiring, "Expiring"),
            (.expired, "Expired"),
            (.disabled, "Disabled"),
            (
                .failed(.authenticationConfigurationInvalid),
                "Failed — Authentication configuration invalid"
            ),
            (
                .failed(.resourceInvalid(.invalidApplicationVersion)),
                "Failed — Application version invalid"
            ),
            (
                .failed(.resourceInvalid(.invalidApplicationBuild)),
                "Failed — Application build invalid"
            ),
            (
                .failed(.resourceInvalid(.invalidOperatingSystemVersion)),
                "Failed — Operating system version invalid"
            ),
            (
                .failed(.exportConfigurationInvalid),
                "Failed — Export configuration invalid"
            ),
            (
                .failed(.attesterUnavailable),
                "Failed — App Attest unavailable"
            ),
            (
                .failed(.authenticationResponseInvalid),
                "Failed — Authentication response invalid"
            ),
            (
                .failed(.authenticationRejected),
                "Failed — Authentication rejected"
            ),
            (
                .failed(.rateLimited),
                "Failed — Rate limited"
            ),
            (
                .failed(.temporarilyUnavailable),
                "Failed — Temporarily unavailable"
            ),
            (
                .failed(.retryBackoff),
                "Failed — Waiting to retry"
            ),
            (
                .failed(.inactiveController),
                "Failed — Telemetry controller inactive"
            ),
            (
                .failed(.unsupportedPlatform),
                "Failed — Unsupported platform"
            ),
        ]

        for (availability, label) in values {
            XCTAssertEqual(availability.diagnosticsLabel, label)
        }
    }

    func testAppModelMonitorsTokenAcquiredAfterDiagnosticsAppears() async {
        let controller = RecordingRemoteTelemetryConsentController()
        let model = AppModel(
            service: UnavailableAppService(),
            remoteTelemetryConsentController: controller
        )
        model.setRemoteTelemetryEnabled(true)

        let monitor = Task { @MainActor in
            await model.monitorRemoteTelemetryTokenAvailability(
                interval: .milliseconds(1)
            )
        }
        while controller.tokenAvailabilityRequests == 0 {
            await Task.yield()
        }
        XCTAssertEqual(
            model.remoteTelemetryTokenAvailability,
            .missing
        )

        controller.tokenAvailability = .available
        while model.remoteTelemetryTokenAvailability != .available {
            await Task.yield()
        }
        monitor.cancel()
        await monitor.value

        XCTAssertGreaterThanOrEqual(controller.tokenAvailabilityRequests, 2)
        XCTAssertEqual(model.remoteTelemetryTokenAvailability, .available)
    }

    func testTelemetryTokenAvailabilityDiscardsResultAfterWithdrawal()
        async
    {
        let controller = DeferredTelemetryAvailabilityController()
        let model = AppModel(
            service: UnavailableAppService(),
            remoteTelemetryConsentController: controller
        )
        model.setRemoteTelemetryEnabled(true)

        let refresh = Task { @MainActor in
            await model.refreshRemoteTelemetryTokenAvailability()
        }
        while !controller.isAvailabilityRequestPending {
            await Task.yield()
        }

        model.setRemoteTelemetryEnabled(false)
        controller.completeAvailabilityRequest(with: .available)
        await refresh.value

        XCTAssertEqual(
            model.remoteTelemetryTokenAvailability,
            .disabled
        )
    }

    #if DEBUG && os(iOS)
        func testRealRuntimeDefaultsOffAndWithdrawalPurgesItsGeneration()
            async throws
        {
            let storageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "RemoteTelemetryConsentTests-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: storageRoot) }
            let controller = RemoteTelemetryController(
                resource: try RemoteTelemetryResource(
                    applicationVersion: "1.2.3",
                    applicationBuild: "68",
                    platform: .iOS,
                    operatingSystemMajorVersion: 26,
                    operatingSystemMinorVersion: 0,
                    operatingSystemPatchVersion: 0,
                    installationID: UUID()
                ),
                storageRootURL: storageRoot
            )

            controller.tracer.beginSpan(operation: .appLaunch).end(.succeeded)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(hasPersistedBatch(in: storageRoot))

            let firstGeneration = UUID()
            controller.setRemoteTelemetryForeground(true)
            controller.applyRemoteTelemetryConsent(
                true,
                storageGeneration: firstGeneration
            )
            try await Task.sleep(for: .milliseconds(100))
            let withdrawnSpan = controller.tracer.beginSpan(
                operation: .libraryRefresh
            )
            controller.tracer.beginSpan(
                operation: .appLaunch,
                source: .offline,
                retryBucket: .one
            ).end(.succeeded)
            controller.setRemoteTelemetryForeground(false)
            try await waitForPersistedBatch(in: storageRoot)

            controller.applyRemoteTelemetryConsent(
                false,
                storageGeneration: firstGeneration
            )
            try await waitForNoPersistedBatch(in: storageRoot)
            withdrawnSpan.end(.succeeded)

            let currentGeneration = UUID()
            controller.setRemoteTelemetryForeground(true)
            controller.applyRemoteTelemetryConsent(
                true,
                storageGeneration: currentGeneration
            )
            try await Task.sleep(for: .milliseconds(100))
            controller.tracer.beginSpan(operation: .playbackStart)
                .end(.succeeded)
            controller.setRemoteTelemetryForeground(false)
            try await waitForPersistedBatch(in: storageRoot)

            let generationDirectories = try FileManager.default
                .contentsOfDirectory(
                    at: storageRoot,
                    includingPropertiesForKeys: nil
                )
                .map(\.lastPathComponent)
                .filter { $0.hasPrefix("generation-") }
            XCTAssertEqual(
                generationDirectories,
                ["generation-\(currentGeneration.uuidString.lowercased())"]
            )

            controller.applyRemoteTelemetryConsent(
                false,
                storageGeneration: currentGeneration
            )
            try await waitForNoPersistedBatch(in: storageRoot)
        }

        private func waitForPersistedBatch(in root: URL) async throws {
            for _ in 0..<100 {
                if hasPersistedBatch(in: root) { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("telemetry runtime did not persist a batch")
        }

        private func waitForNoPersistedBatch(in root: URL) async throws {
            for _ in 0..<100 {
                if !hasPersistedBatch(in: root) { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("telemetry runtime did not purge its batch")
        }

        private func hasPersistedBatch(in root: URL) -> Bool {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey]
                )
            else {
                return false
            }
            return enumerator.compactMap { $0 as? URL }.contains {
                $0.pathExtension == "json"
            }
        }
    #endif
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
    var tokenAvailability: TelemetryTokenAvailability = .missing
    private(set) var tokenAvailabilityRequests = 0

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

    func telemetryTokenAvailability() async -> TelemetryTokenAvailability {
        tokenAvailabilityRequests += 1
        return tokenAvailability
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

@MainActor
private final class DeferredTelemetryAvailabilityController:
    RemoteTelemetryConsentApplying
{
    private var availabilityContinuation:
        CheckedContinuation<TelemetryTokenAvailability, Never>?

    var isAvailabilityRequestPending: Bool {
        availabilityContinuation != nil
    }

    func applyRemoteTelemetryConsent(
        _ enabled: Bool,
        storageGeneration: UUID?
    ) {}

    func telemetryTokenAvailability() async -> TelemetryTokenAvailability {
        await withCheckedContinuation { continuation in
            availabilityContinuation = continuation
        }
    }

    func completeAvailabilityRequest(
        with availability: TelemetryTokenAvailability
    ) {
        let continuation = availabilityContinuation
        availabilityContinuation = nil
        continuation?.resume(returning: availability)
    }
}
