use bleat_api::{
    config::DatabaseConfig,
    database::{Migrator, connect_and_migrate},
};
use sea_orm_migration::{MigratorTrait, SchemaManager};

fn test_database() -> DatabaseConfig {
    DatabaseConfig::new(
        std::env::var("BLEAT_API_TEST_DATABASE_URL")
            .expect("BLEAT_API_TEST_DATABASE_URL must name the disposable PostgreSQL database"),
        4,
        std::time::Duration::from_secs(5),
    )
    .expect("test database configuration should be valid")
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
