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
pub mod appstore_testflight;
pub mod ci_artifact_retry;
pub mod ci_cache_keys;
pub mod ci_smoke;
pub mod deploy_device;
pub mod device_build;
pub mod documentation;
pub mod error;
pub mod large_library;
pub mod listening_repair;
pub mod live_fixtures;
pub mod paid_build_modes;
pub mod runner_readiness;
pub mod site_news;
pub mod swift_test_results;
pub mod test_results;
pub mod xcode_test_runner;
