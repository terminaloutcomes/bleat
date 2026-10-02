#![deny(warnings, clippy::panic, clippy::unwrap_used)]

#[path = "../ci_cache_keys.rs"]
mod ci_cache_keys;

use std::process::ExitCode;

fn main() -> ExitCode {
    let mut arguments = std::env::args().skip(1);
    let Some(lane) = arguments.next() else {
        eprintln!("Pass ios or host");
        return ExitCode::FAILURE;
    };
    if arguments.next().is_some() {
        eprintln!("Pass exactly one cache lane");
        return ExitCode::FAILURE;
    }
    match ci_cache_keys::write_keys(&lane) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("CI cache key generation failed: {error}");
            ExitCode::FAILURE
        }
    }
}
