//! Script-related things for the Bleat project because shell scripts aren't fun.

pub mod app_store_connect;
#[allow(
    clippy::too_many_arguments,
    clippy::redundant_field_names,
    clippy::collapsible_if,
    clippy::result_large_err,
    clippy::double_must_use
)]
pub mod appstore;
pub mod appstore_analytics;
pub mod appstore_builds;
pub mod ci_artifact_retry;
pub mod ci_cache_keys;
pub mod ci_smoke;
pub mod deploy_device;
pub mod error;
pub mod listening_repair;
pub mod live_fixtures;
pub mod release_versions;
