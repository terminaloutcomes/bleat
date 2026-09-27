use clap::{Parser, Subcommand};
use reqwest::header::HeaderValue;
use scripts::{
    app_store_connect::{StatusArgs, appstatus, openapi_file},
    appstore_analytics::{AccessType, AnalyticsClient, AnalyticsError, download_dir_from_env},
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

#[derive(Parser, Debug, Clone)]
struct UpdateArgs {
    #[clap(long)]
    force: bool,
}

#[derive(Subcommand, Debug, Clone)]
enum Commands {
    UpdateSpec(UpdateArgs),
    UpdateCodegen,
    AppStatus(StatusArgs),
    CreateReport,
    OneTimeSnapshot,
    DownloadReports {
        #[arg(long, value_enum)]
        access_type: AccessType,
    },
}

#[derive(Parser, Debug)]
struct CliOpts {
    #[command(subcommand)]
    pub command: Commands,
}

fn handle_error(error: AnalyticsError) -> ExitCode {
    eprintln!("{error}");
    ExitCode::FAILURE
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<ExitCode, ExitCode> {
    let cli_opts = CliOpts::parse();
    match cli_opts.command {
        Commands::CreateReport => {
            let client = AnalyticsClient::from_env().map_err(handle_error)?;
            println!("{}", client.create_report().await.map_err(handle_error)?);
        }
        Commands::OneTimeSnapshot => {
            let client = AnalyticsClient::from_env().map_err(handle_error)?;
            let download_dir = download_dir_from_env().map_err(handle_error)?;
            println!(
                "{}",
                client
                    .one_time_snapshot(&download_dir)
                    .await
                    .map_err(handle_error)?
            );
        }
        Commands::DownloadReports { access_type } => {
            let client = AnalyticsClient::from_env().map_err(handle_error)?;
            let download_dir = download_dir_from_env().map_err(handle_error)?;

            println!(
                "{}",
                client
                    .download_reports(access_type, &download_dir)
                    .await
                    .map_err(handle_error)?
            );
        }

        Commands::UpdateSpec(args) => {
            ensure_openapi_file_exists(args.force).await;
        }
        Commands::UpdateCodegen => {}
        Commands::AppStatus(statusargs) => {
            appstatus(statusargs).await?;
        }
    }
    Ok(ExitCode::SUCCESS)
}
