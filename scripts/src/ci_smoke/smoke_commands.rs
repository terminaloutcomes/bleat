//! Remaining smoke phases use the same invocation-owned process boundary.
use super::{
    Result, erase,
    owned_command::{self, Running, Stage},
};
use std::{process::Command, thread, time::Duration};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum SmokeCommand {
    Version,
    Inventory,
    Settings,
    Enumeration,
    Install,
    Execution,
}
impl SmokeCommand {
    pub(super) fn stage(self) -> Stage {
        match self {
            Self::Version => Stage::XcodeVersion,
            Self::Inventory => Stage::SimulatorInventory,
            Self::Settings => Stage::BuildSettings,
            Self::Enumeration => Stage::TestEnumeration,
            Self::Install => Stage::SimulatorInstall,
            Self::Execution => Stage::TestExecution,
        }
    }
    pub(super) fn budget(self) -> Duration {
        Duration::from_secs(match self {
            Self::Version | Self::Inventory => 120,
            Self::Settings | Self::Enumeration | Self::Install => 300,
            Self::Execution => 2400,
        })
    }
    fn captures(self) -> bool {
        matches!(self, Self::Inventory | Self::Settings)
    }
}

pub(super) fn run_command(command: &mut Command, phase: SmokeCommand) -> Result<Vec<u8>> {
    run_with_budget(command, phase, phase.budget(), Duration::from_secs(3))
}

pub(super) fn run_with_budget(
    command: &mut Command,
    phase: SmokeCommand,
    budget: Duration,
    cleanup: Duration,
) -> Result<Vec<u8>> {
    if phase.captures() {
        // Match the structured report acceptance ceiling. These files may grow
        // until the deadline; the ceiling limits accepted reads, not disk usage.
        return owned_command::run_with_capture_limit(
            command,
            phase.stage(),
            budget,
            cleanup,
            None,
            64 * 1024 * 1024,
        )
        .map(|output| output.stdout)
        .map_err(erase);
    }
    // Preserve live Xcode/simctl console output without buffering it. The
    // command owner still observes, bounds, retires and reaps this exact group.
    let mut running =
        Running::start(command, phase.stage(), budget, cleanup, None, false).map_err(erase)?;
    loop {
        if let Some(outcome) = running.poll() {
            return outcome.map(|_| Vec::new()).map_err(erase);
        }
        thread::sleep(Duration::from_millis(10));
    }
}

#[derive(Debug)]
pub(super) struct TestPhaseFailure {
    pub(super) execution: Option<Box<dyn std::error::Error + Send + Sync>>,
    pub(super) verification: Option<Box<dyn std::error::Error + Send + Sync>>,
}

impl std::fmt::Display for TestPhaseFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "iOS execution failure: {:?}; result verification failure: {:?}",
            self.execution, self.verification
        )
    }
}
impl std::error::Error for TestPhaseFailure {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        self.execution
            .as_deref()
            .or(self.verification.as_deref())
            .map(|error| error as &(dyn std::error::Error + 'static))
    }
}

pub(super) fn finish_tests(
    execution: Result<()>,
    verify: impl FnOnce() -> Result<()>,
) -> Result<()> {
    // Always inspect the result artifact, including spawn/deadline/exit failure.
    let verification = verify();
    match (execution, verification) {
        (Ok(()), Ok(())) => Ok(()),
        (execution, verification) => Err(Box::new(TestPhaseFailure {
            execution: execution.err(),
            verification: verification.err(),
        })),
    }
}
