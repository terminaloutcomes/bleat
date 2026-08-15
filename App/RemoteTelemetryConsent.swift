import Foundation

@MainActor
final class RemoteTelemetryConsentStore {
    nonisolated static let enabledKey =
        "bleat.remoteTelemetry.enabled.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        defaults.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
    }
}

/// The single application boundary later telemetry exporters and token
/// providers must implement. The synchronous call lets implementations treat
/// `false` as an immediate stop signal: cancel export and token renewal before
/// returning, then own any asynchronous credential clearing and buffer purge.
/// Failures remain internal to the telemetry subsystem and must not fail the
/// user's action.
@MainActor
protocol RemoteTelemetryConsentApplying: Sendable {
    func applyRemoteTelemetryConsent(_ enabled: Bool)
}

struct InactiveRemoteTelemetryConsentController:
    RemoteTelemetryConsentApplying
{
    func applyRemoteTelemetryConsent(_ enabled: Bool) {}
}
