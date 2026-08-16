use axum::{Json, http::StatusCode, response::IntoResponse};
use serde::Serialize;
use uuid::Uuid;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    MalformedRequest,
    RequestTooLarge,
    TemporarilyUnavailable,
    RateLimited,
    AuthenticationRejected,
}

#[derive(Debug, Serialize)]
pub struct ErrorBody {
    pub error: ErrorDetail,
    pub request_id: Uuid,
}

#[derive(Debug, Serialize)]
pub struct ErrorDetail {
    pub code: ErrorCode,
    pub message: &'static str,
}

pub struct ApiError {
    status: StatusCode,
    code: ErrorCode,
    message: &'static str,
    request_id: Uuid,
}

impl ApiError {
    pub fn malformed(request_id: Uuid) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            code: ErrorCode::MalformedRequest,
            message: "request body is not valid JSON",
            request_id,
        }
    }

    pub fn temporarily_unavailable(request_id: Uuid) -> Self {
        Self {
            status: StatusCode::SERVICE_UNAVAILABLE,
            code: ErrorCode::TemporarilyUnavailable,
            message: "authentication service is temporarily unavailable",
            request_id,
        }
    }

    pub fn request_too_large(request_id: Uuid) -> Self {
        Self {
            status: StatusCode::PAYLOAD_TOO_LARGE,
            code: ErrorCode::RequestTooLarge,
            message: "request body exceeds the configured limit",
            request_id,
        }
    }

    pub fn timed_out(request_id: Uuid) -> Self {
        Self {
            status: StatusCode::GATEWAY_TIMEOUT,
            code: ErrorCode::TemporarilyUnavailable,
            message: "request timed out",
            request_id,
        }
    }

    pub fn rate_limited(request_id: Uuid) -> Self {
        Self {
            status: StatusCode::SERVICE_UNAVAILABLE,
            code: ErrorCode::RateLimited,
            message: "request capacity is temporarily unavailable",
            request_id,
        }
    }

    pub fn issuance_rate_limited(request_id: Uuid) -> Self {
        Self {
            status: StatusCode::TOO_MANY_REQUESTS,
            code: ErrorCode::RateLimited,
            message: "challenge issuance rate exceeded",
            request_id,
        }
    }

    pub fn authentication_rejected(request_id: Uuid) -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            code: ErrorCode::AuthenticationRejected,
            message: "installation authentication was rejected",
            request_id,
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> axum::response::Response {
        (
            self.status,
            Json(ErrorBody {
                error: ErrorDetail {
                    code: self.code,
                    message: self.message,
                },
                request_id: self.request_id,
            }),
        )
            .into_response()
    }
}
