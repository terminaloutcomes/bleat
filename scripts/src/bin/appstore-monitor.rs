use base64::Engine;
use clap::{Parser, Subcommand};
use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
use reqwest::header::HeaderValue;
use scripts::appstore::*;
use serde::{Deserialize, Serialize};
use std::{path::PathBuf, process::ExitCode};
use url::Url;

fn openapi_file() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("appstore.json")
}

#[derive(Deserialize, Clone)]
struct OpenApiServer {
    url: Url,
}

#[derive(Deserialize, Clone)]
struct OpenApiSpec {
    servers: Vec<OpenApiServer>,
}

fn openapi_base_url() -> Url {
    let openapi_file = openapi_file();
    let file_contents =
        std::fs::read_to_string(&openapi_file).expect("Failed to read OpenAPI specification file");
    let spec: OpenApiSpec =
        serde_json::from_str(&file_contents).expect("Failed to parse OpenAPI specification JSON");
    let first_server = spec
        .servers
        .first()
        .expect("No servers defined in OpenAPI specification");
    first_server.url.clone()
}

async fn ensure_openapi_file_exists(force: bool) {
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
    AppStatus,
}

#[derive(Parser)]
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

    if let Some(command) = cli_opts.command {
        match command {
            Commands::UpdateSpec(args) => {
                ensure_openapi_file_exists(args.force).await;
                return ExitCode::SUCCESS;
            }
            Commands::UpdateCodegen => {
                return ExitCode::SUCCESS;
            }
            Commands::AppStatus => {
                let jwt_payload =
                    generate_app_store_token().expect("Failed to generate App Store token");

                let client = client::HttpClient::new()
                    .with_base_url(openapi_base_url())
                    .with_api_key(&jwt_payload);

                let apps = client
                    .apps_get_collection_builder()
                    .filter_name(vec!["Bleat".to_string()])
                    .send()
                    .await
                    .expect("Failed to fetch apps");
                for (appnum, app) in apps.data.iter().enumerate() {
                    let app_name = match &app.attributes {
                        Some(attributes) => attributes
                            .name
                            .clone()
                            .unwrap_or("Unknown Name?".to_string()),
                        None => "Unknown Name?".to_string(),
                    };
                    println!("{} - {}", app.id, app_name);

                    let versions = client
                        .apps_app_store_versions_get_to_many_related_builder(app.id.clone())
                        .send()
                        .await
                        .expect("Failed to fetch app versions");

                    eprintln!("----------------------------------------------------\nApp versions",);

                    for (num, version) in versions.data.iter().enumerate() {
                        println!("{}", version.id);
                        println!(
                            "{}",
                            serde_json::to_string_pretty(&version.attributes)
                                .expect("Failed to serialize version")
                        );
                        if num != versions.data.len() - 1 {
                            println!("----------------------------------------------------");
                        }
                    }
                    if appnum != apps.data.len() - 1 {
                        println!("----------------------------------------------------");
                    }
                }
            }
        }
    }
    ExitCode::SUCCESS
}
