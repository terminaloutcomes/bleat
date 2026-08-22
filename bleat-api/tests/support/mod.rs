use std::{sync::Arc, time::Duration};

use bleat_api::config::DatabaseConfig;
use testcontainers_modules::{
    postgres::Postgres,
    testcontainers::{ContainerAsync, ImageExt, runners::AsyncRunner},
};
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

const POSTGRES_PORT: u16 = 5432;
const TEST_DATABASE: &str = "bleat";
const TEST_PASSWORD: &str = "development-only";
const TEST_USER: &str = "bleat";
const MAXIMUM_CONCURRENT_DATABASES: usize = 4;

static DATABASE_PERMITS: std::sync::LazyLock<Arc<Semaphore>> =
    std::sync::LazyLock::new(|| Arc::new(Semaphore::new(MAXIMUM_CONCURRENT_DATABASES)));

pub struct TestPostgres {
    _container: ContainerAsync<Postgres>,
    _permit: OwnedSemaphorePermit,
    database_url: String,
}

impl TestPostgres {
    pub async fn start() -> Self {
        let permit = DATABASE_PERMITS
            .clone()
            .acquire_owned()
            .await
            .expect("test database concurrency semaphore should remain open");
        let container = Postgres::default()
            .with_db_name(TEST_DATABASE)
            .with_user(TEST_USER)
            .with_password(TEST_PASSWORD)
            .with_tag("17-bookworm")
            .start()
            .await
            .expect("disposable PostgreSQL container should start");
        let host = container
            .get_host()
            .await
            .expect("PostgreSQL container host should resolve");
        let port = container
            .get_host_port_ipv4(POSTGRES_PORT)
            .await
            .expect("PostgreSQL container port should be mapped");
        let database_url =
            format!("postgres://{TEST_USER}:{TEST_PASSWORD}@{host}:{port}/{TEST_DATABASE}");

        Self {
            _container: container,
            _permit: permit,
            database_url,
        }
    }

    #[allow(
        dead_code,
        reason = "shared integration-test support is compiled per test crate"
    )]
    pub fn database_url(&self) -> &str {
        &self.database_url
    }

    #[allow(
        dead_code,
        reason = "shared integration-test support is compiled per test crate"
    )]
    pub fn config(&self) -> DatabaseConfig {
        DatabaseConfig::new(self.database_url.clone(), 4, Duration::from_secs(5))
            .expect("test database configuration should be valid")
    }
}
