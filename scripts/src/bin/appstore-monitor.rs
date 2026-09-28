use clap::Parser;
use reqwest::header::HeaderValue;
use scripts::{
    app_store_connect::{CliOpts, Commands, appstatus, openapi_file},
    appstore_analytics::{AnalyticsClient, AnalyticsError, parse_download_dir},
};
use std::process::ExitCode;

pub async fn ensure_openapi_file_exists(force: bool) {
    let openapi_file = openapi_file();
    let file_already_exists = openapi_file.exists();

    if !file_already_exists || force {
        if force {
            eprintln!("Overwriting existing OpenAPI specification file");
        }
        let mut request = reqwest::Request::new(reqwest::Method::GET, "https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip".parse().expect("Failed to parse URL"));
        request.headers_mut().insert(
            "User-Agent",
            HeaderValue::from_static("appstore-monitor/1.0"),
        );
        let contents = reqwest::Client::new()
            .execute(request)
            .await
            .expect("Failed to download OpenAPI specification")
            .bytes()
            .await
            .expect("Failed to read OpenAPI specification bytes");

        let mut archive = zip::ZipArchive::new(std::io::Cursor::new(contents))
            .expect("Failed to read OpenAPI specification zip archive");
        let tempdir = tempfile::TempDir::new().expect("Failed to create temporary directory");

        archive
            .extract(tempdir.path())
            .expect("Failed to extract OpenAPI specification from zip file");
        // find the file
        let mut found = false;
        for file in std::fs::read_dir(tempdir.path()).expect("Failed to read temporary directory") {
            let file = file.expect("Failed to read file in temporary directory");
            if file.path().extension().and_then(|s| s.to_str()) == Some("json") {
                std::fs::copy(file.path(), &openapi_file)
                    .expect("Failed to copy OpenAPI specification to destination");
                found = true;
                break;
            }
        }
        if !found {
            panic!("Failed to find OpenAPI specification JSON file in the extracted archive");
        }
        eprintln!(
            "Downloaded and extracted OpenAPI specification to {}",
            openapi_file.display()
        );
    } else {
        eprintln!(
            "OpenAPI specification file already exists at {}",
            openapi_file.display()
        );
    }
}

fn handle_error(error: AnalyticsError) -> ExitCode {
    eprintln!("{error}");
    ExitCode::FAILURE
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<ExitCode, ExitCode> {
    let cli_opts = CliOpts::parse();
    match cli_opts.clone().command {
        Commands::CreateReport => {
            let client = AnalyticsClient::new(&cli_opts).map_err(handle_error)?;
            println!("{}", client.create_report().await.map_err(handle_error)?);
        }
        Commands::OneTimeSnapshot { download_dir } => {
            let client = AnalyticsClient::new(&cli_opts).map_err(handle_error)?;
            let download_dir = parse_download_dir(download_dir).map_err(handle_error)?;
            println!(
                "{}",
                client
                    .one_time_snapshot(&download_dir)
                    .await
                    .map_err(handle_error)?
            );
        }
        Commands::DownloadReports {
            access_type,
            list,
            download_dir,
        } => {
            let client = AnalyticsClient::new(&cli_opts).map_err(handle_error)?;
            let download_dir = parse_download_dir(download_dir).map_err(handle_error)?;
            if list {
                let listing = client
                    .list_reports(access_type, &download_dir)
                    .await
                    .map_err(handle_error)?;
                for request in &listing.requests {
                    println!("Request {request}");
                    for report in listing
                        .reports
                        .iter()
                        .filter(|row| &row.request_id == request)
                    {
                        let latest = report
                            .latest_daily
                            .map_or_else(|| "none".to_string(), |date| date.to_string());
                        println!(
                            "  {} [{}]: {} DAILY instances, {} segments; latest processing date {}",
                            report.name,
                            report.category,
                            report.daily_instances,
                            report.segments,
                            latest
                        );
                    }
                }
                if listing.reports.is_empty() {
                    println!("No reports generated for the selected request yet.");
                }
            } else {
                println!(
                    "{}",
                    client
                        .download_reports(access_type, &download_dir)
                        .await
                        .map_err(handle_error)?
                );
            }
        }

        Commands::UpdateSpec(args) => {
            ensure_openapi_file_exists(args.force).await;
        }
        Commands::UpdateCodegen => {}
        Commands::AppStatus(statusargs) => {
            appstatus(statusargs, &cli_opts).await?;
        }
    }
    Ok(ExitCode::SUCCESS)
}
