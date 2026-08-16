use std::time::Duration;

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Utc};
use sea_orm::{
    ActiveModelTrait, ActiveValue::Set, ColumnTrait, DatabaseConnection, EntityTrait, QueryFilter,
    QueryOrder, QuerySelect, sea_query::Expr,
};
use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;

use crate::entity::{challenge, installation};

pub use crate::entity::challenge::ChallengePurpose;
use crate::entity::installation::InstallationStatus;

const CHALLENGE_BYTES: usize = 32;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IssuedChallenge {
    pub challenge_id: Uuid,
    pub challenge: String,
    pub expires_at: DateTime<Utc>,
    pub installation_id: Option<Uuid>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ExpectedChallenge {
    pub purpose: ChallengePurpose,
    pub installation_id: Option<Uuid>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ChallengeConsumeOutcome {
    Consumed,
    Invalid,
    WrongPurpose,
    WrongBinding,
    Expired,
    Replayed,
}

#[derive(Clone, Copy, Debug, Error, Eq, PartialEq)]
pub enum ChallengeStoreError {
    #[error("challenge generation is temporarily unavailable")]
    RandomUnavailable,
    #[error("installation authentication was rejected")]
    AuthenticationRejected,
    #[error("challenge persistence is temporarily unavailable")]
    Database,
}

#[derive(Clone)]
pub struct ChallengeRepository {
    database: DatabaseConnection,
    cleanup_batch_size: u64,
}

impl ChallengeRepository {
    pub fn new(database: DatabaseConnection, cleanup_batch_size: u64) -> Self {
        Self {
            database,
            cleanup_batch_size,
        }
    }

    pub async fn issue_attestation_at(
        &self,
        lifetime: Duration,
        now: DateTime<Utc>,
    ) -> Result<IssuedChallenge, ChallengeStoreError> {
        self.issue_at(
            ExpectedChallenge {
                purpose: ChallengePurpose::AttestationEnroll,
                installation_id: None,
            },
            lifetime,
            now,
        )
        .await
    }

    pub async fn issue_token_at(
        &self,
        installation_id: Uuid,
        lifetime: Duration,
        now: DateTime<Utc>,
    ) -> Result<IssuedChallenge, ChallengeStoreError> {
        let active = installation::Entity::find_by_id(installation_id)
            .filter(installation::Column::Status.eq(InstallationStatus::Active))
            .one(&self.database)
            .await
            .map_err(|_| ChallengeStoreError::Database)?
            .is_some();
        if !active {
            return Err(ChallengeStoreError::AuthenticationRejected);
        }
        self.issue_at(
            ExpectedChallenge {
                purpose: ChallengePurpose::TokenIssue,
                installation_id: Some(installation_id),
            },
            lifetime,
            now,
        )
        .await
    }

    async fn issue_at(
        &self,
        expected: ExpectedChallenge,
        lifetime: Duration,
        now: DateTime<Utc>,
    ) -> Result<IssuedChallenge, ChallengeStoreError> {
        self.cleanup_expired(now).await?;
        let mut raw = [0_u8; CHALLENGE_BYTES];
        getrandom::fill(&mut raw).map_err(|_| ChallengeStoreError::RandomUnavailable)?;
        let challenge_id = Uuid::new_v4();
        let challenge = URL_SAFE_NO_PAD.encode(raw);
        let expires_at = now
            + chrono::Duration::from_std(lifetime).map_err(|_| ChallengeStoreError::Database)?;
        challenge::ActiveModel {
            id: Set(challenge_id),
            digest: Set(Sha256::digest(raw).to_vec()),
            purpose: Set(expected.purpose),
            installation_id: Set(expected.installation_id),
            expires_at: Set(expires_at),
            consumed_at: Set(None),
            created_at: Set(now),
        }
        .insert(&self.database)
        .await
        .map_err(|_| ChallengeStoreError::Database)?;
        Ok(IssuedChallenge {
            challenge_id,
            challenge,
            expires_at,
            installation_id: expected.installation_id,
        })
    }

    pub async fn consume_at(
        &self,
        challenge_id: Uuid,
        encoded_challenge: &str,
        expected: ExpectedChallenge,
        now: DateTime<Utc>,
    ) -> Result<ChallengeConsumeOutcome, ChallengeStoreError> {
        let raw = match URL_SAFE_NO_PAD.decode(encoded_challenge) {
            Ok(raw) if raw.len() == CHALLENGE_BYTES => raw,
            Ok(_) | Err(_) => return Ok(ChallengeConsumeOutcome::Invalid),
        };
        let digest = Sha256::digest(raw).to_vec();
        let mut update = challenge::Entity::update_many()
            .col_expr(challenge::Column::ConsumedAt, Expr::value(now))
            .filter(challenge::Column::Id.eq(challenge_id))
            .filter(challenge::Column::Digest.eq(digest.clone()))
            .filter(challenge::Column::Purpose.eq(expected.purpose))
            .filter(challenge::Column::ConsumedAt.is_null())
            .filter(challenge::Column::ExpiresAt.gt(now));
        update = match expected.installation_id {
            Some(installation_id) => {
                update.filter(challenge::Column::InstallationId.eq(installation_id))
            }
            None => update.filter(challenge::Column::InstallationId.is_null()),
        };
        let updated = update
            .exec(&self.database)
            .await
            .map_err(|_| ChallengeStoreError::Database)?;
        if updated.rows_affected == 1 {
            return Ok(ChallengeConsumeOutcome::Consumed);
        }

        let Some(stored) = challenge::Entity::find_by_id(challenge_id)
            .one(&self.database)
            .await
            .map_err(|_| ChallengeStoreError::Database)?
        else {
            return Ok(ChallengeConsumeOutcome::Invalid);
        };
        if stored.digest != digest {
            return Ok(ChallengeConsumeOutcome::Invalid);
        }
        if stored.purpose != expected.purpose {
            return Ok(ChallengeConsumeOutcome::WrongPurpose);
        }
        if stored.installation_id != expected.installation_id {
            return Ok(ChallengeConsumeOutcome::WrongBinding);
        }
        if stored.consumed_at.is_some() {
            return Ok(ChallengeConsumeOutcome::Replayed);
        }
        if stored.expires_at <= now {
            return Ok(ChallengeConsumeOutcome::Expired);
        }
        Ok(ChallengeConsumeOutcome::Invalid)
    }

    async fn cleanup_expired(&self, now: DateTime<Utc>) -> Result<(), ChallengeStoreError> {
        let expired_ids = challenge::Entity::find()
            .select_only()
            .column(challenge::Column::Id)
            .filter(challenge::Column::ExpiresAt.lte(now))
            .order_by_asc(challenge::Column::ExpiresAt)
            .limit(self.cleanup_batch_size)
            .into_tuple::<Uuid>()
            .all(&self.database)
            .await
            .map_err(|_| ChallengeStoreError::Database)?;
        if expired_ids.is_empty() {
            return Ok(());
        }
        challenge::Entity::delete_many()
            .filter(challenge::Column::Id.is_in(expired_ids))
            .exec(&self.database)
            .await
            .map_err(|_| ChallengeStoreError::Database)?;
        Ok(())
    }
}
