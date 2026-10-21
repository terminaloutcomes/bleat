//! Native SwiftPM boundaries, separate from selection and report interpretation.
use super::{SwiftTestResultsError, TestRunner, VerificationSummary};
use crate::ci_smoke::owned_command::{self, Failure, Stage};
use std::{
    ffi::OsStr,
    process::{Command, Output},
    time::Duration,
};

#[derive(Clone, Copy, Debug)]
pub(crate) enum SwiftCommand {
    Discovery(TestRunner),
    Execution,
}
impl SwiftCommand {
    pub(crate) fn stage(self) -> Stage {
        match self {
            Self::Discovery(TestRunner::Xctest) => Stage::SwiftPMXCTestDiscovery,
            Self::Discovery(TestRunner::SwiftTesting) => Stage::SwiftTestingDiscovery,
            Self::Execution => Stage::SwiftPMExecution,
        }
    }
    pub(crate) fn budget(self) -> Duration {
        Duration::from_secs(match self {
            Self::Discovery(_) => 1200,
            Self::Execution => 3600,
        })
    }
}

pub(crate) fn discovery_command(runner: TestRunner, package_path: Option<&OsStr>) -> Command {
    let mut command = Command::new("swift");
    command.arg("test");
    if let Some(path) = package_path {
        command.arg("--package-path").arg(path);
    }
    command.arg("list").arg(runner.discovery_flag());
    command
}

pub(crate) fn run_command(
    command: &mut Command,
    phase: SwiftCommand,
) -> Result<Output, Box<Failure>> {
    run_with_budget(command, phase, phase.budget(), Duration::from_secs(3))
}
pub(crate) fn run_with_budget(
    command: &mut Command,
    phase: SwiftCommand,
    budget: Duration,
    cleanup: Duration,
) -> Result<Output, Box<Failure>> {
    match phase {
        SwiftCommand::Discovery(_) => {
            owned_command::run_stdout(command, phase.stage(), budget, cleanup, 64 * 1024 * 1024)
        }
        SwiftCommand::Execution => {
            owned_command::run_inherited(command, phase.stage(), budget, cleanup)
        }
    }
}

pub(crate) fn finish_execution(
    execution: Result<Output, Box<Failure>>,
    audit: impl FnOnce() -> Result<VerificationSummary, SwiftTestResultsError>,
) -> Result<VerificationSummary, SwiftTestResultsError> {
    // Missing or unsuccessful native execution still requires the report audit.
    // Selection and observation artifacts are prepared before this boundary.
    let report = audit();
    match (execution, report) {
        (Ok(_), report) => report,
        (Err(command), report) => Err(SwiftTestResultsError::ExecutionAndAudit {
            command,
            report_audit: report.err().map(Box::new),
        }),
    }
}

pub(crate) fn decode_discovery_output(
    output: Vec<u8>,
    runner: TestRunner,
) -> Result<String, SwiftTestResultsError> {
    String::from_utf8(output).map_err(|error| SwiftTestResultsError::DiscoveryEncoding {
        runner,
        source: error.utf8_error(),
    })
}
