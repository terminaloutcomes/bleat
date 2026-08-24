import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public final class URLSessionTelemetryAuthenticationTransport:
    TelemetryAuthenticationTransport, @unchecked Sendable
{
    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let installationID: UUID?

    public init(
        baseURL: URL,
        allowsInsecureLoopback: Bool = false,
        installationID: UUID? = nil,
        configuration: URLSessionConfiguration = .ephemeral
    ) throws(TelemetryAuthenticationTransportError) {
        guard Self.isValid(
            baseURL: baseURL,
            allowsInsecureLoopback: allowsInsecureLoopback
        ) else {
            throw .invalidConfiguration
        }
        self.baseURL = baseURL.appending(path: "")
        self.installationID = installationID
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    public func attestationChallenge() async throws(
        TelemetryAuthenticationTransportError
    ) -> TelemetryChallenge {
        let response: ChallengeDTO = try await post(
            path: "v1/attestation/challenge",
            body: EmptyRequest(),
            expectedStatus: 201
        )
        return try response.domainValue()
    }

    public func enroll(
        challenge: TelemetryChallenge,
        keyID: String,
        attestationObject: Data
    ) async throws(TelemetryAuthenticationTransportError) -> UUID {
        let response: EnrollmentResponseDTO = try await post(
            path: "v1/attestation/enroll",
            body: EnrollmentRequestDTO(
                challengeID: challenge.id,
                challenge: challenge.value,
                keyID: keyID,
                attestationObject: attestationObject.base64URLEncodedString()
            ),
            expectedStatus: 201
        )
        return response.installationID
    }

    public func tokenChallenge(
        installationID: UUID
    ) async throws(TelemetryAuthenticationTransportError)
        -> TelemetryChallenge
    {
        let response: ChallengeDTO = try await post(
            path: "v1/token/challenge",
            body: TokenChallengeRequestDTO(installationID: installationID),
            expectedStatus: 201
        )
        return try response.domainValue()
    }

    public func token(
        installationID: UUID,
        challenge: TelemetryChallenge,
        assertionObject: Data
    ) async throws(TelemetryAuthenticationTransportError)
        -> TelemetryBearerToken
    {
        let response: TokenResponseDTO = try await post(
            path: "v1/token",
            body: TokenRequestDTO(
                installationID: installationID,
                challengeID: challenge.id,
                challenge: challenge.value,
                assertionObject: assertionObject.base64URLEncodedString()
            ),
            expectedStatus: 200
        )
        guard response.tokenType == "Bearer",
            !response.accessToken.isEmpty,
            let expiresAt = Self.date(from: response.expiresAt)
        else {
            throw .malformedResponse
        }
        return TelemetryBearerToken(
            value: response.accessToken,
            expiresAt: expiresAt
        )
    }

    private func post<RequestBody: Encodable, ResponseBody: Decodable>(
        path: String,
        body: RequestBody,
        expectedStatus: Int
    ) async throws(TelemetryAuthenticationTransportError) -> ResponseBody {
        let url = baseURL.appending(path: path)
        guard url.scheme == baseURL.scheme, url.host == baseURL.host else {
            throw .invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if let installationID {
            request.setValue(
                "service.instance.id=\(installationID.uuidString.lowercased())",
                forHTTPHeaderField: "baggage"
            )
        }
        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw .malformedResponse
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .temporarilyUnavailable
        }
        guard let response = response as? HTTPURLResponse else {
            throw .malformedResponse
        }
        guard data.count <= 65_536 else {
            throw .malformedResponse
        }
        guard response.statusCode == expectedStatus else {
            throw Self.error(status: response.statusCode, data: data)
        }
        do {
            return try decoder.decode(ResponseBody.self, from: data)
        } catch {
            throw .malformedResponse
        }
    }

    private static func error(
        status: Int,
        data: Data
    ) -> TelemetryAuthenticationTransportError {
        let code = (try? JSONDecoder().decode(ErrorResponseDTO.self, from: data))?
            .error.code
        switch (status, code) {
        case (401, _), (_, "authentication_rejected"):
            return .authenticationRejected
        case (429, _), (_, "rate_limited"):
            return .rateLimited
        case (408, _), (500...599, _), (_, "temporarily_unavailable"):
            return .temporarilyUnavailable
        default:
            return .malformedResponse
        }
    }

    private static func isValid(
        baseURL: URL,
        allowsInsecureLoopback: Bool
    ) -> Bool {
        guard baseURL.user == nil, baseURL.password == nil,
            baseURL.query == nil, baseURL.fragment == nil,
            let host = baseURL.host?.lowercased()
        else { return false }
        if baseURL.scheme == "https" { return true }
        guard allowsInsecureLoopback, baseURL.scheme == "http" else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    fileprivate static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

private struct EmptyRequest: Encodable {}

private struct ChallengeDTO: Decodable {
    let challengeID: UUID
    let challenge: String
    let expiresAt: String

    private enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case challenge
        case expiresAt = "expires_at"
    }

    func domainValue() throws(TelemetryAuthenticationTransportError)
        -> TelemetryChallenge
    {
        guard challenge.utf8.count <= 128,
            let expiresAt = URLSessionTelemetryAuthenticationTransport.date(
                from: expiresAt
            )
        else {
            throw .malformedResponse
        }
        return TelemetryChallenge(
            id: challengeID,
            value: challenge,
            expiresAt: expiresAt
        )
    }
}

private struct EnrollmentRequestDTO: Encodable {
    let challengeID: UUID
    let challenge: String
    let keyID: String
    let attestationObject: String

    private enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case challenge
        case keyID = "key_id"
        case attestationObject = "attestation_object"
    }
}

private struct EnrollmentResponseDTO: Decodable {
    let installationID: UUID

    private enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
    }
}

private struct TokenChallengeRequestDTO: Encodable {
    let installationID: UUID

    private enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
    }
}

private struct TokenRequestDTO: Encodable {
    let installationID: UUID
    let challengeID: UUID
    let challenge: String
    let assertionObject: String

    private enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
        case challengeID = "challenge_id"
        case challenge
        case assertionObject = "assertion_object"
    }
}

private struct TokenResponseDTO: Decodable {
    let accessToken: String
    let tokenType: String
    let expiresAt: String

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresAt = "expires_at"
    }
}

private struct ErrorResponseDTO: Decodable {
    struct Detail: Decodable {
        let code: String
    }

    let error: Detail
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
