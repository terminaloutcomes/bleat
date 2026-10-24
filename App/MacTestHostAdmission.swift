#if BLEAT_MACOS_TESTING
    import Foundation

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
