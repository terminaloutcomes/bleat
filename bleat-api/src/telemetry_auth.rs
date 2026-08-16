use std::collections::BTreeMap;

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Utc};
use compact_jwt::{crypto::JwsEs256Signer, jwt::Jwt, traits::JwsSigner};
use p256::ecdsa::{Signature, VerifyingKey, signature::Verifier};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use url::Url;
use uuid::Uuid;

const CLIENT_DATA_DOMAIN: &str = "bleat-telemetry-auth/v1";
const TOKEN_AUDIENCE: &str = "bleat-telemetry";
const TOKEN_SCOPE: &str = "telemetry:write";

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

#[derive(Clone)]
pub struct DevelopmentTokenIssuer {
    issuer: String,
    token_lifetime: chrono::Duration,
    signer: JwsEs256Signer,
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
}

#[derive(Clone, Debug, Serialize)]
pub struct JwkSet {
    pub keys: Vec<compact_jwt::compact::Jwk>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct TelemetryClaims {
    scope: String,
    environment: String,
}

#[derive(Clone, Copy, Debug, Error, Eq, PartialEq)]
pub enum TokenIssuerError {
    #[error("token signing is unavailable")]
    Signing,
    #[error("token lifetime is invalid")]
    Lifetime,
}

impl DevelopmentTokenIssuer {
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
            signer,
        })
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
            nbf: Some(now.timestamp()),
            iat: Some(now.timestamp()),
            jti: Some(Uuid::new_v4().to_string()),
            extensions: TelemetryClaims {
                scope: TOKEN_SCOPE.to_owned(),
                environment: "development".to_owned(),
            },
            claims: BTreeMap::new(),
        };
        let access_token = self
            .signer
            .sign(&token)
            .map_err(|_| TokenIssuerError::Signing)?
            .to_string();
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
        }
    }

    pub fn jwks(&self) -> Result<JwkSet, TokenIssuerError> {
        let key = self
            .signer
            .public_key_as_jwk()
            .map_err(|_| TokenIssuerError::Signing)?;
        Ok(JwkSet { keys: vec![key] })
    }
}
