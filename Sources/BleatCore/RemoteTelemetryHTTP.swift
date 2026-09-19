import Foundation

/// Closed endpoint catalogue: no URL, account, item, inode or session value can
/// enter the remote HTTP telemetry contract.
public enum RemoteTelemetryHTTPEndpoint: Equatable, Sendable {
    case audiobookshelf(DiagnosticEndpoint)
    case attestationChallenge
    case attestationEnroll
    case tokenChallenge
    case token

    public var name: String {
        switch self {
        case .audiobookshelf(let endpoint): endpoint.rawValue
        case .attestationChallenge: "telemetry.attestation_challenge"
        case .attestationEnroll: "telemetry.attestation_enroll"
        case .tokenChallenge: "telemetry.token_challenge"
        case .token: "telemetry.token"
        }
    }
}

public enum RemoteTelemetryHTTPResult: Equatable, Sendable {
    case response(statusCode: Int)
    case cancelled
    case urlError(URLError.Code)
    case transportFailure
    case nonHTTPResponse

    public static func failure(_ error: any Error) -> Self {
        if error is CancellationError
            || (error as? URLError)?.code == .cancelled
        {
            return .cancelled
        }
        if let error = error as? URLError { return .urlError(error.code) }
        return .transportFailure
    }

    var outcome: RemoteTelemetryOutcome {
        switch self {
        case .response(let status):
            (400...599).contains(status) ? .failed(.transport) : .succeeded
        case .cancelled: .cancelled
        case .urlError, .transportFailure, .nonHTTPResponse: .failed(.transport)
        }
    }
}

public struct RemoteTelemetryHTTPCall: Equatable, Sendable {
    public let endpoint: RemoteTelemetryHTTPEndpoint
    public let method: DiagnosticHTTPMethod
    public let result: RemoteTelemetryHTTPResult

    public init(
        endpoint: RemoteTelemetryHTTPEndpoint, method: DiagnosticHTTPMethod,
        result: RemoteTelemetryHTTPResult
    ) {
        self.endpoint = endpoint
        self.method = method
        self.result = result
    }

    var attributes: [String: String] {
        var values = [
            "bleat.http.endpoint": endpoint.name,
            "http.request.method": method.rawValue,
        ]
        switch result {
        case .response(let status):
            values["bleat.http.stage"] = "response"
            values["http.response.status_code"] = String(status)
        case .cancelled:
            values["bleat.http.stage"] = "transport"
            values["bleat.http.failure_code"] =
                DiagnosticFailureCode.requestCancelled.rawValue
        case .urlError(let code):
            values["bleat.http.stage"] = "transport"
            values["bleat.http.failure_code"] = "url_error"
            values["error.type"] = String(code.rawValue)
        case .transportFailure:
            values["bleat.http.stage"] = "transport"
            values["bleat.http.failure_code"] =
                DiagnosticFailureCode.requestTransportFailed.rawValue
        case .nonHTTPResponse:
            values["bleat.http.stage"] = "response"
            values["bleat.http.failure_code"] =
                DiagnosticFailureCode.nonHTTPResponse.rawValue
        }
        return values
    }
}
