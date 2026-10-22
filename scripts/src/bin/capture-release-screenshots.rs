#![deny(warnings, clippy::panic, clippy::unwrap_used)]
use clap::Parser;
fn main() -> std::process::ExitCode {
    scripts::release_screenshots::main(scripts::release_screenshots::Arguments::parse())
}
