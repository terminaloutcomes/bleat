use sea_orm::{ConnectOptions, Database, DatabaseConnection};
use sea_orm_migration::{MigrationTrait, MigratorTrait, SchemaManager, prelude::*};
use thiserror::Error;

use crate::config::DatabaseConfig;

#[derive(Clone, Copy, Debug, Error, Eq, PartialEq)]
pub enum DatabaseError {
    #[error("database connection failed")]
    Connection,
    #[error("database migration failed")]
    Migration,
    #[error("database query failed")]
    Query,
}

pub async fn connect_and_migrate(
    config: &DatabaseConfig,
) -> Result<DatabaseConnection, DatabaseError> {
    let mut options = ConnectOptions::new(config.url().to_owned());
    options
        .max_connections(config.max_connections as u32)
        .connect_timeout(config.connect_timeout)
        .sqlx_logging(false);
    let database = Database::connect(options)
        .await
        .map_err(|_| DatabaseError::Connection)?;
    Migrator::up(&database, None)
        .await
        .map_err(|_| DatabaseError::Migration)?;
    Ok(database)
}

pub async fn is_ready(database: &DatabaseConnection) -> bool {
    database.ping().await.is_ok()
}

pub struct Migrator;

impl MigratorTrait for Migrator {
    fn migrations() -> Vec<Box<dyn MigrationTrait>> {
        vec![Box::new(InitialSchema)]
    }
}

#[derive(DeriveMigrationName)]
struct InitialSchema;

#[sea_orm_migration::async_trait::async_trait]
impl MigrationTrait for InitialSchema {
    async fn up(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        manager
            .create_table(
                Table::create()
                    .table(Installation::Table)
                    .if_not_exists()
                    .col(
                        ColumnDef::new(Installation::Id)
                            .uuid()
                            .not_null()
                            .primary_key(),
                    )
                    .col(
                        ColumnDef::new(Installation::AppAttestKeyId)
                            .string_len(512)
                            .not_null()
                            .unique_key(),
                    )
                    .col(ColumnDef::new(Installation::PublicKey).binary().not_null())
                    .col(
                        ColumnDef::new(Installation::Environment)
                            .string_len(16)
                            .not_null(),
                    )
                    .col(
                        ColumnDef::new(Installation::Status)
                            .string_len(16)
                            .not_null(),
                    )
                    .col(
                        ColumnDef::new(Installation::SignCount)
                            .big_integer()
                            .not_null(),
                    )
                    .col(
                        ColumnDef::new(Installation::CreatedAt)
                            .timestamp_with_time_zone()
                            .not_null(),
                    )
                    .col(
                        ColumnDef::new(Installation::UpdatedAt)
                            .timestamp_with_time_zone()
                            .not_null(),
                    )
                    .col(ColumnDef::new(Installation::LastSeenAt).timestamp_with_time_zone())
                    .to_owned(),
            )
            .await?;
        manager
            .create_table(
                Table::create()
                    .table(Challenge::Table)
                    .if_not_exists()
                    .col(
                        ColumnDef::new(Challenge::Id)
                            .uuid()
                            .not_null()
                            .primary_key(),
                    )
                    .col(ColumnDef::new(Challenge::Digest).binary().not_null())
                    .col(ColumnDef::new(Challenge::Purpose).string_len(32).not_null())
                    .col(ColumnDef::new(Challenge::InstallationId).uuid())
                    .col(
                        ColumnDef::new(Challenge::ExpiresAt)
                            .timestamp_with_time_zone()
                            .not_null(),
                    )
                    .col(ColumnDef::new(Challenge::ConsumedAt).timestamp_with_time_zone())
                    .col(
                        ColumnDef::new(Challenge::CreatedAt)
                            .timestamp_with_time_zone()
                            .not_null(),
                    )
                    .foreign_key(
                        ForeignKey::create()
                            .from(Challenge::Table, Challenge::InstallationId)
                            .to(Installation::Table, Installation::Id)
                            .on_delete(ForeignKeyAction::Cascade)
                            .on_update(ForeignKeyAction::NoAction),
                    )
                    .to_owned(),
            )
            .await?;
        manager
            .create_index(
                Index::create()
                    .name("idx-challenges-expires-at")
                    .table(Challenge::Table)
                    .col(Challenge::ExpiresAt)
                    .to_owned(),
            )
            .await
    }

    async fn down(&self, manager: &SchemaManager) -> Result<(), DbErr> {
        manager
            .drop_table(Table::drop().table(Challenge::Table).to_owned())
            .await?;
        manager
            .drop_table(Table::drop().table(Installation::Table).to_owned())
            .await
    }
}

#[derive(DeriveIden)]
enum Installation {
    #[sea_orm(iden = "installations")]
    Table,
    Id,
    AppAttestKeyId,
    PublicKey,
    Environment,
    Status,
    SignCount,
    CreatedAt,
    UpdatedAt,
    LastSeenAt,
}

#[derive(DeriveIden)]
enum Challenge {
    #[sea_orm(iden = "challenges")]
    Table,
    Id,
    Digest,
    Purpose,
    InstallationId,
    ExpiresAt,
    ConsumedAt,
    CreatedAt,
}
