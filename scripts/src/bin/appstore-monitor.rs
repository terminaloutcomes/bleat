use base64::Engine;
use clap::{Parser, Subcommand};
use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
use reqwest::header::HeaderValue;
use scripts::{
    app_store_connect::{openapi_base_url, openapi_file},
    appstore::*,
    appstore_analytics::{AccessType, AnalyticsClient},
};
use serde::Serialize;
use serde_json::json;
use std::path::PathBuf;
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

#[derive(Parser, Debug, Clone)]
struct StatusArgs {
    #[clap(long)]
    name: Option<String>,

    #[clap(long)]
    version_string: Option<String>,

    #[clap(long)]
    latest: bool,

    #[clap(long)]
    pretty: bool,
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
        access_type: DownloadAccessType,
        #[arg(long, default_value = ".build/appstore-reports")]
        output_dir: PathBuf,
    },
}

#[derive(clap::ValueEnum, Clone, Debug)]
enum DownloadAccessType {
    Ongoing,
    OneTimeSnapshot,
}

#[derive(Parser, Debug)]
struct CliOpts {
    #[command(subcommand)]
    pub command: Option<Commands>,
}

#[derive(Serialize)]
struct JwtPayload {
    iss: String,
    iat: u64,
    exp: u64,
    aud: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    scope: Vec<String>,
}

impl JwtPayload {
    fn new(iss: String) -> Self {
        let iat = chrono::Utc::now().timestamp() as u64;
        let exp = iat + 600; // Token valid for 10 minutes
        Self {
            iss,
            iat,
            exp,
            aud: "appstoreconnect-v1".to_string(),
            scope: vec![],
        }
    }
}

fn generate_app_store_token() -> Result<String, Box<dyn std::error::Error>> {
    let key_id = std::env::var("APPSTORE_CONNECT_KEY_ID")?;
    let issuer_id = std::env::var("APPSTORE_CONNECT_ISSUER_ID")?;
    // let private_key_path: String = std::env::var("APPSTORE_CONNECT_PRIVATE_KEY_PATH")?;

    // This is Apple's downloaded AuthKey_<KEY_ID>.p8 file.
    let private_key = base64::engine::general_purpose::STANDARD
        .decode(std::env::var("APPSTORE_CONNECT_PRIVATE_KEY_BASE64")?)?;

    let mut header = Header::new(Algorithm::ES256);
    header.kid = Some(key_id);
    // Header::new already sets typ to JWT.

    let payload = JwtPayload::new(issuer_id);

    let encoding_key = EncodingKey::from_ec_pem(&private_key)?;
    Ok(encode(&header, &payload, &encoding_key)?)
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    let cli_opts = CliOpts::parse();
    // eprintln!("Parsed CLI options: {:?}", cli_opts);
    if let Some(command) = cli_opts.command {
        match command {
            Commands::CreateReport
            | Commands::OneTimeSnapshot
            | Commands::DownloadReports { .. } => {
                let result = async {
                    let client = AnalyticsClient::from_env()?;
                    match command {
                        Commands::CreateReport => println!("{}", client.create_report().await?),
                        Commands::OneTimeSnapshot => println!(
                            "{}",
                            client
                                .one_time_snapshot(std::path::Path::new(".build/appstore-reports"))
                                .await?
                        ),
                        Commands::DownloadReports {
                            access_type,
                            output_dir,
                        } => {
                            let access = match access_type {
                                DownloadAccessType::Ongoing => AccessType::Ongoing,
                                DownloadAccessType::OneTimeSnapshot => AccessType::OneTimeSnapshot,
                            };
                            println!("{}", client.download_reports(access, &output_dir).await?);
                        }
                        _ => return Err(scripts::appstore_analytics::AnalyticsError::RequestState),
                    }
                    Ok::<(), scripts::appstore_analytics::AnalyticsError>(())
                }
                .await;
                if let Err(error) = result {
                    eprintln!("{error}");
                    return ExitCode::FAILURE;
                }
                return ExitCode::SUCCESS;
            }
            Commands::UpdateSpec(args) => {
                ensure_openapi_file_exists(args.force).await;
                return ExitCode::SUCCESS;
            }
            Commands::UpdateCodegen => {
                return ExitCode::SUCCESS;
            }
            Commands::AppStatus(statusargs) => {
                let jwt_payload =
                    generate_app_store_token().expect("Failed to generate App Store token");

                let client = client::HttpClient::new()
                    .with_base_url(openapi_base_url())
                    .with_api_key(&jwt_payload);

                let filter_name = statusargs.name.unwrap_or("Bleat".to_string());

                let mut apps = client
                    .apps_get_collection_builder()
                    .filter_name(vec![filter_name]);

                if let Some(version_string) = statusargs.version_string {
                    apps = apps.filter_app_store_versions(vec![version_string]);
                }

                let apps = apps.send().await.expect("Failed to fetch apps");
                for app in apps.data {
                    let versions = client
                        .apps_app_store_versions_get_to_many_related_builder(app.id.clone())
                        .send()
                        .await
                        .expect("Failed to fetch app versions");

                    // eprintln!("----------------------------------------------------\nApp versions",);
                    if versions.data.is_empty() {
                        eprintln!("No versions found for this app.");
                        return ExitCode::FAILURE;
                    }

                    for version in versions.data.into_iter().enumerate().filter_map(|(i, v)| {
                        if statusargs.latest {
                            if i == 0 { Some(v) } else { None }
                        } else {
                            Some(v)
                        }
                    }) {
                        // println!("{}", version.id);
                        if let Some(attributes_original) = &version.attributes {
                            let mut attributes: serde_json::Map<String, serde_json::Value> =
                                json!(attributes_original)
                                    .as_object()
                                    .cloned()
                                    .expect("Failed to convert attributes into HashMap");
                            attributes.insert("appId".to_string(), app.id.clone().into());
                            attributes.insert("versionId".to_string(), version.id.clone().into());
                            if statusargs.pretty {
                                println!(
                                    "{}",
                                    serde_json::to_string_pretty(&attributes)
                                        .expect("Failed to serialize version")
                                );
                            } else {
                                println!("{}", json!(&attributes))
                            }
                        }
                    }
                }
            }
        }
    }
    ExitCode::SUCCESS
}
