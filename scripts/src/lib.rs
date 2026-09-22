//! Script-related things for the Bleat project because shell scripts aren't fun.

#[allow(
    clippy::too_many_arguments,
    clippy::redundant_field_names,
    clippy::collapsible_if,
    clippy::result_large_err,
    clippy::double_must_use
)]
pub mod appstore;
pub mod deploy_device;
pub mod error;
