pub mod config;
pub mod error;
pub mod http;
pub mod observability;

pub use http::router;

#[cfg(test)]
pub(crate) static TRACING_TEST_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
