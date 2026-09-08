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
    LimiterCapacity,
    GlobalCapacity,
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
    retry_seconds: Option<u64>,
}

impl ApiError {
    pub fn malformed(request_id: Uuid) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            code: ErrorCode::MalformedRequest,
            message: "request body is not valid JSON",
            request_id,
            retry_seconds: None,
        }
    }

    pub fn temporarily_unavailable(request_id: Uuid) -> Self {
        Self {
            status: StatusCode::SERVICE_UNAVAILABLE,
            code: ErrorCode::TemporarilyUnavailable,
            message: "authentication service is temporarily unavailable",
            request_id,
            retry_seconds: None,
        }
    }

    pub fn request_too_large(request_id: Uuid) -> Self {
        Self {
            status: StatusCode::PAYLOAD_TOO_LARGE,
            code: ErrorCode::RequestTooLarge,
            message: "request body exceeds the configured limit",
            request_id,
            retry_seconds: None,
        }
    }

    pub fn timed_out(request_id: Uuid) -> Self {
        Self {
            status: StatusCode::GATEWAY_TIMEOUT,
            code: ErrorCode::TemporarilyUnavailable,
            message: "request timed out",
            request_id,
            retry_seconds: None,
        }
    }

    pub fn rate_limited(request_id: Uuid) -> Self {
        Self {
            status: StatusCode::SERVICE_UNAVAILABLE,
            code: ErrorCode::GlobalCapacity,
            message: "request capacity is temporarily unavailable",
            request_id,
            retry_seconds: None,
        }
    }

    pub fn issuance_rate_limited(request_id: Uuid, retry_seconds: u64) -> Self {
        Self {
            status: StatusCode::TOO_MANY_REQUESTS,
            code: ErrorCode::RateLimited,
            message: "challenge issuance rate exceeded",
            request_id,
            retry_seconds: Some(retry_seconds),
        }
    }

    pub fn limiter_capacity(request_id: Uuid) -> Self {
        Self {
            status: StatusCode::SERVICE_UNAVAILABLE,
            code: ErrorCode::LimiterCapacity,
            message: "challenge admission capacity is temporarily unavailable",
            request_id,
            retry_seconds: None,
        }
    }

    pub fn authentication_rejected(request_id: Uuid) -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            code: ErrorCode::AuthenticationRejected,
            message: "installation authentication was rejected",
            request_id,
            retry_seconds: None,
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> axum::response::Response {
        let mut response = (
            self.status,
            Json(ErrorBody {
                error: ErrorDetail {
                    code: self.code,
                    message: self.message,
                },
                request_id: self.request_id,
            }),
        )
            .into_response();
        if let Some(seconds) = self.retry_seconds
            && let Ok(value) = axum::http::HeaderValue::from_str(&seconds.to_string())
        {
            response
                .headers_mut()
                .insert(axum::http::header::RETRY_AFTER, value);
        }
        response
    }
}
