#if DEBUG
    import CryptoKit
    import Foundation

    /// Deterministic public test evidence for the development backend only.
    public final class DevelopmentTelemetryAttester:
        TelemetryAttester, @unchecked Sendable
    {
        private let key: P256.Signing.PrivateKey?

        public convenience init() {
            self.init(keySeed: 7)
        }

        init(keySeed: UInt8) {
            key = try? P256.Signing.PrivateKey(
                rawRepresentation: Data(repeating: keySeed, count: 32)
            )
        }

        public var isSupported: Bool { key != nil }

        public func generateKey()
            async throws(TelemetryAttesterError) -> String
        {
            guard let key else { throw .unsupported }
            return Data(
                SHA256.hash(data: key.publicKey.x963Representation)
            ).base64URLEncodedString()
        }

        public func attest(
            keyID: String,
            clientDataHash: Data
        ) async throws(TelemetryAttesterError) -> Data {
            guard let key else { throw .unsupported }
            let expectedKeyID = Data(
                SHA256.hash(data: key.publicKey.x963Representation)
            ).base64URLEncodedString()
            guard keyID == expectedKeyID else { throw .keyInvalidated }
            let signature = try signature(
                key: key,
                clientDataHash: clientDataHash
            )
            return try encode(
                DevelopmentAttestationEvidence(
                    publicKey: key.publicKey.x963Representation
                        .base64URLEncodedString(),
                    signature: signature
                )
            )
        }

        public func assertion(
            keyID: String,
            clientDataHash: Data
        ) async throws(TelemetryAttesterError) -> Data {
            guard let key else { throw .unsupported }
            let expectedKeyID = Data(
                SHA256.hash(data: key.publicKey.x963Representation)
            ).base64URLEncodedString()
            guard keyID == expectedKeyID else { throw .keyInvalidated }
            return try encode(
                DevelopmentAssertionEvidence(
                    signature: try signature(
                        key: key,
                        clientDataHash: clientDataHash
                    )
                )
            )
        }

        private func signature(
            key: P256.Signing.PrivateKey,
            clientDataHash: Data
        ) throws(TelemetryAttesterError) -> String {
            do {
                return try key.signature(for: clientDataHash)
                    .derRepresentation.base64URLEncodedString()
            } catch {
                throw .temporarilyUnavailable
            }
        }

        private func encode<Value: Encodable>(
            _ value: Value
        ) throws(TelemetryAttesterError) -> Data {
            do {
                return try JSONEncoder().encode(value)
            } catch {
                throw .temporarilyUnavailable
            }
        }
    }

    private struct DevelopmentAttestationEvidence: Encodable {
        let publicKey: String
        let signature: String

        private enum CodingKeys: String, CodingKey {
            case publicKey = "public_key"
            case signature
        }
    }

    private struct DevelopmentAssertionEvidence: Encodable {
        let signature: String
    }
#endif
