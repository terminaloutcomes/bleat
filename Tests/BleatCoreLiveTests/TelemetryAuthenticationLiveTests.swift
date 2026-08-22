#if DEBUG
    import CryptoKit
    import Foundation
    import XCTest

    @testable import BleatCore

    final class TelemetryAuthenticationLiveTests: XCTestCase {
        func testSwiftDevelopmentAttesterObtainsVerifiableJWT() async throws {
            let environment = ProcessInfo.processInfo.environment
            guard let value = environment["BLEAT_TELEMETRY_AUTH_BASE_URL"],
                let baseURL = URL(string: value)
            else {
                throw XCTSkip(
                    "Run scripts/test-bleat-api.sh to provide the telemetry auth URL"
                )
            }
            let store = LiveTelemetryEnrollmentStore()
            let provider = TelemetryTokenProvider(
                attester: DevelopmentTelemetryAttester(),
                transport: try URLSessionTelemetryAuthenticationTransport(
                    baseURL: baseURL,
                    allowsInsecureLoopback: true
                ),
                store: store
            )

            await provider.setEnabled(true)
            let enrollmentBeforeToken = await store.value
            XCTAssertNil(enrollmentBeforeToken)

            let token = try await provider.currentToken()
            let storedEnrollment = await store.value
            let enrollment = try XCTUnwrap(storedEnrollment)
            try await verify(
                token: token,
                installationID: try XCTUnwrap(enrollment.installationID),
                baseURL: baseURL
            )
        }

        private func verify(
            token: String,
            installationID: UUID,
            baseURL: URL
        ) async throws {
            let components = token.split(separator: ".")
            XCTAssertEqual(components.count, 3)
            guard components.count == 3 else { return }
            let payload = try XCTUnwrap(Data(base64URL: String(components[1])))
            let claims = try XCTUnwrap(
                JSONSerialization.jsonObject(with: payload) as? [String: Any]
            )
            let discoveryURL = baseURL.appending(
                path: ".well-known/openid-configuration"
            )
            let (discoveryData, discoveryResponse) = try await URLSession.shared.data(
                from: discoveryURL
            )
            XCTAssertEqual((discoveryResponse as? HTTPURLResponse)?.statusCode, 200)
            let discovery = try XCTUnwrap(
                JSONSerialization.jsonObject(with: discoveryData) as? [String: Any]
            )
            XCTAssertEqual(claims["sub"] as? String, installationID.uuidString.lowercased())
            XCTAssertEqual(claims["iss"] as? String, discovery["issuer"] as? String)
            XCTAssertEqual(claims["aud"] as? String, "bleat-telemetry")
            XCTAssertEqual(claims["scope"] as? String, "telemetry:write")
            XCTAssertEqual(
                Set(claims.keys),
                ["iss", "sub", "aud", "scope", "iat", "exp"]
            )
            let now = Date().timeIntervalSince1970
            let issuedAt = try XCTUnwrap(claims["iat"] as? Double)
            let expiresAt = try XCTUnwrap(claims["exp"] as? Double)
            XCTAssertLessThanOrEqual(issuedAt, now + 5)
            XCTAssertGreaterThan(expiresAt, now + 500)
            XCTAssertLessThanOrEqual(expiresAt, now + 605)

            let jwksURL = baseURL.appending(path: ".well-known/jwks.json")
            let (jwksData, response) = try await URLSession.shared.data(from: jwksURL)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let jwks = try XCTUnwrap(
                JSONSerialization.jsonObject(with: jwksData) as? [String: Any]
            )
            let keys = try XCTUnwrap(jwks["keys"] as? [[String: Any]])
            let key = try XCTUnwrap(keys.first)
            XCTAssertEqual(key["alg"] as? String, "ES256")
            XCTAssertEqual(key["kty"] as? String, "EC")
            XCTAssertEqual(key["crv"] as? String, "P-256")
            let x = try XCTUnwrap(
                (key["x"] as? String).flatMap(Data.init(base64URL:))
            )
            let y = try XCTUnwrap(
                (key["y"] as? String).flatMap(Data.init(base64URL:))
            )
            var representation = Data([4])
            representation.append(x)
            representation.append(y)
            let publicKey = try P256.Signing.PublicKey(
                x963Representation: representation
            )
            let signatureData = try XCTUnwrap(
                Data(base64URL: String(components[2]))
            )
            let signature = try P256.Signing.ECDSASignature(
                rawRepresentation: signatureData
            )
            let signingInput = Data(
                "\(components[0]).\(components[1])".utf8
            )
            XCTAssertTrue(publicKey.isValidSignature(signature, for: signingInput))
        }
    }

    private actor LiveTelemetryEnrollmentStore: TelemetryEnrollmentStoring {
        private(set) var value: TelemetryEnrollment?

        func enrollment() async throws -> TelemetryEnrollment? { value }
        func save(_ enrollment: TelemetryEnrollment) async throws {
            value = enrollment
        }
        func delete() async throws { value = nil }
    }

    private extension Data {
        init?(base64URL value: String) {
            var normalized = value
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            normalized += String(
                repeating: "=",
                count: (4 - normalized.count % 4) % 4
            )
            self.init(base64Encoded: normalized)
        }
    }
#endif
