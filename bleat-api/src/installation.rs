use chrono::Utc;
use sea_orm::{
    ActiveModelTrait, ActiveValue::Set, ColumnTrait, DatabaseConnection, EntityTrait, QueryFilter,
    SqlErr, sea_query::Expr,
};
use thiserror::Error;
use uuid::Uuid;

use crate::entity::installation;

pub use crate::entity::installation::{InstallationEnvironment, InstallationStatus};

const P256_UNCOMPRESSED_PUBLIC_KEY_LENGTH: usize = 65;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Installation {
    pub id: Uuid,
    pub app_attest_key_id: String,
    pub public_key: Vec<u8>,
    pub environment: InstallationEnvironment,
    pub status: InstallationStatus,
    pub sign_count: u32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NewInstallation {
    pub app_attest_key_id: String,
    pub public_key: Vec<u8>,
    pub environment: InstallationEnvironment,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DisableOutcome {
    Disabled,
    AlreadyDisabled,
    NotFound,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CounterAdvanceOutcome {
    Advanced,
    Conflict,
    Disabled,
    NotFound,
    InvalidTransition,
}

#[derive(Clone, Copy, Debug, Error, Eq, PartialEq)]
pub enum InstallationStoreError {
    #[error("the App Attest key identifier is invalid")]
    InvalidKeyIdentifier,
    #[error("the verified public key is invalid")]
    InvalidPublicKey,
    #[error("stored installation state is invalid")]
    InvalidStoredState,
    #[error("the App Attest key is already enrolled")]
    DuplicateKey,
    #[error("installation persistence is temporarily unavailable")]
    Database,
}

#[derive(Clone)]
pub struct InstallationRepository {
    database: DatabaseConnection,
}

impl InstallationRepository {
    pub fn new(database: DatabaseConnection) -> Self {
        Self { database }
    }

    pub async fn create_verified(
        &self,
        installation: NewInstallation,
    ) -> Result<Installation, InstallationStoreError> {
        let key_id = installation.app_attest_key_id.trim();
        if key_id.is_empty() || key_id.len() > 512 {
            return Err(InstallationStoreError::InvalidKeyIdentifier);
        }
        if installation.public_key.len() != P256_UNCOMPRESSED_PUBLIC_KEY_LENGTH
            || installation.public_key.first() != Some(&4)
        {
            return Err(InstallationStoreError::InvalidPublicKey);
        }

        let now = Utc::now();
        let model = installation::ActiveModel {
            id: Set(Uuid::new_v4()),
            app_attest_key_id: Set(key_id.to_owned()),
            public_key: Set(installation.public_key),
            environment: Set(installation.environment),
            status: Set(InstallationStatus::Active),
            sign_count: Set(0),
            created_at: Set(now),
            updated_at: Set(now),
            last_seen_at: Set(None),
        }
        .insert(&self.database)
        .await
        .map_err(|error| match error.sql_err() {
            Some(SqlErr::UniqueConstraintViolation(_)) => InstallationStoreError::DuplicateKey,
            _ => InstallationStoreError::Database,
        })?;
        Installation::try_from(model)
    }

    pub async fn find_active(
        &self,
        id: Uuid,
    ) -> Result<Option<Installation>, InstallationStoreError> {
        let model = installation::Entity::find_by_id(id)
            .filter(installation::Column::Status.eq(InstallationStatus::Active))
            .one(&self.database)
            .await
            .map_err(|_| InstallationStoreError::Database)?;
        model.map(Installation::try_from).transpose()
    }

    pub async fn disable(&self, id: Uuid) -> Result<DisableOutcome, InstallationStoreError> {
        let now = Utc::now();
        let updated = installation::Entity::update_many()
            .col_expr(
                installation::Column::Status,
                Expr::value(InstallationStatus::Disabled),
            )
            .col_expr(installation::Column::UpdatedAt, Expr::value(now))
            .filter(installation::Column::Id.eq(id))
            .filter(installation::Column::Status.eq(InstallationStatus::Active))
            .exec(&self.database)
            .await
            .map_err(|_| InstallationStoreError::Database)?;
        if updated.rows_affected == 1 {
            return Ok(DisableOutcome::Disabled);
        }
        match installation::Entity::find_by_id(id)
            .one(&self.database)
            .await
            .map_err(|_| InstallationStoreError::Database)?
        {
            Some(model) if model.status == InstallationStatus::Disabled => {
                Ok(DisableOutcome::AlreadyDisabled)
            }
            Some(_) => Err(InstallationStoreError::InvalidStoredState),
            None => Ok(DisableOutcome::NotFound),
        }
    }

    pub async fn advance_counter(
        &self,
        id: Uuid,
        expected: u32,
        new_value: u32,
    ) -> Result<CounterAdvanceOutcome, InstallationStoreError> {
        if new_value <= expected {
            return Ok(CounterAdvanceOutcome::InvalidTransition);
        }
        let now = Utc::now();
        let updated = installation::Entity::update_many()
            .col_expr(
                installation::Column::SignCount,
                Expr::value(i64::from(new_value)),
            )
            .col_expr(installation::Column::UpdatedAt, Expr::value(now))
            .col_expr(installation::Column::LastSeenAt, Expr::value(now))
            .filter(installation::Column::Id.eq(id))
            .filter(installation::Column::Status.eq(InstallationStatus::Active))
            .filter(installation::Column::SignCount.eq(i64::from(expected)))
            .exec(&self.database)
            .await
            .map_err(|_| InstallationStoreError::Database)?;
        if updated.rows_affected == 1 {
            return Ok(CounterAdvanceOutcome::Advanced);
        }
        match installation::Entity::find_by_id(id)
            .one(&self.database)
            .await
            .map_err(|_| InstallationStoreError::Database)?
        {
            None => Ok(CounterAdvanceOutcome::NotFound),
            Some(model) if model.status == InstallationStatus::Disabled => {
                Ok(CounterAdvanceOutcome::Disabled)
            }
            Some(_) => Ok(CounterAdvanceOutcome::Conflict),
        }
    }
}

impl TryFrom<installation::Model> for Installation {
    type Error = InstallationStoreError;

    fn try_from(model: installation::Model) -> Result<Self, Self::Error> {
        Ok(Self {
            id: model.id,
            app_attest_key_id: model.app_attest_key_id,
            public_key: model.public_key,
            environment: model.environment,
            status: model.status,
            sign_count: u32::try_from(model.sign_count)
                .map_err(|_| InstallationStoreError::InvalidStoredState)?,
        })
    }
}
