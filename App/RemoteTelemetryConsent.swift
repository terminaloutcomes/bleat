import BleatCore
import Foundation

#if os(iOS)
    import UIKit
#endif

@MainActor
final class RemoteTelemetryConsentStore {
    nonisolated static let enabledKey =
        "bleat.remoteTelemetry.enabled.v1"
    nonisolated static let generationKey =
        "bleat.remoteTelemetry.storageGeneration.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        defaults.bool(forKey: Self.enabledKey)
    }

    var storageGeneration: UUID? {
        guard isEnabled,
            let value = defaults.string(forKey: Self.generationKey)
        else { return nil }
        return UUID(uuidString: value)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> UUID? {
        let priorGeneration = storageGeneration
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            let generation = priorGeneration ?? UUID()
            defaults.set(
                generation.uuidString.lowercased(),
                forKey: Self.generationKey
            )
            return generation
        }
        defaults.removeObject(forKey: Self.generationKey)
        return priorGeneration
    }

    func ensureEnabledStorageGeneration() -> UUID? {
        guard isEnabled else { return nil }
        if let storageGeneration { return storageGeneration }
        return setEnabled(true)
    }

    #if BLEAT_RELEASE_SECRET_SCAN
        static func applyReleaseSecretScanLaunchOverride(
            processInfo: ProcessInfo = .processInfo
        ) {
            guard
                processInfo.arguments.contains(
                    "--release-secret-scan-enable-telemetry"
                )
            else { return }
            _ = RemoteTelemetryConsentStore().setEnabled(true)
        }
    #endif
}

/// The single application boundary for the private telemetry runtime. The
/// synchronous call lets implementations treat
/// `false` as an immediate stop signal: cancel export and token renewal before
/// returning, then own any asynchronous credential clearing and buffer purge.
/// Failures remain internal to the telemetry subsystem and must not fail the
/// user's action.
@MainActor
protocol RemoteTelemetryConsentApplying: Sendable {
    func applyRemoteTelemetryConsent(
        _ enabled: Bool,
        storageGeneration: UUID?
    )
    func setRemoteTelemetryForeground(_ foreground: Bool)
    func telemetryTokenAvailability() async -> TelemetryTokenAvailability
}

extension RemoteTelemetryConsentApplying {
    func setRemoteTelemetryForeground(_ foreground: Bool) {}

    func telemetryTokenAvailability() async -> TelemetryTokenAvailability {
        .failed(.inactiveController)
    }
}

struct InactiveRemoteTelemetryConsentController:
    RemoteTelemetryConsentApplying
{
    func applyRemoteTelemetryConsent(
        _ enabled: Bool,
        storageGeneration: UUID?
    ) {}
}

enum RemoteTelemetryAttesterSelection: Equatable {
    case unavailable
    case development
    case appAttest

    static func resolve(
        appAttestMode: String?,
        requestedMode: String?
    ) -> Self {
        #if DEBUG || BLEAT_RELEASE_SECRET_SCAN
            if requestedMode == "fake" {
                return .development
            }
        #endif
        guard appAttestMode == "enabled" else {
            return .unavailable
        }
        return .appAttest
    }
}

@MainActor
final class RemoteTelemetryController: RemoteTelemetryConsentApplying {
    private enum TokenProviderConstruction {
        case ready(TelemetryTokenProvider)
        case failed(TelemetryTokenAvailabilityFailure)
    }

    let tracer = RemoteTelemetryTracer()
    let logger = RemoteTelemetryLogger()
    let privateCloudEvents: any PrivateCloudSyncEventRecording
    let tokenProvider: TelemetryTokenProvider?
    private let tokenAvailabilityFailure: TelemetryTokenAvailabilityFailure?
    private let worker: RemoteTelemetryRuntimeWorker?
    private var telemetryEnabled = false

    init(bundle: Bundle = .main, processInfo: ProcessInfo = .processInfo) {
        privateCloudEvents = RemoteTelemetryPrivateCloudSyncEventRecorder(
            tracer: tracer,
            logger: logger
        )
        #if os(macOS)
            // Remote telemetry export is not in scope for the native macOS app.
            // Do not create App Attest state, tokens, persisted batches, or OTLP
            // traffic on that platform.
            tokenProvider = nil
            tokenAvailabilityFailure = .unsupportedPlatform
            worker = nil
        #else
            let version =
                bundle.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "0"
            let build =
                bundle.object(forInfoDictionaryKey: "CFBundleVersion")
                as? String ?? "0"
            let systemVersion = processInfo.operatingSystemVersion
            let platform: RemoteTelemetryPlatform =
                UIDevice.current.userInterfaceIdiom == .pad
                ? .iPadOS : .iOS
            let resource = try? RemoteTelemetryResource(
                applicationVersion: version,
                applicationBuild: build,
                platform: platform,
                operatingSystemMajorVersion: systemVersion.majorVersion,
                operatingSystemMinorVersion: systemVersion.minorVersion,
                operatingSystemPatchVersion: systemVersion.patchVersion,
                installationID: InstallationIdentifierStore().uuid
            )
            let storageRootURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?.appendingPathComponent(
                "Bleat/RemoteTelemetry",
                isDirectory: true
            )
            let tokenProviderConstruction = Self.makeTokenProvider(
                bundle: bundle,
                tracer: tracer
            )
            let providerFailure: TelemetryTokenAvailabilityFailure?
            switch tokenProviderConstruction {
            case .ready(let tokenProvider):
                self.tokenProvider = tokenProvider
                providerFailure = nil
            case .failed(let failure):
                self.tokenProvider = nil
                providerFailure = failure
            }
            let exporterConfiguration = Self.makeExporterConfiguration(
                bundle: bundle
            )
            tokenAvailabilityFailure =
                providerFailure
                ?? (exporterConfiguration == nil
                    ? .exportConfigurationInvalid : nil)
            let downstreamExportersFactory:
                (@Sendable () -> AuthenticatedOtlpExporters?)? =
                    if let tokenProvider, let exporterConfiguration {
                        {
                            AuthenticatedOtlpExporters(
                                configuration: exporterConfiguration,
                                tokenProvider: tokenProvider
                            )
                        }
                    } else {
                        nil
                    }
            worker = RemoteTelemetryRuntimeWorker(
                tracer: tracer,
                logger: logger,
                resource: resource,
                storageRootURL: storageRootURL,
                downstreamExportersFactory: downstreamExportersFactory
            )
        #endif
    }

    #if DEBUG && os(iOS)
        /// Internal composition seam for app-hosted lifecycle tests. Production
        /// construction continues through the bundle-backed initializer above.
        init(
            resource: RemoteTelemetryResource?,
            storageRootURL: URL?
        ) {
            privateCloudEvents = RemoteTelemetryPrivateCloudSyncEventRecorder(
                tracer: tracer,
                logger: logger
            )
            tokenProvider = nil
            tokenAvailabilityFailure = .inactiveController
            worker = RemoteTelemetryRuntimeWorker(
                tracer: tracer,
                logger: logger,
                resource: resource,
                storageRootURL: storageRootURL
            )
        }
    #endif

    func applyRemoteTelemetryConsent(
        _ enabled: Bool,
        storageGeneration: UUID?
    ) {
        telemetryEnabled = enabled
        guard let worker else { return }
        if let tokenProvider {
            Task {
                await tokenProvider.setEnabled(enabled)
            }
        }
        if enabled {
            guard let storageGeneration else {
                worker.disable(storageGeneration: nil)
                return
            }
            worker.enable(storageGeneration: storageGeneration)
        } else {
            worker.disable(storageGeneration: storageGeneration)
        }
    }

    func setRemoteTelemetryForeground(_ foreground: Bool) {
        worker?.setForeground(foreground)
    }

    func telemetryTokenAvailability() async -> TelemetryTokenAvailability {
        guard telemetryEnabled else { return .disabled }
        if let tokenAvailabilityFailure {
            return .failed(tokenAvailabilityFailure)
        }
        guard let tokenProvider else {
            return .failed(.inactiveController)
        }
        return await tokenProvider.cachedTokenAvailability()
    }

    private static func makeTokenProvider(
        bundle: Bundle,
        tracer: any RemoteTelemetryTracing
    ) -> TokenProviderConstruction {
        guard
            let value = bundle.object(
                forInfoDictionaryKey: "BleatTelemetryAuthenticationBaseURL"
            ) as? String,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let baseURL = URL(string: value)
        else {
            return .failed(.authenticationConfigurationInvalid)
        }

        #if DEBUG || BLEAT_RELEASE_SECRET_SCAN
            let allowsInsecureLoopback = true
        #else
            let allowsInsecureLoopback = false
        #endif
        guard
            let transport = try? URLSessionTelemetryAuthenticationTransport(
                baseURL: baseURL,
                allowsInsecureLoopback: allowsInsecureLoopback,
                installationID: InstallationIdentifierStore().uuid
            )
        else {
            return .failed(.authenticationConfigurationInvalid)
        }

        let selection = RemoteTelemetryAttesterSelection.resolve(
            appAttestMode: bundle.object(
                forInfoDictionaryKey: "BleatAppAttestMode"
            ) as? String,
            requestedMode: bundle.object(
                forInfoDictionaryKey: "BleatTelemetryAttesterMode"
            ) as? String
        )
        let attester: any TelemetryAttester
        switch selection {
        case .unavailable:
            return .failed(.attesterUnavailable)
        case .development:
            #if DEBUG || BLEAT_RELEASE_SECRET_SCAN
                attester = DevelopmentTelemetryAttester()
            #else
                return .failed(.attesterUnavailable)
            #endif
        case .appAttest:
            attester = AppAttestTelemetryAttester()
        }

        let bundleID = bundle.bundleIdentifier ?? "com.terminaloutcomes.Bleat"
        return .ready(
            TelemetryTokenProvider(
                attester: attester,
                transport: transport,
                store: TelemetryEnrollmentVault(
                    service: "\(bundleID).telemetry-app-attest"
                ),
                tracer: tracer
            )
        )
    }

    private static func makeExporterConfiguration(
        bundle: Bundle
    ) -> AuthenticatedOtlpSpanExporterConfiguration? {
        guard
            let value = bundle.object(
                forInfoDictionaryKey: "BleatTelemetryOTLPEndpoint"
            ) as? String,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let endpoint = URL(string: value)
        else {
            return nil
        }
        return try? AuthenticatedOtlpSpanExporterConfiguration(
            endpoint: endpoint
        )
    }
}

private final class RemoteTelemetryRuntimeWorker: @unchecked Sendable {
    private enum State: Equatable {
        case disabled
        case initializing(UInt64)
        case active(UInt64)
        case failed(UInt64, RemoteTelemetryRuntimeFailure)
        case shuttingDown(UInt64)
    }

    private let tracer: RemoteTelemetryTracer
    private let logger: RemoteTelemetryLogger
    private let resource: RemoteTelemetryResource?
    private let storageRootURL: URL?
    private let downstreamExportersFactory:
        (@Sendable () -> AuthenticatedOtlpExporters?)?
    private let queue = DispatchQueue(
        label: "app.bleat.remote-telemetry.runtime",
        qos: .utility
    )
    private let lock = NSLock()
    private var pipeline: RemoteTelemetryPipeline?
    private var generation: UInt64 = 0
    private var wantsEnabled = false
    private var isForeground = false
    private var state = State.disabled

    init(
        tracer: RemoteTelemetryTracer,
        logger: RemoteTelemetryLogger,
        resource: RemoteTelemetryResource?,
        storageRootURL: URL?,
        downstreamExportersFactory:
            (@Sendable () -> AuthenticatedOtlpExporters?)? = nil
    ) {
        self.tracer = tracer
        self.logger = logger
        self.resource = resource
        self.storageRootURL = storageRootURL
        self.downstreamExportersFactory = downstreamExportersFactory
    }

    func enable(storageGeneration: UUID) {
        let requestedGeneration = lock.withLock {
            wantsEnabled = true
            generation &+= 1
            state = .initializing(generation)
            return generation
        }
        tracer.prepareForActivation()
        logger.prepareForActivation()
        queue.async { [weak self] in
            self?.buildPipeline(
                for: requestedGeneration,
                storageGeneration: storageGeneration
            )
        }
    }

    func disable(storageGeneration: UUID?) {
        let oldPipeline = lock.withLock {
            wantsEnabled = false
            generation &+= 1
            state = .shuttingDown(generation)
            let oldPipeline = pipeline
            pipeline = nil
            return oldPipeline
        }
        tracer.deactivate()
        logger.deactivate()
        oldPipeline?.deactivate()
        let disabledGeneration = lock.withLock { generation }
        queue.async { [weak self] in
            oldPipeline?.purge()
            self?.purgeStorageGenerations(
                retaining: nil,
                explicitlyRemoving: storageGeneration
            )
            if let oldPipeline {
                DispatchQueue.global(qos: .utility).async {
                    oldPipeline.shutdown()
                }
            }
            self?.lock.withLock {
                guard self?.generation == disabledGeneration,
                    self?.wantsEnabled == false
                else { return }
                self?.state = .disabled
            }
        }
    }

    func setForeground(_ foreground: Bool) {
        let current = lock.withLock {
            isForeground = foreground
            return pipeline
        }
        current?.setForeground(foreground)
        guard !foreground, let current else { return }
        DispatchQueue.global(qos: .utility).async {
            current.flushForBackground(timeout: 2)
        }
    }

    private func buildPipeline(
        for requestedGeneration: UInt64,
        storageGeneration: UUID
    ) {
        guard let resource else {
            recordFailure(.invalidResource, generation: requestedGeneration)
            return
        }
        guard let storageRootURL else {
            recordFailure(.storageUnavailable, generation: requestedGeneration)
            return
        }
        let shouldBuild = lock.withLock {
            wantsEnabled && generation == requestedGeneration
                && pipeline == nil
        }
        guard shouldBuild else { return }
        purgeStorageGenerations(
            retaining: storageGeneration,
            explicitlyRemoving: nil
        )
        let storageURL = storageRootURL.appendingPathComponent(
            Self.directoryName(for: storageGeneration),
            isDirectory: true
        )
        let newPipeline: RemoteTelemetryPipeline
        let downstream = downstreamExportersFactory?()
        do {
            newPipeline = try RemoteTelemetryPipeline(
                resource: resource,
                storageURL: storageURL,
                tracerFacade: tracer,
                loggerFacade: logger,
                downstreamExporter: downstream?.spans,
                downstreamLogExporter: downstream?.logs
            )
        } catch let failure as RemoteTelemetryRuntimeFailure {
            downstream?.spans.shutdown(explicitTimeout: 0)
            downstream?.logs.shutdown(explicitTimeout: 0)
            tracer.deactivate()
            logger.deactivate()
            recordFailure(failure, generation: requestedGeneration)
            return
        } catch {
            downstream?.spans.shutdown(explicitTimeout: 0)
            downstream?.logs.shutdown(explicitTimeout: 0)
            tracer.deactivate()
            logger.deactivate()
            recordFailure(.storageUnavailable, generation: requestedGeneration)
            return
        }
        let accepted = lock.withLock {
            guard wantsEnabled, generation == requestedGeneration,
                pipeline == nil
            else {
                return false
            }
            pipeline = newPipeline
            state = .active(requestedGeneration)
            newPipeline.setForeground(isForeground)
            return true
        }
        guard !accepted else { return }
        newPipeline.deactivate()
        newPipeline.purge()
        DispatchQueue.global(qos: .utility).async {
            newPipeline.shutdown()
        }
    }

    private func purgeStorageGenerations(
        retaining retainedGeneration: UUID?,
        explicitlyRemoving removedGeneration: UUID?
    ) {
        guard let storageRootURL else { return }
        let retainedName = retainedGeneration.map {
            Self.directoryName(for: $0)
        }
        let removedName = removedGeneration.map {
            Self.directoryName(for: $0)
        }
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: storageRootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        for url in contents {
            guard url.lastPathComponent.hasPrefix("generation-") else {
                continue
            }
            if let removedName {
                guard url.lastPathComponent == removedName else { continue }
            } else if url.lastPathComponent == retainedName {
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func directoryName(for generation: UUID) -> String {
        "generation-\(generation.uuidString.lowercased())"
    }

    private func recordFailure(
        _ failure: RemoteTelemetryRuntimeFailure,
        generation requestedGeneration: UInt64
    ) {
        let accepted = lock.withLock {
            guard generation == requestedGeneration, wantsEnabled else {
                return false
            }
            state = .failed(requestedGeneration, failure)
            return true
        }
        if accepted {
            tracer.deactivate()
        }
    }
}
