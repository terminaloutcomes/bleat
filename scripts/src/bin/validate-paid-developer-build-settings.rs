#![deny(warnings)]
#![warn(unused_extern_crates)]
#![deny(clippy::todo)]
#![deny(clippy::unimplemented)]
#![deny(clippy::unwrap_used)]
#![deny(clippy::panic)]
#![deny(clippy::unreachable)]
#![deny(clippy::await_holding_lock)]
#![deny(clippy::needless_pass_by_value)]
#![deny(clippy::trivially_copy_pass_by_ref)]

fn get_env_or_quit(var_name: &str) -> String {
    match std::env::var(var_name) {
        Ok(value) => value,
        Err(_) => {
            eprintln!("Environment var {} must be set", var_name);
            std::process::exit(1);
        }
    }
}

fn check_var_values(var_name: &str, allowed_values: &[&str]) {
    let value = get_env_or_quit(var_name);
    if !allowed_values.contains(&value.as_str()) {
        eprintln!(
            "Environment var {} must be one of {:?}",
            var_name, allowed_values
        );
        std::process::exit(2);
    }
    eprintln!("✅ {} is set to {}", var_name, value);
}

fn parse_telemetry_url(test_url: &str, requires_origin: bool) -> Result<url::Url, String> {
    let url = match url::Url::parse(test_url) {
        Ok(parsed_url) => parsed_url,
        Err(_) => {
            return Err(format!("Failed to parse telemetry URL: {}", test_url));
        }
    };

    if url.scheme() != "http" && url.scheme() != "https" {
        return Err(format!(
            "Telemetry URL must have http or https scheme: {}",
            test_url
        ));
    }
    if requires_origin && url.path() != "/" {
        return Err(format!("Telemetry URL must be an origin: {}", test_url));
    }
    Ok(url)
}

fn validate_ios_build_settings() {
    check_var_values("BLEAT_APP_ATTEST_MODE", &["enabled", "disabled"]);
    check_var_values("BLEAT_CARPLAY_MODE", &["enabled", "disabled"]);

    let bleat_telemetry_auth_base_url = std::env::var("BLEAT_TELEMETRY_AUTH_BASE_URL")
        .expect("BLEAT_TELEMETRY_AUTH_BASE_URL must be set");
    let bleat_telemetry_auth_base_url =
        match parse_telemetry_url(&bleat_telemetry_auth_base_url, false) {
            Ok(url) => url,
            Err(err) => {
                eprintln!(
                    "Failed to parse BLEAT_TELEMETRY_AUTH_BASE_URL ({}): {}",
                    bleat_telemetry_auth_base_url, err
                );
                std::process::exit(2);
            }
        };
    // check that BLEAT_TELEMETRY_AUTH_BASE_URL is HTTPS or Debug loopback HTTP
    let schema_not_https = bleat_telemetry_auth_base_url.scheme().to_lowercase() != "https";
    let debug_config = std::env::var("CONFIGURATION").unwrap_or("".to_string()) == "Debug";
    let url_host_is_local = ["localhost", "127.0.0.1", "::1"]
        .contains(&bleat_telemetry_auth_base_url.host_str().unwrap_or(""));

    if !debug_config && (url_host_is_local) || (!url_host_is_local && schema_not_https) {
        eprintln!("BLEAT_TELEMETRY_AUTH_BASE_URL must be HTTPS or Debug loopback HTTP");
        std::process::exit(2);
    }
}

fn validate_telemetry_otlp_endpoint() {
    let bleat_telemetry_otlp_endpoint = get_env_or_quit("BLEAT_TELEMETRY_OTLP_ENDPOINT");
    let bleat_telemetry_otlp_endpoint =
        match parse_telemetry_url(&bleat_telemetry_otlp_endpoint, true) {
            Ok(url) => url,
            Err(err) => {
                eprintln!(
                    "Failed to parse BLEAT_TELEMETRY_OTLP_ENDPOINT ({}): {}",
                    bleat_telemetry_otlp_endpoint, err
                );
                std::process::exit(2);
            }
        };

    if bleat_telemetry_otlp_endpoint.scheme().to_lowercase() != "https" {
        eprintln!("BLEAT_TELEMETRY_OTLP_ENDPOINT must be a valid HTTPS origin for iOS builds");
        std::process::exit(2);
    }
    if bleat_telemetry_otlp_endpoint.fragment().is_some() {
        eprintln!("BLEAT_TELEMETRY_OTLP_ENDPOINT must not contain a URL fragment");
        std::process::exit(2);
    }
    if bleat_telemetry_otlp_endpoint.path() != "/" {
        eprintln!("BLEAT_TELEMETRY_OTLP_ENDPOINT must not contain a URL path");
        std::process::exit(2);
    }
    if bleat_telemetry_otlp_endpoint.query().is_some() {
        eprintln!("BLEAT_TELEMETRY_OTLP_ENDPOINT must not contain a URL query");
        std::process::exit(2);
    }
    if !bleat_telemetry_otlp_endpoint.username().is_empty() {
        eprintln!("BLEAT_TELEMETRY_OTLP_ENDPOINT must not contain a URL username/credentials");
        std::process::exit(2);
    }
    eprintln!("✅ BLEAT_TELEMETRY_OTLP_ENDPOINT is set",);
}

fn main() {
    check_var_values("BUILD_WITHOUT_PAID_DEVELOPER", &["YES", "NO"]);
    check_var_values("BLEAT_CLOUDKIT_MODE", &["enabled", "disabled"]);

    check_var_values("PLATFORM_NAME", &["iphoneos", "iphonesimulator", "macosx"]);
    let platform_name = get_env_or_quit("PLATFORM_NAME");
    if platform_name == "macosx" {
        eprintln!("✅ Running on macOS platform, telemetry checks skipped");
    } else if ["iphoneos", "iphonesimulator"].contains(&platform_name.as_ref()) {
        validate_ios_build_settings();
        validate_telemetry_otlp_endpoint();
    }
}
