#![deny(warnings)]
#![deny(unsafe_code)]
#![warn(unused_extern_crates)]
#![deny(clippy::todo)]
#![deny(clippy::unimplemented)]
#![deny(clippy::unwrap_used)]
#![deny(clippy::expect_used)]
#![deny(clippy::panic)]
#![deny(clippy::unreachable)]
#![deny(clippy::await_holding_lock)]
#![deny(clippy::needless_pass_by_value)]
#![deny(clippy::trivially_copy_pass_by_ref)]

pub mod app_attest;
pub mod challenge;
pub mod config;
pub mod database;
pub mod entity;
pub mod error;
mod forwarding;
pub mod http;
pub mod installation;
pub mod observability;
pub mod telemetry_auth;

pub use http::router;

#[cfg(test)]
pub(crate) static TRACING_TEST_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
