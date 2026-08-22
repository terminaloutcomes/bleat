use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use bleat_api::{
    challenge::{
        ChallengeConsumeOutcome, ChallengePurpose, ChallengeRepository, ChallengeStoreError,
        ExpectedChallenge,
    },
    config::DatabaseConfig,
    database::{Migrator, connect_and_migrate},
    installation::{
        CounterAdvanceOutcome, InstallationEnvironment, InstallationRepository, InstallationStatus,
        InstallationStoreError, NewInstallation,
    },
};
use chrono::{Duration as ChronoDuration, Utc};
use sea_orm::{ColumnTrait, DatabaseConnection, EntityTrait, QueryFilter};
use sea_orm_migration::{MigratorTrait, SchemaManager};
use sha2::{Digest, Sha256};
use uuid::Uuid;

static DATABASE_TEST_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

fn test_database() -> DatabaseConfig {
    DatabaseConfig::new(
        std::env::var("BLEAT_API_TEST_DATABASE_URL")
            .expect("BLEAT_API_TEST_DATABASE_URL must name the disposable PostgreSQL database"),
        4,
        std::time::Duration::from_secs(5),
    )
    .expect("test database configuration should be valid")
}

async fn database() -> DatabaseConnection {
    connect_and_migrate(&test_database())
        .await
        .expect("test database should connect")
}

async fn repository() -> InstallationRepository {
    InstallationRepository::new(database().await)
}

async fn challenge_repository() -> ChallengeRepository {
    ChallengeRepository::new(database().await, 100)
}

#[tokio::test]
async fn migrations_create_the_issue_64_schema_and_are_repeatable() {
    let _database_lock = DATABASE_TEST_LOCK.lock().await;
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
    let _database_lock = DATABASE_TEST_LOCK.lock().await;
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
    let _database_lock = DATABASE_TEST_LOCK.lock().await;
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

#[tokio::test]
async fn an_attested_key_can_only_enroll_once() {
    let _database_lock = DATABASE_TEST_LOCK.lock().await;
    let repository = repository().await;
    let installation = NewInstallation {
        app_attest_key_id: format!("duplicate-key-{}", Uuid::new_v4()),
        public_key: vec![4; 65],
        environment: InstallationEnvironment::Production,
    };
    repository
        .create_verified(installation.clone())
        .await
        .expect("first enrollment should persist");
    assert_eq!(
        repository
            .create_verified(installation)
            .await
            .expect_err("duplicate key enrollment should be rejected"),
        InstallationStoreError::DuplicateKey
    );
}

#[tokio::test]
async fn opaque_challenge_is_unique_and_only_its_digest_is_persisted() {
    let _database_lock = DATABASE_TEST_LOCK.lock().await;
    let database = database().await;
    let repository = ChallengeRepository::new(database.clone(), 100);
    let now = Utc::now();
    let first = repository
        .issue_attestation_at(std::time::Duration::from_secs(120), now)
        .await
        .expect("first challenge should issue");
    let second = repository
        .issue_attestation_at(std::time::Duration::from_secs(120), now)
        .await
        .expect("second challenge should issue");

    assert_ne!(first.challenge, second.challenge);
    let raw = URL_SAFE_NO_PAD
        .decode(&first.challenge)
        .expect("challenge should be unpadded base64url");
    assert_eq!(raw.len(), 32);
    let stored = bleat_api::entity::challenge::Entity::find_by_id(first.challenge_id)
        .one(&database)
        .await
        .expect("challenge lookup should succeed")
        .expect("challenge should persist");
    assert_ne!(stored.digest, raw);
    assert_eq!(stored.digest, Sha256::digest(&raw).to_vec());
}

#[tokio::test]
async fn challenge_consumption_is_purpose_bound_expiring_and_replay_safe() {
    let _database_lock = DATABASE_TEST_LOCK.lock().await;
    let repository = challenge_repository().await;
    let now = Utc::now();
    let challenge = repository
        .issue_attestation_at(std::time::Duration::from_secs(120), now)
        .await
        .expect("challenge should issue");
    let wrong_purpose = repository
        .consume_at(
            challenge.challenge_id,
            &challenge.challenge,
            ExpectedChallenge {
                purpose: ChallengePurpose::TokenIssue,
                installation_id: None,
            },
            now,
        )
        .await
        .expect("purpose mismatch should be typed");
    assert_eq!(wrong_purpose, ChallengeConsumeOutcome::WrongPurpose);

    let expected = ExpectedChallenge {
        purpose: ChallengePurpose::AttestationEnroll,
        installation_id: None,
    };
    assert_eq!(
        repository
            .consume_at(challenge.challenge_id, &challenge.challenge, expected, now,)
            .await
            .expect("first consumption should succeed"),
        ChallengeConsumeOutcome::Consumed
    );
    assert_eq!(
        repository
            .consume_at(challenge.challenge_id, &challenge.challenge, expected, now,)
            .await
            .expect("replay should be typed"),
        ChallengeConsumeOutcome::Replayed
    );

    let expired = repository
        .issue_attestation_at(std::time::Duration::from_secs(30), now)
        .await
        .expect("expiring challenge should issue");
    assert_eq!(
        repository
            .consume_at(
                expired.challenge_id,
                &expired.challenge,
                expected,
                now + ChronoDuration::seconds(31),
            )
            .await
            .expect("expiry should be typed"),
        ChallengeConsumeOutcome::Expired
    );
}

#[tokio::test]
async fn concurrent_challenge_consumption_has_exactly_one_winner() {
    let _database_lock = DATABASE_TEST_LOCK.lock().await;
    let repository = challenge_repository().await;
    let now = Utc::now();
    let challenge = repository
        .issue_attestation_at(std::time::Duration::from_secs(120), now)
        .await
        .expect("challenge should issue");
    let expected = ExpectedChallenge {
        purpose: ChallengePurpose::AttestationEnroll,
        installation_id: None,
    };

    let (first, second) = tokio::join!(
        repository.consume_at(challenge.challenge_id, &challenge.challenge, expected, now,),
        repository.consume_at(challenge.challenge_id, &challenge.challenge, expected, now,),
    );
    let outcomes = [
        first.expect("first consumer should have a typed outcome"),
        second.expect("second consumer should have a typed outcome"),
    ];
    assert_eq!(
        outcomes
            .iter()
            .filter(|outcome| **outcome == ChallengeConsumeOutcome::Consumed)
            .count(),
        1
    );
    assert_eq!(
        outcomes
            .iter()
            .filter(|outcome| **outcome == ChallengeConsumeOutcome::Replayed)
            .count(),
        1
    );
}

#[tokio::test]
async fn token_challenges_require_an_active_installation_binding() {
    let _database_lock = DATABASE_TEST_LOCK.lock().await;
    let database = database().await;
    let installations = InstallationRepository::new(database.clone());
    let challenges = ChallengeRepository::new(database, 100);
    let installation = installations
        .create_verified(NewInstallation {
            app_attest_key_id: format!("binding-key-{}", Uuid::new_v4()),
            public_key: vec![4; 65],
            environment: InstallationEnvironment::Development,
        })
        .await
        .expect("installation should persist");

    let issued = challenges
        .issue_token_at(
            installation.id,
            std::time::Duration::from_secs(120),
            Utc::now(),
        )
        .await
        .expect("active installation should receive a challenge");
    assert_eq!(issued.installation_id, Some(installation.id));
    assert_eq!(
        challenges
            .issue_token_at(
                Uuid::new_v4(),
                std::time::Duration::from_secs(120),
                Utc::now(),
            )
            .await
            .expect_err("unknown installation should be rejected"),
        ChallengeStoreError::AuthenticationRejected
    );
}

#[tokio::test]
async fn challenge_cleanup_removes_only_the_configured_expired_batch() {
    let _database_lock = DATABASE_TEST_LOCK.lock().await;
    let database = database().await;
    let challenges = ChallengeRepository::new(database.clone(), 1);
    bleat_api::entity::challenge::Entity::delete_many()
        .filter(bleat_api::entity::challenge::Column::ExpiresAt.lte(Utc::now()))
        .exec(&database)
        .await
        .expect("old test challenges should be cleared");
    let old_now = Utc::now() - ChronoDuration::minutes(10);
    let first = challenges
        .issue_attestation_at(std::time::Duration::from_secs(30), old_now)
        .await
        .expect("first expired challenge should persist");
    let second = challenges
        .issue_attestation_at(std::time::Duration::from_secs(30), old_now)
        .await
        .expect("second expired challenge should persist");

    challenges
        .issue_attestation_at(std::time::Duration::from_secs(120), Utc::now())
        .await
        .expect("new issuance should run bounded cleanup");

    let first_exists = bleat_api::entity::challenge::Entity::find_by_id(first.challenge_id)
        .one(&database)
        .await
        .expect("first lookup should succeed")
        .is_some();
    let second_exists = bleat_api::entity::challenge::Entity::find_by_id(second.challenge_id)
        .one(&database)
        .await
        .expect("second lookup should succeed")
        .is_some();
    assert_ne!(first_exists, second_exists);
}
