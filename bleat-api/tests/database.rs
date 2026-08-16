use bleat_api::{
    config::DatabaseConfig,
    database::{Migrator, connect_and_migrate},
    installation::{
        CounterAdvanceOutcome, InstallationEnvironment, InstallationRepository, InstallationStatus,
        NewInstallation,
    },
};
use sea_orm_migration::{MigratorTrait, SchemaManager};
use uuid::Uuid;

fn test_database() -> DatabaseConfig {
    DatabaseConfig::new(
        std::env::var("BLEAT_API_TEST_DATABASE_URL")
            .expect("BLEAT_API_TEST_DATABASE_URL must name the disposable PostgreSQL database"),
        4,
        std::time::Duration::from_secs(5),
    )
    .expect("test database configuration should be valid")
}

async fn repository() -> InstallationRepository {
    InstallationRepository::new(
        connect_and_migrate(&test_database())
            .await
            .expect("test database should connect"),
    )
}

#[tokio::test]
async fn migrations_create_the_issue_64_schema_and_are_repeatable() {
    let database = connect_and_migrate(&test_database())
        .await
        .expect("initial migration should succeed");
    Migrator::up(&database, None)
        .await
        .expect("reapplying migrations should succeed");

    let schema = SchemaManager::new(&database);
    assert!(
        schema
            .has_table("installations")
            .await
            .expect("installation table lookup should succeed")
    );
    assert!(
        schema
            .has_table("challenges")
            .await
            .expect("challenge table lookup should succeed")
    );
}

#[tokio::test]
async fn installation_state_persists_and_disabling_is_typed() {
    let repository = repository().await;
    let key_id = format!("test-key-{}", Uuid::new_v4());
    let created = repository
        .create_verified(NewInstallation {
            app_attest_key_id: key_id.clone(),
            public_key: vec![4; 65],
            environment: InstallationEnvironment::Development,
        })
        .await
        .expect("verified installation should persist");

    assert_eq!(created.app_attest_key_id, key_id);
    assert_eq!(created.public_key, vec![4; 65]);
    assert_eq!(created.environment, InstallationEnvironment::Development);
    assert_eq!(created.status, InstallationStatus::Active);
    assert_eq!(created.sign_count, 0);

    assert_eq!(
        repository
            .disable(created.id)
            .await
            .expect("disable should succeed"),
        bleat_api::installation::DisableOutcome::Disabled
    );
    assert_eq!(
        repository
            .disable(created.id)
            .await
            .expect("repeat disable should be typed"),
        bleat_api::installation::DisableOutcome::AlreadyDisabled
    );
    assert!(
        repository
            .find_active(created.id)
            .await
            .expect("lookup should succeed")
            .is_none()
    );
}

#[tokio::test]
async fn assertion_counter_compare_and_update_accepts_only_one_racer() {
    let repository = repository().await;
    let installation = repository
        .create_verified(NewInstallation {
            app_attest_key_id: format!("counter-key-{}", Uuid::new_v4()),
            public_key: vec![4; 65],
            environment: InstallationEnvironment::Production,
        })
        .await
        .expect("verified installation should persist");

    let (first, second) = tokio::join!(
        repository.advance_counter(installation.id, 0, 1),
        repository.advance_counter(installation.id, 0, 1),
    );
    let outcomes = [
        first.expect("first update should have a typed outcome"),
        second.expect("second update should have a typed outcome"),
    ];
    assert_eq!(
        outcomes
            .iter()
            .filter(|outcome| **outcome == CounterAdvanceOutcome::Advanced)
            .count(),
        1
    );
    assert_eq!(
        outcomes
            .iter()
            .filter(|outcome| **outcome == CounterAdvanceOutcome::Conflict)
            .count(),
        1
    );
    assert_eq!(
        repository
            .advance_counter(installation.id, 1, 1)
            .await
            .expect("invalid transition should be typed"),
        CounterAdvanceOutcome::InvalidTransition
    );
}
