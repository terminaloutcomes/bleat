#if BLEAT_RELEASE_SECRET_SCAN && os(iOS)
    import BleatCore
    import Foundation
    import Security
    import XCTest

    final class ReleaseSecretLeakageTests: XCTestCase {
        private static let sessionService =
            "com.terminaloutcomes.Bleat.session-tokens"
        private static let nativeLoginService =
            "com.terminaloutcomes.Bleat.native-login"

        func testCaptureInitialTokensAndForceRefresh() async throws {
            let item = try XCTUnwrap(try sessionCredentialItems().only)
            let account = try XCTUnwrap(item[kSecAttrAccount as String] as? String)
            let data = try XCTUnwrap(item[kSecValueData as String] as? Data)
            let tokens = try JSONDecoder().decode(
                AuthenticationTokens.self,
                from: data
            )
            let rejectedAccessToken =
                "release-scan-rejected-\(UUID().uuidString.lowercased())"
            let replacement = try AuthenticationTokens(
                accessToken: rejectedAccessToken,
                refreshToken: tokens.refreshToken
            )
            try await TokenVault(
                tokenService: Self.sessionService,
                nativeLoginService: Self.nativeLoginService,
                legacyService: "com.terminaloutcomes.Bleat.credentials",
                synchronizesNativeLogin: false
            ).save(replacement, for: AccountID(rawValue: account))
            try writeManifest(
                [
                    Secret(label: "initial-access-token", value: tokens.accessToken),
                    Secret(label: "initial-refresh-token", value: tokens.refreshToken),
                    Secret(label: "rejected-access-token", value: rejectedAccessToken),
                ],
                named: "initial.json"
            )
        }

        func testCaptureRotatedTokens() throws {
            let initial = try readManifest(named: "initial.json")
            let item = try XCTUnwrap(try sessionCredentialItems().only)
            let data = try XCTUnwrap(item[kSecValueData as String] as? Data)
            let tokens = try JSONDecoder().decode(
                AuthenticationTokens.self,
                from: data
            )
            XCTAssertNotEqual(
                tokens.accessToken,
                try XCTUnwrap(initial.value(for: "initial-access-token"))
            )
            XCTAssertNotEqual(
                tokens.refreshToken,
                try XCTUnwrap(initial.value(for: "initial-refresh-token"))
            )
            try writeManifest(
                [
                    Secret(label: "rotated-access-token", value: tokens.accessToken),
                    Secret(label: "rotated-refresh-token", value: tokens.refreshToken),
                ],
                named: "rotated.json"
            )
        }

        func testRemovePrivateCapture() throws {
            let directory = try captureDirectory()
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: directory.path)
            )
        }

        func testLogoutRemovedSessionCredentials() throws {
            XCTAssertTrue(try credentialItems(service: Self.sessionService).isEmpty)
        }

        func testPrivateCaptureRemainsRemovedAfterLogout() throws {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: try captureDirectory().path
                )
            )
        }

        private func sessionCredentialItems() throws -> [[String: Any]] {
            try credentialItems(service: Self.sessionService)
        }

        private func credentialItems(
            service: String
        ) throws -> [[String: Any]] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound {
                return []
            }
            guard status == errSecSuccess else {
                throw TokenVaultError.unexpectedStatus(status)
            }
            return result as? [[String: Any]] ?? []
        }

        private func captureDirectory() throws -> URL {
            let support = try XCTUnwrap(
                FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first
            )
            return support.appendingPathComponent(
                "Bleat/ReleaseSecretScan",
                isDirectory: true
            )
        }

        private func writeManifest(
            _ secrets: [Secret],
            named name: String
        ) throws {
            let directory = try captureDirectory()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(Manifest(secrets: secrets)).write(
                to: directory.appendingPathComponent(name),
                options: .atomic
            )
        }

        private func readManifest(named name: String) throws -> Manifest {
            try JSONDecoder().decode(
                Manifest.self,
                from: Data(
                    contentsOf: try captureDirectory()
                        .appendingPathComponent(name)
                )
            )
        }
    }

    private struct Manifest: Codable {
        let secrets: [Secret]

        func value(for label: String) -> String? {
            secrets.first(where: { $0.label == label })?.value
        }
    }

    private struct Secret: Codable {
        let label: String
        let value: String
    }

    private extension Array {
        var only: Element? {
            count == 1 ? self[0] : nil
        }
    }
#endif
