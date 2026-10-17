fn main() {
    if let Err(error) = scripts::swift_test_results::run_cli() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
