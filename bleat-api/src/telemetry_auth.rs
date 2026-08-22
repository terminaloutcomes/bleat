use std::{
    collections::{BTreeMap, HashSet},
    path::Path,
    str::FromStr,
    sync::Arc,
};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Utc};
use compact_jwt::{
    JwaAlg, Jwk, JwsEs256Signer, JwsEs256Verifier, JwsVerifier, JwtUnverified,
    compact::{EcCurve, JwkUse},
    jwt::Jwt,
    traits::{JwsSigner, JwsVerifiable},
};
use p256::ecdsa::{Signature, VerifyingKey, signature::Verifier};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use url::Url;
use uuid::Uuid;
use zeroize::Zeroize;

const CLIENT_DATA_DOMAIN: &str = "bleat-telemetry-auth/v1";
const TOKEN_AUDIENCE: &str = "bleat-telemetry";
const TOKEN_SCOPE: &str = "telemetry:write";
pub const TOKEN_CLOCK_SKEW_SECONDS: i64 = 30;
pub const JWKS_CACHE_SECONDS: u64 = 60;
const MAX_SIGNING_KEY_BYTES: u64 = 16_384;
const MAX_PUBLIC_KEY_SET_BYTES: u64 = 65_536;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ClientDataPurpose {
    AttestationEnroll,
    TokenIssue,
}

impl ClientDataPurpose {
    fn wire_value(self) -> &'static str {
        match self {
            Self::AttestationEnroll => "attestation_enroll",
            Self::TokenIssue => "token_issue",
        }
    }
}

pub fn client_data_hash(
    purpose: ClientDataPurpose,
    challenge_id: Uuid,
    challenge: &str,
    installation_id: Option<Uuid>,
) -> [u8; 32] {
    let installation = installation_id.map_or_else(String::new, |id| id.to_string());
    let canonical = format!(
        "{CLIENT_DATA_DOMAIN}\n{}\n{challenge_id}\n{challenge}\n{installation}",
        purpose.wire_value()
    );
    Sha256::digest(canonical.as_bytes()).into()
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DevelopmentAttestation {
    pub public_key: String,
    pub signature: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct DevelopmentAssertion {
    pub signature: String,
}

#[derive(Clone, Copy, Debug, Error, Eq, PartialEq)]
pub enum DevelopmentEvidenceError {
    #[error("development evidence is malformed")]
    Malformed,
    #[error("development evidence was rejected")]
    Rejected,
}

pub fn verify_development_attestation(
    key_id: &str,
    evidence: &str,
    client_data_hash: &[u8; 32],
) -> Result<Vec<u8>, DevelopmentEvidenceError> {
    let evidence: DevelopmentAttestation = decode_evidence(evidence)?;
    let public_key = URL_SAFE_NO_PAD
        .decode(evidence.public_key)
        .map_err(|_| DevelopmentEvidenceError::Malformed)?;
    if public_key.len() != 65 || public_key.first() != Some(&4) {
        return Err(DevelopmentEvidenceError::Malformed);
    }
    let expected_key_id = URL_SAFE_NO_PAD.encode(Sha256::digest(&public_key));
    if key_id != expected_key_id {
        return Err(DevelopmentEvidenceError::Rejected);
    }
    verify_signature(&public_key, &evidence.signature, client_data_hash)?;
    Ok(public_key)
}

pub fn verify_development_assertion(
    public_key: &[u8],
    evidence: &str,
    client_data_hash: &[u8; 32],
) -> Result<(), DevelopmentEvidenceError> {
    let evidence: DevelopmentAssertion = decode_evidence(evidence)?;
    verify_signature(public_key, &evidence.signature, client_data_hash)
}

fn decode_evidence<T: for<'de> Deserialize<'de>>(
    encoded: &str,
) -> Result<T, DevelopmentEvidenceError> {
    let bytes = URL_SAFE_NO_PAD
        .decode(encoded)
        .map_err(|_| DevelopmentEvidenceError::Malformed)?;
    if bytes.len() > 2_048 {
        return Err(DevelopmentEvidenceError::Malformed);
    }
    serde_json::from_slice(&bytes).map_err(|_| DevelopmentEvidenceError::Malformed)
}

fn verify_signature(
    public_key: &[u8],
    encoded_signature: &str,
    client_data_hash: &[u8; 32],
) -> Result<(), DevelopmentEvidenceError> {
    let verifying_key = VerifyingKey::from_sec1_bytes(public_key)
        .map_err(|_| DevelopmentEvidenceError::Malformed)?;
    let signature = URL_SAFE_NO_PAD
        .decode(encoded_signature)
        .map_err(|_| DevelopmentEvidenceError::Malformed)?;
    let signature =
        Signature::from_der(&signature).map_err(|_| DevelopmentEvidenceError::Malformed)?;
    verifying_key
        .verify(client_data_hash, &signature)
        .map_err(|_| DevelopmentEvidenceError::Rejected)
}

trait TokenSigning: Send + Sync {
    fn sign(&self, token: &Jwt<TelemetryClaims>) -> Result<String, TokenIssuerError>;
    fn public_jwk(&self) -> Result<Jwk, TokenIssuerError>;
}

#[derive(Clone)]
struct CompactJwtTokenSigner {
    signer: JwsEs256Signer,
}

impl TokenSigning for CompactJwtTokenSigner {
    fn sign(&self, token: &Jwt<TelemetryClaims>) -> Result<String, TokenIssuerError> {
        self.signer
            .sign(token)
            .map(|token| token.to_string())
            .map_err(|_| TokenIssuerError::Signing)
    }

    fn public_jwk(&self) -> Result<Jwk, TokenIssuerError> {
        self.signer
            .public_key_as_jwk()
            .map_err(|_| TokenIssuerError::Signing)
    }
}

#[derive(Clone)]
pub struct TokenIssuer {
    issuer: String,
    token_lifetime: chrono::Duration,
    signer: Arc<dyn TokenSigning>,
    scheduled_public_keys: Vec<ScheduledPublicKey>,
}

#[derive(Clone, Debug, Serialize)]
pub struct TokenResponse {
    pub access_token: String,
    pub token_type: &'static str,
    pub expires_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Serialize)]
pub struct OpenIdConfiguration {
    pub issuer: String,
    pub jwks_uri: String,
    pub token_endpoint: String,
    pub id_token_signing_alg_values_supported: [&'static str; 1],
}

#[derive(Clone, Debug, Serialize)]
pub struct JwkSet {
    pub keys: Vec<Jwk>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct TelemetryClaims {
    scope: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ScheduledPublicKeySet {
    keys: Vec<ScheduledPublicKey>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ScheduledPublicKey {
    jwk: Jwk,
    publish_from: DateTime<Utc>,
    publish_until: DateTime<Utc>,
}

#[derive(Clone, Copy, Debug, Error, Eq, PartialEq)]
pub enum TokenIssuerError {
    #[error("token signing is unavailable")]
    Signing,
    #[error("token lifetime is invalid")]
    Lifetime,
    #[error("token signing-key configuration is invalid")]
    SigningKeyConfiguration,
    #[error("token public-key rotation configuration is invalid")]
    PublicKeyConfiguration,
}

#[derive(Clone, Copy, Debug, Error, Eq, PartialEq)]
pub enum TokenValidationError {
    #[error("token is malformed")]
    Malformed,
    #[error("token signing algorithm is invalid")]
    Algorithm,
    #[error("token signing key is unknown")]
    UnknownKey,
    #[error("token signature is invalid")]
    Signature,
    #[error("token claims are invalid")]
    Claims,
    #[error("token has expired")]
    Expired,
}

impl TokenIssuer {
    pub fn generate(
        issuer: &Url,
        token_lifetime: std::time::Duration,
    ) -> Result<Self, TokenIssuerError> {
        let token_lifetime =
            chrono::Duration::from_std(token_lifetime).map_err(|_| TokenIssuerError::Lifetime)?;
        let signer = JwsEs256Signer::generate_es256().map_err(|_| TokenIssuerError::Signing)?;
        Ok(Self {
            issuer: issuer.as_str().trim_end_matches('/').to_owned(),
            token_lifetime,
            signer: Arc::new(CompactJwtTokenSigner { signer }),
            scheduled_public_keys: Vec::new(),
        })
    }

    pub fn from_files(
        issuer: &Url,
        token_lifetime: std::time::Duration,
        signing_key_file: &Path,
        public_key_set_file: Option<&Path>,
    ) -> Result<Self, TokenIssuerError> {
        let token_lifetime =
            chrono::Duration::from_std(token_lifetime).map_err(|_| TokenIssuerError::Lifetime)?;
        let mut signing_key = read_bounded_file(
            signing_key_file,
            MAX_SIGNING_KEY_BYTES,
            TokenIssuerError::SigningKeyConfiguration,
        )?;
        let signer = JwsEs256Signer::from_es256_der(&signing_key)
            .map_err(|_| TokenIssuerError::SigningKeyConfiguration);
        signing_key.zeroize();
        let signer = signer?;
        let scheduled_public_keys = match public_key_set_file {
            Some(path) => load_scheduled_public_keys(path, token_lifetime)?,
            None => Vec::new(),
        };
        let issuer = Self {
            issuer: issuer.as_str().trim_end_matches('/').to_owned(),
            token_lifetime,
            signer: Arc::new(CompactJwtTokenSigner { signer }),
            scheduled_public_keys,
        };
        issuer.validate_key_ids()?;
        Ok(issuer)
    }

    pub fn issue(
        &self,
        installation_id: Uuid,
        now: DateTime<Utc>,
    ) -> Result<TokenResponse, TokenIssuerError> {
        let expires_at = now + self.token_lifetime;
        let token = Jwt {
            iss: Some(self.issuer.clone()),
            sub: Some(installation_id.to_string()),
            aud: Some(TOKEN_AUDIENCE.to_owned()),
            exp: Some(expires_at.timestamp()),
            nbf: None,
            iat: Some(now.timestamp()),
            jti: None,
            extensions: TelemetryClaims {
                scope: TOKEN_SCOPE.to_owned(),
            },
            claims: BTreeMap::new(),
        };
        let access_token = self.signer.sign(&token)?;
        Ok(TokenResponse {
            access_token,
            token_type: "Bearer",
            expires_at,
        })
    }

    pub fn discovery(&self) -> OpenIdConfiguration {
        OpenIdConfiguration {
            issuer: self.issuer.clone(),
            jwks_uri: format!("{}/.well-known/jwks.json", self.issuer),
            token_endpoint: format!("{}/v1/token", self.issuer),
            id_token_signing_alg_values_supported: ["ES256"],
        }
    }

    pub fn jwks_at(&self, now: DateTime<Utc>) -> Result<JwkSet, TokenIssuerError> {
        let mut keys = vec![self.signer.public_jwk()?];
        keys.extend(
            self.scheduled_public_keys
                .iter()
                .filter(|key| key.publish_from <= now && now < key.publish_until)
                .map(|key| key.jwk.clone()),
        );
        Ok(JwkSet { keys })
    }

    pub fn validate(&self, token: &str, now: DateTime<Utc>) -> Result<Uuid, TokenValidationError> {
        validate_token(
            token,
            &self
                .jwks_at(now)
                .map_err(|_| TokenValidationError::UnknownKey)?,
            &self.issuer,
            self.token_lifetime,
            now,
        )
    }

    fn validate_key_ids(&self) -> Result<(), TokenIssuerError> {
        let active = self.signer.public_jwk()?;
        let active_kid = valid_public_key_id(&active)?;
        let mut key_ids = HashSet::from([active_kid.to_owned()]);
        for scheduled in &self.scheduled_public_keys {
            let kid = valid_public_key_id(&scheduled.jwk)?;
            if !key_ids.insert(kid.to_owned()) {
                return Err(TokenIssuerError::PublicKeyConfiguration);
            }
        }
        Ok(())
    }
}

pub fn validate_token(
    token: &str,
    jwks: &JwkSet,
    expected_issuer: &str,
    token_lifetime: chrono::Duration,
    now: DateTime<Utc>,
) -> Result<Uuid, TokenValidationError> {
    let unverified = JwtUnverified::<TelemetryClaims>::from_str(token)
        .map_err(|_| TokenValidationError::Malformed)?;
    if unverified.alg() != JwaAlg::ES256 {
        return Err(TokenValidationError::Algorithm);
    }
    let kid = unverified.kid().ok_or(TokenValidationError::UnknownKey)?;
    let jwk = jwks
        .keys
        .iter()
        .find(|jwk| jwk_key_id(jwk) == Some(kid))
        .ok_or(TokenValidationError::UnknownKey)?;
    valid_public_key_id(jwk).map_err(|_| TokenValidationError::UnknownKey)?;
    let verifier = JwsEs256Verifier::try_from(jwk).map_err(|_| TokenValidationError::UnknownKey)?;
    let verified = verifier
        .verify(&unverified)
        .map_err(|_| TokenValidationError::Signature)?;
    validate_claims(&verified, expected_issuer, token_lifetime, now)
}

fn validate_claims(
    token: &Jwt<TelemetryClaims>,
    expected_issuer: &str,
    token_lifetime: chrono::Duration,
    now: DateTime<Utc>,
) -> Result<Uuid, TokenValidationError> {
    if token.iss.as_deref() != Some(expected_issuer)
        || token.aud.as_deref() != Some(TOKEN_AUDIENCE)
        || token.extensions.scope != TOKEN_SCOPE
        || token.nbf.is_some()
        || token.jti.is_some()
        || !token.claims.is_empty()
    {
        return Err(TokenValidationError::Claims);
    }
    let subject = token
        .sub
        .as_deref()
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or(TokenValidationError::Claims)?;
    let issued_at = token.iat.ok_or(TokenValidationError::Claims)?;
    let expires_at = token.exp.ok_or(TokenValidationError::Claims)?;
    let actual_lifetime = expires_at
        .checked_sub(issued_at)
        .ok_or(TokenValidationError::Claims)?;
    if actual_lifetime != token_lifetime.num_seconds() || expires_at <= issued_at {
        return Err(TokenValidationError::Claims);
    }
    let now = now.timestamp();
    if expires_at <= now - TOKEN_CLOCK_SKEW_SECONDS {
        return Err(TokenValidationError::Expired);
    }
    if issued_at > now + TOKEN_CLOCK_SKEW_SECONDS
        || issued_at < now - token_lifetime.num_seconds() - TOKEN_CLOCK_SKEW_SECONDS
    {
        return Err(TokenValidationError::Claims);
    }
    Ok(subject)
}

fn read_bounded_file(
    path: &Path,
    maximum_bytes: u64,
    error: TokenIssuerError,
) -> Result<Vec<u8>, TokenIssuerError> {
    let metadata = std::fs::metadata(path).map_err(|_| error)?;
    if !metadata.is_file() || metadata.len() == 0 || metadata.len() > maximum_bytes {
        return Err(error);
    }
    let bytes = std::fs::read(path).map_err(|_| error)?;
    if bytes.is_empty() || bytes.len() as u64 > maximum_bytes {
        return Err(error);
    }
    Ok(bytes)
}

fn load_scheduled_public_keys(
    path: &Path,
    token_lifetime: chrono::Duration,
) -> Result<Vec<ScheduledPublicKey>, TokenIssuerError> {
    let bytes = read_bounded_file(
        path,
        MAX_PUBLIC_KEY_SET_BYTES,
        TokenIssuerError::PublicKeyConfiguration,
    )?;
    let raw: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|_| TokenIssuerError::PublicKeyConfiguration)?;
    if contains_private_key_material(&raw) {
        return Err(TokenIssuerError::PublicKeyConfiguration);
    }
    let key_set: ScheduledPublicKeySet =
        serde_json::from_value(raw).map_err(|_| TokenIssuerError::PublicKeyConfiguration)?;
    let minimum_overlap = token_lifetime + chrono::Duration::seconds(TOKEN_CLOCK_SKEW_SECONDS);
    for key in &key_set.keys {
        valid_public_key_id(&key.jwk)?;
        if key.publish_from >= key.publish_until
            || key.publish_until - key.publish_from < minimum_overlap
        {
            return Err(TokenIssuerError::PublicKeyConfiguration);
        }
    }
    Ok(key_set.keys)
}

fn contains_private_key_material(value: &serde_json::Value) -> bool {
    match value {
        serde_json::Value::Object(values) => {
            values.contains_key("d") || values.values().any(contains_private_key_material)
        }
        serde_json::Value::Array(values) => values.iter().any(contains_private_key_material),
        _ => false,
    }
}

fn valid_public_key_id(jwk: &Jwk) -> Result<&str, TokenIssuerError> {
    let kid = match jwk {
        Jwk::EC {
            crv: EcCurve::P256,
            alg: Some(JwaAlg::ES256),
            use_: Some(JwkUse::Sig),
            kid: Some(kid),
            ..
        } if !kid.trim().is_empty() && kid.len() <= 128 => kid,
        _ => return Err(TokenIssuerError::PublicKeyConfiguration),
    };
    JwsEs256Verifier::try_from(jwk).map_err(|_| TokenIssuerError::PublicKeyConfiguration)?;
    Ok(kid)
}

fn jwk_key_id(jwk: &Jwk) -> Option<&str> {
    match jwk {
        Jwk::EC { kid, .. } | Jwk::RSA { kid, .. } => kid.as_deref(),
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;

    struct TemporaryFile(PathBuf);

    impl TemporaryFile {
        fn write(name: &str, bytes: &[u8]) -> Self {
            let path = std::env::temp_dir().join(format!("bleat-{name}-{}", Uuid::new_v4()));
            std::fs::write(&path, bytes).expect("temporary test file should be written");
            Self(path)
        }
    }

    impl Drop for TemporaryFile {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }

    fn signer(seed: u8) -> JwsEs256Signer {
        let key = p256::SecretKey::from_slice(&[seed; 32]).expect("test key should be valid");
        let der = key
            .to_sec1_der()
            .expect("test key should encode as SEC1 DER");
        JwsEs256Signer::from_es256_der(der.as_ref()).expect("test signer should load")
    }

    fn issuer_with_signer(
        signer: JwsEs256Signer,
        scheduled: Vec<ScheduledPublicKey>,
    ) -> TokenIssuer {
        TokenIssuer {
            issuer: "https://telemetry.example".to_owned(),
            token_lifetime: chrono::Duration::minutes(10),
            signer: Arc::new(CompactJwtTokenSigner { signer }),
            scheduled_public_keys: scheduled,
        }
    }

    fn signed_token(
        signer: &JwsEs256Signer,
        issuer: &str,
        subject: &str,
        audience: &str,
        scope: &str,
        issued_at: DateTime<Utc>,
        expires_at: DateTime<Utc>,
    ) -> String {
        signer
            .sign(&Jwt {
                iss: Some(issuer.to_owned()),
                sub: Some(subject.to_owned()),
                aud: Some(audience.to_owned()),
                exp: Some(expires_at.timestamp()),
                nbf: None,
                iat: Some(issued_at.timestamp()),
                jti: None,
                extensions: TelemetryClaims {
                    scope: scope.to_owned(),
                },
                claims: BTreeMap::new(),
            })
            .expect("test token should sign")
            .to_string()
    }

    #[test]
    fn issued_token_contains_only_the_narrow_claims_and_validates() {
        let issuer = issuer_with_signer(signer(21), Vec::new());
        let now = DateTime::from_timestamp(2_000_000_000, 0).expect("test time should be valid");
        let installation_id = Uuid::new_v4();
        let response = issuer
            .issue(installation_id, now)
            .expect("token should issue");

        assert_eq!(response.token_type, "Bearer");
        assert_eq!(response.expires_at, now + chrono::Duration::minutes(10));
        assert_eq!(
            issuer
                .validate(&response.access_token, now)
                .expect("issued token should validate"),
            installation_id
        );

        let payload = response
            .access_token
            .split('.')
            .nth(1)
            .expect("token should contain a payload");
        let payload = URL_SAFE_NO_PAD
            .decode(payload)
            .expect("token payload should be base64url");
        let claims: serde_json::Value =
            serde_json::from_slice(&payload).expect("token claims should be JSON");
        let mut keys = claims
            .as_object()
            .expect("token claims should be an object")
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>();
        keys.sort_unstable();
        assert_eq!(keys, ["aud", "exp", "iat", "iss", "scope", "sub"]);

        let response = serde_json::to_value(response).expect("token response should encode");
        let mut response_keys = response
            .as_object()
            .expect("token response should be an object")
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>();
        response_keys.sort_unstable();
        assert_eq!(response_keys, ["access_token", "expires_at", "token_type"]);
        assert!(response.get("refresh_token").is_none());
    }

    #[test]
    fn strict_validation_rejects_wrong_claims_and_time() {
        let signer = signer(22);
        let issuer = issuer_with_signer(signer.clone(), Vec::new());
        let now = DateTime::from_timestamp(2_000_000_000, 0).expect("test time should be valid");
        let subject = Uuid::new_v4().to_string();
        let valid_expiry = now + chrono::Duration::minutes(10);

        for (token, expected) in [
            (
                signed_token(
                    &signer,
                    "https://wrong.example",
                    &subject,
                    TOKEN_AUDIENCE,
                    TOKEN_SCOPE,
                    now,
                    valid_expiry,
                ),
                TokenValidationError::Claims,
            ),
            (
                signed_token(
                    &signer,
                    "https://telemetry.example",
                    &subject,
                    "wrong-audience",
                    TOKEN_SCOPE,
                    now,
                    valid_expiry,
                ),
                TokenValidationError::Claims,
            ),
            (
                signed_token(
                    &signer,
                    "https://telemetry.example",
                    &subject,
                    TOKEN_AUDIENCE,
                    "wrong:scope",
                    now,
                    valid_expiry,
                ),
                TokenValidationError::Claims,
            ),
            (
                signed_token(
                    &signer,
                    "https://telemetry.example",
                    "not-an-installation",
                    TOKEN_AUDIENCE,
                    TOKEN_SCOPE,
                    now,
                    valid_expiry,
                ),
                TokenValidationError::Claims,
            ),
            (
                signed_token(
                    &signer,
                    "https://telemetry.example",
                    &subject,
                    TOKEN_AUDIENCE,
                    TOKEN_SCOPE,
                    now - chrono::Duration::minutes(11),
                    now - chrono::Duration::minutes(1),
                ),
                TokenValidationError::Expired,
            ),
            (
                signed_token(
                    &signer,
                    "https://telemetry.example",
                    &subject,
                    TOKEN_AUDIENCE,
                    TOKEN_SCOPE,
                    now + chrono::Duration::seconds(TOKEN_CLOCK_SKEW_SECONDS + 1),
                    now + chrono::Duration::minutes(10) + chrono::Duration::seconds(31),
                ),
                TokenValidationError::Claims,
            ),
        ] {
            assert_eq!(
                issuer
                    .validate(&token, now)
                    .expect_err("invalid token should be rejected"),
                expected
            );
        }
    }

    #[test]
    fn extreme_numeric_dates_are_rejected_without_overflow() {
        let signer = signer(30);
        let issuer = issuer_with_signer(signer.clone(), Vec::new());
        let token = signer
            .sign(&Jwt {
                iss: Some("https://telemetry.example".to_owned()),
                sub: Some(Uuid::new_v4().to_string()),
                aud: Some(TOKEN_AUDIENCE.to_owned()),
                exp: Some(i64::MAX),
                nbf: None,
                iat: Some(i64::MIN),
                jti: None,
                extensions: TelemetryClaims {
                    scope: TOKEN_SCOPE.to_owned(),
                },
                claims: BTreeMap::new(),
            })
            .expect("test token should sign")
            .to_string();

        assert_eq!(
            issuer
                .validate(&token, Utc::now())
                .expect_err("extreme dates should be rejected"),
            TokenValidationError::Claims
        );
    }

    #[test]
    fn wrong_signature_and_unknown_key_are_distinct() {
        let expected = issuer_with_signer(signer(23), Vec::new());
        let other = issuer_with_signer(signer(24), Vec::new());
        let now = Utc::now();
        let token = other
            .issue(Uuid::new_v4(), now)
            .expect("token should issue")
            .access_token;
        assert_eq!(
            expected
                .validate(&token, now)
                .expect_err("unknown key should fail"),
            TokenValidationError::UnknownKey
        );

        let expected_jwk = expected
            .jwks_at(now)
            .expect("JWKS should publish")
            .keys
            .into_iter()
            .next()
            .expect("active key should exist");
        let other_jwk = other
            .jwks_at(now)
            .expect("JWKS should publish")
            .keys
            .into_iter()
            .next()
            .expect("active key should exist");
        let other_kid = jwk_key_id(&other_jwk)
            .expect("key should have an ID")
            .to_owned();
        let forged_jwk = match expected_jwk {
            Jwk::EC {
                crv,
                x,
                y,
                alg,
                use_,
                ..
            } => Jwk::EC {
                crv,
                x,
                y,
                alg,
                use_,
                kid: Some(other_kid),
            },
            unexpected => {
                assert!(
                    matches!(unexpected, Jwk::EC { .. }),
                    "test key should be P-256"
                );
                return;
            }
        };
        assert_eq!(
            validate_token(
                &token,
                &JwkSet {
                    keys: vec![forged_jwk],
                },
                "https://telemetry.example",
                chrono::Duration::minutes(10),
                now,
            )
            .expect_err("wrong signature should fail"),
            TokenValidationError::Signature
        );
    }

    #[test]
    fn algorithm_substitution_and_additional_claims_are_rejected() {
        let signer = signer(29);
        let issuer = issuer_with_signer(signer.clone(), Vec::new());
        let now = Utc::now();
        let valid = issuer
            .issue(Uuid::new_v4(), now)
            .expect("token should issue")
            .access_token;
        let mut parts = valid.split('.').map(str::to_owned).collect::<Vec<_>>();
        let header = URL_SAFE_NO_PAD
            .decode(&parts[0])
            .expect("header should decode");
        let mut header: serde_json::Value =
            serde_json::from_slice(&header).expect("header should be JSON");
        header["alg"] = serde_json::json!("HS256");
        parts[0] = URL_SAFE_NO_PAD
            .encode(serde_json::to_vec(&header).expect("substituted header should encode"));
        let substituted = parts.join(".");
        assert_eq!(
            issuer
                .validate(&substituted, now)
                .expect_err("algorithm substitution should fail"),
            TokenValidationError::Algorithm
        );

        let mut claims = BTreeMap::new();
        claims.insert("server_url".to_owned(), serde_json::json!("forbidden"));
        let token = signer
            .sign(&Jwt {
                iss: Some("https://telemetry.example".to_owned()),
                sub: Some(Uuid::new_v4().to_string()),
                aud: Some(TOKEN_AUDIENCE.to_owned()),
                exp: Some((now + chrono::Duration::minutes(10)).timestamp()),
                nbf: None,
                iat: Some(now.timestamp()),
                jti: None,
                extensions: TelemetryClaims {
                    scope: TOKEN_SCOPE.to_owned(),
                },
                claims,
            })
            .expect("test token should sign")
            .to_string();
        assert_eq!(
            issuer
                .validate(&token, now)
                .expect_err("additional claims should fail"),
            TokenValidationError::Claims
        );
    }

    #[test]
    fn scheduled_keys_validate_only_during_the_overlap_window() {
        let active = signer(25);
        let retired = signer(26);
        let now = DateTime::from_timestamp(2_000_000_000, 0).expect("test time should be valid");
        let scheduled = ScheduledPublicKey {
            jwk: retired
                .public_key_as_jwk()
                .expect("retired public key should export"),
            publish_from: now - chrono::Duration::minutes(1),
            publish_until: now + chrono::Duration::minutes(11),
        };
        let issuer = issuer_with_signer(active, vec![scheduled]);
        let retired_token = issuer_with_signer(retired, Vec::new())
            .issue(Uuid::new_v4(), now)
            .expect("retired-key token should issue")
            .access_token;

        assert_eq!(
            issuer.jwks_at(now).expect("JWKS should publish").keys.len(),
            2
        );
        issuer
            .validate(&retired_token, now)
            .expect("overlap key should validate");
        assert_eq!(
            issuer
                .validate(&retired_token, now + chrono::Duration::minutes(12))
                .expect_err("retired key should disappear"),
            TokenValidationError::UnknownKey
        );
    }

    #[test]
    fn mounted_key_and_public_rotation_files_are_strict() {
        let active = signer(27);
        let active_der = active
            .private_key_to_der()
            .expect("active key should export");
        let active_file = TemporaryFile::write("jwt-active.der", &active_der);
        let overlap = signer(28)
            .public_key_as_jwk()
            .expect("overlap key should export");
        let now = Utc::now();
        let key_set = serde_json::json!({
            "keys": [{
                "jwk": overlap,
                "publish_from": now - chrono::Duration::minutes(1),
                "publish_until": now + chrono::Duration::minutes(11),
            }]
        });
        let key_set_file = TemporaryFile::write(
            "jwt-public.json",
            &serde_json::to_vec(&key_set).expect("key set should encode"),
        );
        let issuer = TokenIssuer::from_files(
            &Url::parse("https://telemetry.example").expect("issuer should parse"),
            std::time::Duration::from_secs(600),
            &active_file.0,
            Some(&key_set_file.0),
        )
        .expect("mounted keys should load");
        assert_eq!(
            issuer.jwks_at(now).expect("JWKS should publish").keys.len(),
            2
        );

        let mut private_key_set = key_set;
        private_key_set["keys"][0]["jwk"]["d"] = serde_json::json!("private-material");
        let private_file = TemporaryFile::write(
            "jwt-private.json",
            &serde_json::to_vec(&private_key_set).expect("private key set should encode"),
        );
        assert_eq!(
            TokenIssuer::from_files(
                &Url::parse("https://telemetry.example").expect("issuer should parse"),
                std::time::Duration::from_secs(600),
                &active_file.0,
                Some(&private_file.0),
            )
            .err()
            .expect("private JWKS material should be rejected"),
            TokenIssuerError::PublicKeyConfiguration
        );

        let invalid_key_file = TemporaryFile::write("jwt-invalid.der", b"not-a-private-key");
        assert_eq!(
            TokenIssuer::from_files(
                &Url::parse("https://telemetry.example").expect("issuer should parse"),
                std::time::Duration::from_secs(600),
                &invalid_key_file.0,
                None,
            )
            .err()
            .expect("invalid private key should be rejected"),
            TokenIssuerError::SigningKeyConfiguration
        );
    }

    #[test]
    fn retiring_key_remains_valid_during_the_final_overlap() {
        let active = signer(31);
        let active_der = active
            .private_key_to_der()
            .expect("active key should export");
        let active_file = TemporaryFile::write("jwt-restart-active.der", &active_der);
        let retired = signer(32)
            .public_key_as_jwk()
            .expect("retired public key should export");
        let now = Utc::now();
        let key_set = serde_json::json!({
            "keys": [{
                "jwk": retired,
                "publish_from": now - chrono::Duration::minutes(20),
                "publish_until": now + chrono::Duration::minutes(1),
            }]
        });
        let key_set_file = TemporaryFile::write(
            "jwt-restart-public.json",
            &serde_json::to_vec(&key_set).expect("key set should encode"),
        );

        let issuer = TokenIssuer::from_files(
            &Url::parse("https://telemetry.example").expect("issuer should parse"),
            std::time::Duration::from_secs(600),
            &active_file.0,
            Some(&key_set_file.0),
        )
        .expect("a retiring key should not prevent restart");
        assert_eq!(
            issuer.jwks_at(now).expect("JWKS should publish").keys.len(),
            2
        );
    }

    #[test]
    fn malformed_scheduled_public_key_is_rejected_at_startup() {
        let active = signer(33);
        let active_der = active
            .private_key_to_der()
            .expect("active key should export");
        let active_file = TemporaryFile::write("jwt-invalid-public-active.der", &active_der);
        let overlap = signer(34)
            .public_key_as_jwk()
            .expect("overlap public key should export");
        let now = Utc::now();
        let mut key_set = serde_json::json!({
            "keys": [{
                "jwk": overlap,
                "publish_from": now - chrono::Duration::minutes(1),
                "publish_until": now + chrono::Duration::minutes(11),
            }]
        });
        key_set["keys"][0]["jwk"]["x"] = serde_json::json!("AA");
        let key_set_file = TemporaryFile::write(
            "jwt-invalid-public.json",
            &serde_json::to_vec(&key_set).expect("key set should encode"),
        );

        assert_eq!(
            TokenIssuer::from_files(
                &Url::parse("https://telemetry.example").expect("issuer should parse"),
                std::time::Duration::from_secs(600),
                &active_file.0,
                Some(&key_set_file.0),
            )
            .err()
            .expect("malformed public coordinates should be rejected"),
            TokenIssuerError::PublicKeyConfiguration
        );
    }
}
