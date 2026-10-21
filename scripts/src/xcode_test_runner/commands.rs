//! Direct native tools only; aggregate shell workflows have separate owners.
use super::{Result, XcodeRunnerError};
use crate::ci_smoke::owned_command::{self, Cause, Failure, Stage};
use std::{
    process::{Command, ExitStatus, Output},
    time::Duration,
};

#[derive(Clone, Copy, Debug)]
pub(super) enum NativeRole {
    SwiftRelease,
    ReleaseVersionTests,
    PackageResolution,
    SimulatorBuild,
    BuildForTesting,
    Enumeration,
    Execution,
}
impl NativeRole {
    pub(super) fn stage(self) -> Stage {
        match self {
            Self::SwiftRelease => Stage::SwiftReleaseBuild,
            Self::ReleaseVersionTests => Stage::ReleaseVersionTests,
            Self::PackageResolution => Stage::PackageResolution,
            Self::SimulatorBuild => Stage::SimulatorReleaseBuild,
            Self::BuildForTesting => Stage::XcodeBuildForTesting,
            Self::Enumeration => Stage::XcodeTestEnumeration,
            Self::Execution => Stage::XcodeTestExecution,
        }
    }
    pub(super) fn budget(self) -> Duration {
        Duration::from_secs(match self {
            Self::ReleaseVersionTests | Self::PackageResolution => 1200,
            Self::SwiftRelease | Self::SimulatorBuild | Self::BuildForTesting => 2400,
            Self::Enumeration => 300,
            Self::Execution => 3600,
        })
    }
}
#[derive(Clone, Copy)]
pub(super) struct NativeBudgets {
    pub(super) command: Option<Duration>,
    pub(super) cleanup: Duration,
}
impl Default for NativeBudgets {
    fn default() -> Self {
        Self {
            command: None,
            cleanup: Duration::from_secs(3),
        }
    }
}
#[derive(Clone, Copy)]
pub(super) enum XcodeAction {
    ResolvePackages,
    Build,
}
impl XcodeAction {
    pub(super) fn argument(self) -> &'static str {
        match self {
            Self::ResolvePackages => "-resolvePackageDependencies",
            Self::Build => "build",
        }
    }
    pub(super) fn role(self) -> NativeRole {
        match self {
            Self::ResolvePackages => NativeRole::PackageResolution,
            Self::Build => NativeRole::SimulatorBuild,
        }
    }
}
pub(super) fn native_command_status(
    command: &mut Command,
    role: NativeRole,
    label: &str,
    budgets: NativeBudgets,
) -> Result<ExitStatus> {
    eprintln!("Running {label}");
    let outcome = owned_command::run_inherited(
        command,
        role.stage(),
        budgets.command.unwrap_or_else(|| role.budget()),
        budgets.cleanup,
    );
    status_from_outcome(outcome, label)
}
pub(super) fn status_from_outcome(
    outcome: std::result::Result<Output, Box<Failure>>,
    label: &str,
) -> Result<ExitStatus> {
    match outcome {
        Ok(output) => Ok(output.status),
        Err(failure) => {
            // Preserve status()'s nonzero-exit contract only after the native
            // owner confirms retirement. Never hide incomplete cleanup as exit.
            if let Cause::Exit(status) = &failure.cause
                && failure
                    .cleanup
                    .as_ref()
                    .is_some_and(|cleanup| cleanup.succeeded())
            {
                return Ok(*status);
            }
            Err(XcodeRunnerError::NativeCommand {
                stage: label.to_owned(),
                source: failure,
            })
        }
    }
}
