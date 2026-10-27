import BleatCore
import Foundation
import MediaPlayer

enum AppUnitTestHostAdmission {
    @MainActor private(set) static var didAdmitProcess = false

    static func isInert(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["BLEAT_UNIT_TEST_HOST"] == "1"
    }

    @MainActor
    static func admitProcess() -> AppModel {
        let model = makeModel()
        didAdmitProcess = true
        return model
    }

    @MainActor
    static func makeModel() -> AppModel {
        AppModel(
            service: UnavailableAppService(),
            nearbyServerDiscovery: UnavailableNearbyServerDiscovery(),
            bootstrapError: .persistenceUnavailable,
            diagnostics: UnitTestHostDiagnostics(),
            nowPlayingCoordinator: NowPlayingCoordinator(
                infoCenter: UnitTestHostNowPlayingInfo(),
                registersRemoteCommands: false))
    }
}

private struct UnitTestHostDiagnostics: DiagnosticRecording {
    func record(_ event: DiagnosticEvent) async {}
}

@MainActor
private final class UnitTestHostNowPlayingInfo: NowPlayingInfoPublishing {
    var nowPlayingInfo: [String: Any]?
    var playbackState: MPNowPlayingPlaybackState = .stopped
}

#if BLEAT_MACOS_TESTING

    enum MacTestHostAdmission {
        static let bundleID = "com.terminaloutcomes.Bleat.MacTestHost"
        enum Rejection: String {
            case unexpectedIdentity
            case missingRunnerAdmission
        }

        static func rejection(
            bundleID: String? = Bundle.main.bundleIdentifier,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Rejection? {
            guard bundleID == Self.bundleID else { return .unexpectedIdentity }
            guard environment["BLEAT_MACOS_TEST_HOST"] == "1" else {
                return .missingRunnerAdmission
            }
            return nil
        }
    }
#endif
