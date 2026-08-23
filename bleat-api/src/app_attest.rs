use std::{
    collections::{BTreeMap, BTreeSet},
    io::Cursor,
};

use base64::{
    Engine as _,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use ciborium::Value;
use p256::ecdsa::{Signature, VerifyingKey, signature::Verifier};
use rustls_pki_types::{CertificateDer, SignatureVerificationAlgorithm, UnixTime};
use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;
use webpki::{
    EndEntityCert, ExtendedKeyUsageValidator, KeyPurposeIdIter, anchor_from_trusted_cert,
};
use x509_parser::{
    asn1_rs::{Class, Tag, oid},
    der_parser::der::parse_der,
    parse_x509_certificate,
};

use crate::{
    config::AppAttestEnvironment,
    installation::InstallationEnvironment,
    telemetry_auth::{
        DevelopmentEvidenceError, verify_development_assertion, verify_development_attestation,
    },
};

const APPLE_ROOT_PEM: &[u8] = include_bytes!("../trust/Apple_App_Attestation_Root_CA.pem");
const APPLE_ROOT_SHA256: [u8; 32] = [
    0x1c, 0xb9, 0x82, 0x3b, 0xa2, 0x8b, 0xa6, 0xad, 0x2d, 0x33, 0xa0, 0x06, 0x94, 0x1d, 0xe2, 0xae,
    0x4f, 0x51, 0x3e, 0xf1, 0xd4, 0xe8, 0x31, 0xb9, 0xf7, 0xe0, 0xfa, 0x7b, 0x62, 0x42, 0xc9, 0x32,
];
const APPLE_NONCE_EXTENSION_OID: x509_parser::oid_registry::Oid<'static> =
    oid!(1.2.840.113635.100.8.2);
const MAX_ENCODED_EVIDENCE_BYTES: usize = 65_536;
const MAX_DECODED_ATTESTATION_BYTES: usize = 48 * 1_024;
const MAX_DECODED_ASSERTION_BYTES: usize = 16 * 1_024;
const MAX_AUTHENTICATOR_DATA_BYTES: usize = 4 * 1_024;
const MAX_CERTIFICATE_BYTES: usize = 8 * 1_024;
const MAX_RECEIPT_BYTES: usize = 16 * 1_024;
const ASSERTION_AUTHENTICATOR_DATA_BYTES: usize = 37;
const ATTESTATION_CREDENTIAL_ID_OFFSET: usize = 55;
const APP_ATTEST_KEY_ID_BYTES: usize = 32;
const COSE_P256_PUBLIC_KEY_BYTES: usize = 65;
const MAX_BUNDLE_VERSION_BYTES: usize = 64;
const APP_ATTEST_AUTHENTICATOR_FLAG: u8 = 0x40;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AppAttestFailureCategory {
    MalformedEvidence,
    OversizedEvidence,
    InvalidChain,
    InvalidNonce,
    WrongApplication,
    WrongEnvironment,
    InvalidCredential,
    InvalidSignature,
    InvalidCounter,
    AssertionReplay,
    InvalidTrustAnchor,
}

impl AppAttestFailureCategory {
    pub const fn metric_name(self) -> &'static str {
        match self {
            Self::MalformedEvidence => "attestation.malformed_evidence",
            Self::OversizedEvidence => "attestation.oversized_evidence",
            Self::InvalidChain => "attestation.invalid_chain",
            Self::InvalidNonce => "attestation.invalid_nonce",
            Self::WrongApplication => "attestation.wrong_application",
            Self::WrongEnvironment => "attestation.wrong_environment",
            Self::InvalidCredential => "attestation.invalid_credential",
            Self::InvalidSignature => "assertion.invalid_signature",
            Self::InvalidCounter => "attestation.invalid_counter",
            Self::AssertionReplay => "assertion.replay",
            Self::InvalidTrustAnchor => "attestation.invalid_trust_anchor",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AppAttestVerificationStage {
    Verification,
    EvidenceDecoding,
    AttestationEnvelope,
    AttestationFormat,
    AttestationStatement,
    AttestationReceipt,
    AttestationCertificates,
    AttestationAuthenticatorLength,
    AttestationAuthenticatorFlags,
    AttestationEnvironment,
    AttestationCredential,
    AttestationCounter,
    AttestationCoseKey,
    AttestationExtensions,
    AttestationCertificateChain,
    AttestationNonceExtension,
    AttestationNonce,
    AttestationApplication,
    AttestationPolicy,
    AssertionEnvelope,
    AssertionSignature,
    AssertionAuthenticatorLength,
    AssertionAuthenticatorFlags,
    AssertionEnvironment,
    AssertionExtensions,
    AssertionApplication,
    AssertionCounter,
    AssertionSignatureVerification,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AppAttestFailureDetail {
    Unspecified,
    AssertionFlagsUnexpectedValue,
    ExtensionsCbor,
    ExtensionsTrailingData,
    ExtensionsNotMap,
    ExtensionsFieldCount,
    ExtensionsKeyType,
    ExtensionsUnknownKey,
    ExtensionsDuplicateKey,
    ValidationCategoryMissing,
    ValidationCategoryType,
    ValidationCategoryLength,
    BundleVersionMissing,
    BundleVersionType,
    BundleVersionLength,
}

impl AppAttestFailureDetail {
    pub const fn metric_name(self) -> &'static str {
        match self {
            Self::Unspecified => "unspecified",
            Self::AssertionFlagsUnexpectedValue => "assertion.flags.unexpected_value",
            Self::ExtensionsCbor => "extensions.cbor",
            Self::ExtensionsTrailingData => "extensions.trailing_data",
            Self::ExtensionsNotMap => "extensions.not_map",
            Self::ExtensionsFieldCount => "extensions.field_count",
            Self::ExtensionsKeyType => "extensions.key_type",
            Self::ExtensionsUnknownKey => "extensions.unknown_key",
            Self::ExtensionsDuplicateKey => "extensions.duplicate_key",
            Self::ValidationCategoryMissing => "extensions.validation_category.missing",
            Self::ValidationCategoryType => "extensions.validation_category.type",
            Self::ValidationCategoryLength => "extensions.validation_category.length",
            Self::BundleVersionMissing => "extensions.bundle_version.missing",
            Self::BundleVersionType => "extensions.bundle_version.type",
            Self::BundleVersionLength => "extensions.bundle_version.length",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CborValueKind {
    Integer,
    Bytes,
    Float,
    Text,
    Bool,
    Null,
    Tag,
    Array,
    Map,
    Other,
}

impl From<&Value> for CborValueKind {
    fn from(value: &Value) -> Self {
        match value {
            Value::Integer(_) => CborValueKind::Integer,
            Value::Bytes(_) => CborValueKind::Bytes,
            Value::Float(_) => CborValueKind::Float,
            Value::Text(_) => CborValueKind::Text,
            Value::Bool(_) => CborValueKind::Bool,
            Value::Null => CborValueKind::Null,
            Value::Tag(_, _) => CborValueKind::Tag,
            Value::Array(_) => CborValueKind::Array,
            Value::Map(_) => CborValueKind::Map,
            _ => CborValueKind::Other,
        }
    }
}

impl CborValueKind {
    pub const fn metric_name(self) -> &'static str {
        match self {
            Self::Integer => "integer",
            Self::Bytes => "bytes",
            Self::Float => "float",
            Self::Text => "text",
            Self::Bool => "bool",
            Self::Null => "null",
            Self::Tag => "tag",
            Self::Array => "array",
            Self::Map => "map",
            Self::Other => "other",
        }
    }
}

impl AppAttestVerificationStage {
    pub const fn metric_name(self) -> &'static str {
        match self {
            Self::Verification => "verification",
            Self::EvidenceDecoding => "evidence.decoding",
            Self::AttestationEnvelope => "attestation.envelope",
            Self::AttestationFormat => "attestation.format",
            Self::AttestationStatement => "attestation.statement",
            Self::AttestationReceipt => "attestation.receipt",
            Self::AttestationCertificates => "attestation.certificates",
            Self::AttestationAuthenticatorLength => "attestation.authenticator.length",
            Self::AttestationAuthenticatorFlags => "attestation.authenticator.flags",
            Self::AttestationEnvironment => "attestation.environment",
            Self::AttestationCredential => "attestation.credential",
            Self::AttestationCounter => "attestation.counter",
            Self::AttestationCoseKey => "attestation.cose_key",
            Self::AttestationExtensions => "attestation.extensions",
            Self::AttestationCertificateChain => "attestation.certificate_chain",
            Self::AttestationNonceExtension => "attestation.nonce_extension",
            Self::AttestationNonce => "attestation.nonce",
            Self::AttestationApplication => "attestation.application",
            Self::AttestationPolicy => "attestation.policy",
            Self::AssertionEnvelope => "assertion.envelope",
            Self::AssertionSignature => "assertion.signature",
            Self::AssertionAuthenticatorLength => "assertion.authenticator.length",
            Self::AssertionAuthenticatorFlags => "assertion.authenticator.flags",
            Self::AssertionEnvironment => "assertion.environment",
            Self::AssertionExtensions => "assertion.extensions",
            Self::AssertionApplication => "assertion.application",
            Self::AssertionCounter => "assertion.counter",
            Self::AssertionSignatureVerification => "assertion.signature_verification",
        }
    }
}

#[derive(Clone, Copy, Debug, Error, Eq, PartialEq)]
#[error("App Attest evidence was rejected")]
pub struct AppAttestVerificationError {
    category: AppAttestFailureCategory,
    stage: AppAttestVerificationStage,
    detail: AppAttestFailureDetail,
    observed_type: Option<CborValueKind>,
    observed_length: Option<usize>,
    observed_count: Option<usize>,
    observed_flags: Option<u8>,
}

impl AppAttestVerificationError {
    const fn new(category: AppAttestFailureCategory) -> Self {
        Self {
            category,
            stage: AppAttestVerificationStage::Verification,
            detail: AppAttestFailureDetail::Unspecified,
            observed_type: None,
            observed_length: None,
            observed_count: None,
            observed_flags: None,
        }
    }

    const fn with_stage(self, stage: AppAttestVerificationStage) -> Self {
        Self {
            stage: if matches!(self.stage, AppAttestVerificationStage::Verification) {
                stage
            } else {
                self.stage
            },
            ..self
        }
    }

    const fn with_detail(self, detail: AppAttestFailureDetail) -> Self {
        Self { detail, ..self }
    }

    const fn with_observed_type(self, observed_type: CborValueKind) -> Self {
        Self {
            observed_type: Some(observed_type),
            ..self
        }
    }

    const fn with_observed_length(self, observed_length: usize) -> Self {
        Self {
            observed_length: Some(observed_length),
            ..self
        }
    }

    const fn with_observed_count(self, observed_count: usize) -> Self {
        Self {
            observed_count: Some(observed_count),
            ..self
        }
    }

    const fn with_observed_flags(self, observed_flags: u8) -> Self {
        Self {
            observed_flags: Some(observed_flags),
            ..self
        }
    }

    pub const fn category(self) -> AppAttestFailureCategory {
        self.category
    }

    pub const fn stage(self) -> AppAttestVerificationStage {
        self.stage
    }

    pub const fn detail(self) -> AppAttestFailureDetail {
        self.detail
    }

    pub const fn observed_type(self) -> Option<CborValueKind> {
        self.observed_type
    }

    pub const fn observed_length(self) -> Option<usize> {
        self.observed_length
    }

    pub const fn observed_count(self) -> Option<usize> {
        self.observed_count
    }

    pub const fn observed_flags(self) -> Option<u8> {
        self.observed_flags
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VerifiedAttestation {
    pub public_key: Vec<u8>,
    pub environment: InstallationEnvironment,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct VerifiedAssertion {
    pub counter: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AuthenticatedInstallationPrincipal {
    pub installation_id: Uuid,
    pub environment: InstallationEnvironment,
}

#[derive(Clone)]
pub struct AppAttestPolicy {
    bundle_versions: BTreeSet<String>,
    validation_categories: BTreeSet<u32>,
}

impl AppAttestPolicy {
    pub fn new(
        bundle_versions: impl IntoIterator<Item = String>,
        validation_categories: impl IntoIterator<Item = u32>,
    ) -> Result<Self, AppAttestVerificationError> {
        let bundle_versions = bundle_versions
            .into_iter()
            .map(|value| value.trim().to_owned())
            .collect::<BTreeSet<_>>();
        let validation_categories = validation_categories.into_iter().collect::<BTreeSet<_>>();
        if bundle_versions.is_empty()
            || bundle_versions
                .iter()
                .any(|value| value.is_empty() || value.len() > MAX_BUNDLE_VERSION_BYTES)
            || validation_categories.is_empty()
            || validation_categories
                .iter()
                .any(|value| !matches!(value, 1..=6 | 10))
        {
            return Err(AppAttestVerificationError::new(
                AppAttestFailureCategory::WrongApplication,
            ));
        }
        Ok(Self {
            bundle_versions,
            validation_categories,
        })
    }

    fn accepts(&self, claims: Option<&AppAttestClaims>) -> bool {
        let Some(claims) = claims else {
            return true;
        };
        self.bundle_versions.contains(&claims.bundle_version)
            && self
                .validation_categories
                .contains(&claims.validation_category)
    }
}

#[derive(Clone)]
pub enum InstallationEvidenceVerifier {
    Development,
    Production(ProductionAppAttestVerifier),
}

impl InstallationEvidenceVerifier {
    pub fn production(
        team_id: &str,
        app_identifier: &str,
        environment: AppAttestEnvironment,
        policy: AppAttestPolicy,
    ) -> Result<Self, AppAttestVerificationError> {
        ProductionAppAttestVerifier::with_embedded_apple_root(
            team_id,
            app_identifier,
            environment,
            policy,
        )
        .map(Self::Production)
    }

    pub fn verify_attestation(
        &self,
        key_id: &str,
        evidence: &str,
        client_data_hash: &[u8; 32],
    ) -> Result<VerifiedAttestation, AppAttestVerificationError> {
        match self {
            Self::Development => verify_development_attestation(key_id, evidence, client_data_hash)
                .map(|public_key| VerifiedAttestation {
                    public_key,
                    environment: InstallationEnvironment::Development,
                })
                .map_err(map_development_error),
            Self::Production(verifier) => {
                verifier.verify_attestation(key_id, evidence, client_data_hash)
            }
        }
    }

    pub fn verify_assertion(
        &self,
        public_key: &[u8],
        installation_environment: InstallationEnvironment,
        evidence: &str,
        client_data_hash: &[u8; 32],
        previous_counter: u32,
    ) -> Result<VerifiedAssertion, AppAttestVerificationError> {
        match self {
            Self::Development => {
                if installation_environment != InstallationEnvironment::Development {
                    return Err(AppAttestVerificationError::new(
                        AppAttestFailureCategory::WrongEnvironment,
                    ));
                }
                verify_development_assertion(public_key, evidence, client_data_hash)
                    .map_err(map_development_error)?;
                let counter = previous_counter.checked_add(1).ok_or_else(|| {
                    AppAttestVerificationError::new(AppAttestFailureCategory::InvalidCounter)
                })?;
                Ok(VerifiedAssertion { counter })
            }
            Self::Production(verifier) => verifier.verify_assertion(
                public_key,
                installation_environment,
                evidence,
                client_data_hash,
                previous_counter,
            ),
        }
    }
}

fn map_development_error(error: DevelopmentEvidenceError) -> AppAttestVerificationError {
    match error {
        DevelopmentEvidenceError::Malformed => {
            AppAttestVerificationError::new(AppAttestFailureCategory::MalformedEvidence)
        }
        DevelopmentEvidenceError::Rejected => {
            AppAttestVerificationError::new(AppAttestFailureCategory::InvalidSignature)
        }
    }
}

#[derive(Clone)]
pub struct ProductionAppAttestVerifier {
    app_id: String,
    environment: InstallationEnvironment,
    policy: AppAttestPolicy,
    trust_anchor: CertificateDer<'static>,
}

impl ProductionAppAttestVerifier {
    fn with_embedded_apple_root(
        team_id: &str,
        app_identifier: &str,
        environment: AppAttestEnvironment,
        policy: AppAttestPolicy,
    ) -> Result<Self, AppAttestVerificationError> {
        let trust_anchor = parse_single_pem_certificate(APPLE_ROOT_PEM)?;
        let digest: [u8; 32] = Sha256::digest(trust_anchor.as_ref()).into();
        if digest != APPLE_ROOT_SHA256 {
            return Err(AppAttestVerificationError::new(
                AppAttestFailureCategory::InvalidTrustAnchor,
            ));
        }
        Self::new(team_id, app_identifier, environment, policy, trust_anchor)
    }

    pub fn new(
        team_id: &str,
        app_identifier: &str,
        environment: AppAttestEnvironment,
        policy: AppAttestPolicy,
        trust_anchor: CertificateDer<'static>,
    ) -> Result<Self, AppAttestVerificationError> {
        if team_id.trim().is_empty() || app_identifier.trim().is_empty() {
            return Err(AppAttestVerificationError::new(
                AppAttestFailureCategory::WrongApplication,
            ));
        }
        anchor_from_trusted_cert(&trust_anchor).map_err(|_| {
            AppAttestVerificationError::new(AppAttestFailureCategory::InvalidTrustAnchor)
        })?;
        Ok(Self {
            app_id: format!("{}.{}", team_id.trim(), app_identifier.trim()),
            environment: match environment {
                AppAttestEnvironment::Development => InstallationEnvironment::Development,
                AppAttestEnvironment::Production => InstallationEnvironment::Production,
            },
            policy,
            trust_anchor,
        })
    }

    pub fn verify_attestation(
        &self,
        key_id: &str,
        evidence: &str,
        client_data_hash: &[u8; 32],
    ) -> Result<VerifiedAttestation, AppAttestVerificationError> {
        let decoded = decode_evidence(evidence, MAX_DECODED_ATTESTATION_BYTES)?;
        let parsed = ParsedAttestation::parse(&decoded)?;
        verify_certificate_chain(&parsed.certificates, &self.trust_anchor).map_err(|error| {
            error.with_stage(AppAttestVerificationStage::AttestationCertificateChain)
        })?;

        let authenticator = AttestationAuthenticatorData::parse(&parsed.authenticator_data)?;
        let expected_app_hash: [u8; 32] = Sha256::digest(self.app_id.as_bytes()).into();
        if authenticator.rp_id_hash != expected_app_hash {
            return Err(AppAttestVerificationError::new(
                AppAttestFailureCategory::WrongApplication,
            )
            .with_stage(AppAttestVerificationStage::AttestationApplication));
        }
        if authenticator.counter != 0 {
            return Err(
                AppAttestVerificationError::new(AppAttestFailureCategory::InvalidCounter)
                    .with_stage(AppAttestVerificationStage::AttestationCounter),
            );
        }
        if authenticator.environment != self.environment {
            return Err(AppAttestVerificationError::new(
                AppAttestFailureCategory::WrongEnvironment,
            )
            .with_stage(AppAttestVerificationStage::AttestationEnvironment));
        }
        if !self.policy.accepts(authenticator.claims.as_ref()) {
            return Err(AppAttestVerificationError::new(
                AppAttestFailureCategory::WrongApplication,
            )
            .with_stage(AppAttestVerificationStage::AttestationPolicy));
        }

        let decoded_key_id = STANDARD.decode(key_id).map_err(|_| {
            AppAttestVerificationError::new(AppAttestFailureCategory::InvalidCredential)
                .with_stage(AppAttestVerificationStage::AttestationCredential)
        })?;
        if decoded_key_id.len() != APP_ATTEST_KEY_ID_BYTES
            || authenticator.credential_id != decoded_key_id
        {
            return Err(AppAttestVerificationError::new(
                AppAttestFailureCategory::InvalidCredential,
            )
            .with_stage(AppAttestVerificationStage::AttestationCredential));
        }

        let leaf = parsed.certificates.first().ok_or_else(|| {
            AppAttestVerificationError::new(AppAttestFailureCategory::InvalidChain)
        })?;
        let (remaining, certificate) = parse_x509_certificate(leaf)
            .map_err(|_| AppAttestVerificationError::new(AppAttestFailureCategory::InvalidChain))?;
        if !remaining.is_empty() {
            return Err(AppAttestVerificationError::new(
                AppAttestFailureCategory::InvalidChain,
            ));
        }
        let public_key = certificate.public_key().subject_public_key.data.as_ref();
        VerifyingKey::from_sec1_bytes(public_key).map_err(|_| {
            AppAttestVerificationError::new(AppAttestFailureCategory::InvalidCredential)
        })?;
        if Sha256::digest(public_key).as_slice() != decoded_key_id {
            return Err(AppAttestVerificationError::new(
                AppAttestFailureCategory::InvalidCredential,
            ));
        }
        if authenticator.encoded_public_key.as_slice() != public_key {
            return Err(AppAttestVerificationError::new(
                AppAttestFailureCategory::InvalidCredential,
            ));
        }

        let certificate_nonce = extract_certificate_nonce(&certificate).map_err(|error| {
            error.with_stage(AppAttestVerificationStage::AttestationNonceExtension)
        })?;
        let mut nonce_input = Vec::with_capacity(parsed.authenticator_data.len() + 32);
        nonce_input.extend_from_slice(&parsed.authenticator_data);
        nonce_input.extend_from_slice(client_data_hash);
        let expected_nonce: [u8; 32] = Sha256::digest(nonce_input).into();
        if certificate_nonce != expected_nonce {
            return Err(
                AppAttestVerificationError::new(AppAttestFailureCategory::InvalidNonce)
                    .with_stage(AppAttestVerificationStage::AttestationNonce),
            );
        }

        Ok(VerifiedAttestation {
            public_key: public_key.to_vec(),
            environment: self.environment,
        })
    }

    pub fn verify_assertion(
        &self,
        public_key: &[u8],
        installation_environment: InstallationEnvironment,
        evidence: &str,
        client_data_hash: &[u8; 32],
        previous_counter: u32,
    ) -> Result<VerifiedAssertion, AppAttestVerificationError> {
        if installation_environment != self.environment {
            return Err(AppAttestVerificationError::new(
                AppAttestFailureCategory::WrongEnvironment,
            )
            .with_stage(AppAttestVerificationStage::AssertionEnvironment));
        }
        let decoded = decode_evidence(evidence, MAX_DECODED_ASSERTION_BYTES)?;
        let parsed = ParsedAssertion::parse(&decoded)?;
        let authenticator = AssertionAuthenticatorData::parse(&parsed.authenticator_data)?;
        let expected_app_hash: [u8; 32] = Sha256::digest(self.app_id.as_bytes()).into();
        if authenticator.rp_id_hash != expected_app_hash {
            return Err(AppAttestVerificationError::new(
                AppAttestFailureCategory::WrongApplication,
            )
            .with_stage(AppAttestVerificationStage::AssertionApplication));
        }
        if authenticator.counter == 0 || authenticator.counter <= previous_counter {
            return Err(
                AppAttestVerificationError::new(AppAttestFailureCategory::AssertionReplay)
                    .with_stage(AppAttestVerificationStage::AssertionCounter),
            );
        }
        if !self.policy.accepts(authenticator.claims.as_ref()) {
            return Err(AppAttestVerificationError::new(
                AppAttestFailureCategory::WrongApplication,
            )
            .with_stage(AppAttestVerificationStage::AssertionExtensions));
        }

        let key = VerifyingKey::from_sec1_bytes(public_key).map_err(|_| {
            AppAttestVerificationError::new(AppAttestFailureCategory::InvalidCredential)
        })?;
        let signature = Signature::from_der(&parsed.signature).map_err(|_| {
            AppAttestVerificationError::new(AppAttestFailureCategory::MalformedEvidence)
                .with_stage(AppAttestVerificationStage::AssertionSignature)
        })?;
        let mut nonce_input = Vec::with_capacity(parsed.authenticator_data.len() + 32);
        nonce_input.extend_from_slice(&parsed.authenticator_data);
        nonce_input.extend_from_slice(client_data_hash);
        let nonce = Sha256::digest(nonce_input);
        key.verify(&nonce, &signature).map_err(|_| {
            AppAttestVerificationError::new(AppAttestFailureCategory::InvalidSignature)
                .with_stage(AppAttestVerificationStage::AssertionSignatureVerification)
        })?;
        Ok(VerifiedAssertion {
            counter: authenticator.counter,
        })
    }
}

fn parse_single_pem_certificate(
    pem: &[u8],
) -> Result<CertificateDer<'static>, AppAttestVerificationError> {
    let mut reader = Cursor::new(pem);
    let mut certificates = rustls_pemfile::certs(&mut reader);
    let certificate = certificates.next().transpose().map_err(|_| {
        AppAttestVerificationError::new(AppAttestFailureCategory::InvalidTrustAnchor)
    })?;
    if certificate.is_none() || certificates.next().is_some() {
        return Err(AppAttestVerificationError::new(
            AppAttestFailureCategory::InvalidTrustAnchor,
        ));
    }
    certificate.ok_or_else(|| {
        AppAttestVerificationError::new(AppAttestFailureCategory::InvalidTrustAnchor)
    })
}

fn decode_evidence(
    encoded: &str,
    maximum_decoded: usize,
) -> Result<Vec<u8>, AppAttestVerificationError> {
    if encoded.len() > MAX_ENCODED_EVIDENCE_BYTES {
        return Err(
            AppAttestVerificationError::new(AppAttestFailureCategory::OversizedEvidence)
                .with_stage(AppAttestVerificationStage::EvidenceDecoding),
        );
    }
    let decoded = URL_SAFE_NO_PAD.decode(encoded).map_err(|_| {
        AppAttestVerificationError::new(AppAttestFailureCategory::MalformedEvidence)
            .with_stage(AppAttestVerificationStage::EvidenceDecoding)
    })?;
    if decoded.len() > maximum_decoded {
        return Err(
            AppAttestVerificationError::new(AppAttestFailureCategory::OversizedEvidence)
                .with_stage(AppAttestVerificationStage::EvidenceDecoding),
        );
    }
    Ok(decoded)
}

#[derive(Debug)]
struct ParsedAttestation {
    certificates: Vec<Vec<u8>>,
    authenticator_data: Vec<u8>,
}

impl ParsedAttestation {
    fn parse(encoded: &[u8]) -> Result<Self, AppAttestVerificationError> {
        let mut fields = decode_cbor_map(encoded, &["fmt", "attStmt", "authData"])
            .map_err(|error| error.with_stage(AppAttestVerificationStage::AttestationEnvelope))?;
        let format = take_text(&mut fields, "fmt")
            .map_err(|error| error.with_stage(AppAttestVerificationStage::AttestationFormat))?;
        if format != "apple-appattest" {
            return Err(AppAttestVerificationError::new(
                AppAttestFailureCategory::MalformedEvidence,
            )
            .with_stage(AppAttestVerificationStage::AttestationFormat));
        }
        let authenticator_data = take_bytes(&mut fields, "authData")
            .map_err(|error| error.with_stage(AppAttestVerificationStage::AttestationEnvelope))?;
        if authenticator_data.len() > MAX_AUTHENTICATOR_DATA_BYTES {
            return Err(AppAttestVerificationError::new(
                AppAttestFailureCategory::OversizedEvidence,
            )
            .with_stage(AppAttestVerificationStage::AttestationAuthenticatorLength));
        }
        let statement = fields.remove("attStmt").ok_or_else(|| {
            malformed().with_stage(AppAttestVerificationStage::AttestationStatement)
        })?;
        let mut statement = value_map(statement, &["x5c", "receipt"])
            .map_err(|error| error.with_stage(AppAttestVerificationStage::AttestationStatement))?;
        let receipt = take_bytes(&mut statement, "receipt")
            .map_err(|error| error.with_stage(AppAttestVerificationStage::AttestationReceipt))?;
        if receipt.is_empty() || receipt.len() > MAX_RECEIPT_BYTES {
            return Err(AppAttestVerificationError::new(
                AppAttestFailureCategory::MalformedEvidence,
            )
            .with_stage(AppAttestVerificationStage::AttestationReceipt));
        }
        let certificates =
            match statement.remove("x5c") {
                Some(Value::Array(values)) if values.len() == 2 => values
                    .into_iter()
                    .map(|value| match value {
                        Value::Bytes(bytes)
                            if !bytes.is_empty() && bytes.len() <= MAX_CERTIFICATE_BYTES =>
                        {
                            Ok(bytes)
                        }
                        Value::Bytes(_) => Err(AppAttestVerificationError::new(
                            AppAttestFailureCategory::OversizedEvidence,
                        )
                        .with_stage(AppAttestVerificationStage::AttestationCertificates)),
                        _ => Err(malformed()
                            .with_stage(AppAttestVerificationStage::AttestationCertificates)),
                    })
                    .collect::<Result<Vec<_>, _>>()?,
                _ => {
                    return Err(
                        malformed().with_stage(AppAttestVerificationStage::AttestationCertificates)
                    );
                }
            };
        Ok(Self {
            certificates,
            authenticator_data,
        })
    }
}

#[derive(Debug)]
struct ParsedAssertion {
    signature: Vec<u8>,
    authenticator_data: Vec<u8>,
}

impl ParsedAssertion {
    fn parse(encoded: &[u8]) -> Result<Self, AppAttestVerificationError> {
        let mut fields = decode_cbor_map(encoded, &["signature", "authenticatorData"])
            .map_err(|error| error.with_stage(AppAttestVerificationStage::AssertionEnvelope))?;
        let signature = take_bytes(&mut fields, "signature")
            .map_err(|error| error.with_stage(AppAttestVerificationStage::AssertionSignature))?;
        if signature.is_empty() || signature.len() > 80 {
            return Err(malformed().with_stage(AppAttestVerificationStage::AssertionSignature));
        }
        let authenticator_data = take_bytes(&mut fields, "authenticatorData")
            .map_err(|error| error.with_stage(AppAttestVerificationStage::AssertionEnvelope))?;
        Ok(Self {
            signature,
            authenticator_data,
        })
    }
}

fn decode_cbor_map(
    encoded: &[u8],
    allowed: &[&str],
) -> Result<BTreeMap<String, Value>, AppAttestVerificationError> {
    let mut cursor = Cursor::new(encoded);
    let value: Value = ciborium::from_reader(&mut cursor).map_err(|_| malformed())?;
    if cursor.position() != encoded.len() as u64 {
        return Err(malformed());
    }
    value_map(value, allowed)
}

fn value_map(
    value: Value,
    allowed: &[&str],
) -> Result<BTreeMap<String, Value>, AppAttestVerificationError> {
    let Value::Map(entries) = value else {
        return Err(malformed());
    };
    if entries.len() != allowed.len() {
        return Err(malformed());
    }
    let mut fields = BTreeMap::new();
    for (key, value) in entries {
        let Value::Text(key) = key else {
            return Err(malformed());
        };
        if !allowed.contains(&key.as_str()) || fields.insert(key, value).is_some() {
            return Err(malformed());
        }
    }
    Ok(fields)
}

fn take_text(
    fields: &mut BTreeMap<String, Value>,
    key: &str,
) -> Result<String, AppAttestVerificationError> {
    match fields.remove(key) {
        Some(Value::Text(value)) => Ok(value),
        _ => Err(malformed()),
    }
}

fn take_bytes(
    fields: &mut BTreeMap<String, Value>,
    key: &str,
) -> Result<Vec<u8>, AppAttestVerificationError> {
    match fields.remove(key) {
        Some(Value::Bytes(value)) => Ok(value),
        _ => Err(malformed()),
    }
}

fn malformed() -> AppAttestVerificationError {
    AppAttestVerificationError::new(AppAttestFailureCategory::MalformedEvidence)
}

struct AttestationAuthenticatorData<'a> {
    rp_id_hash: [u8; 32],
    counter: u32,
    environment: InstallationEnvironment,
    credential_id: &'a [u8],
    encoded_public_key: [u8; COSE_P256_PUBLIC_KEY_BYTES],
    claims: Option<AppAttestClaims>,
}

impl<'a> AttestationAuthenticatorData<'a> {
    fn parse(encoded: &'a [u8]) -> Result<Self, AppAttestVerificationError> {
        let minimum = ATTESTATION_CREDENTIAL_ID_OFFSET + APP_ATTEST_KEY_ID_BYTES;
        if encoded.len() < minimum || encoded.len() > MAX_AUTHENTICATOR_DATA_BYTES {
            return Err(
                malformed().with_stage(AppAttestVerificationStage::AttestationAuthenticatorLength)
            );
        }
        let flags = encoded[32];
        // Apple sets only the attested-credential-data bit here, even though
        // its App Attest claims follow the COSE key. This matches Apple's
        // published attestation validation fixture.
        if flags != APP_ATTEST_AUTHENTICATOR_FLAG {
            return Err(
                malformed().with_stage(AppAttestVerificationStage::AttestationAuthenticatorFlags)
            );
        }
        let rp_id_hash = encoded[0..32].try_into().map_err(|_| malformed())?;
        let counter = u32::from_be_bytes(encoded[33..37].try_into().map_err(|_| malformed())?);
        let environment = match &encoded[37..53] {
            b"appattestdevelop" => InstallationEnvironment::Development,
            bytes if bytes == [b"appattest".as_slice(), &[0; 7]].concat() => {
                InstallationEnvironment::Production
            }
            _ => {
                return Err(AppAttestVerificationError::new(
                    AppAttestFailureCategory::WrongEnvironment,
                )
                .with_stage(AppAttestVerificationStage::AttestationEnvironment));
            }
        };
        let credential_id_length =
            u16::from_be_bytes(encoded[53..55].try_into().map_err(|_| malformed())?) as usize;
        if credential_id_length != APP_ATTEST_KEY_ID_BYTES {
            return Err(AppAttestVerificationError::new(
                AppAttestFailureCategory::InvalidCredential,
            )
            .with_stage(AppAttestVerificationStage::AttestationCredential));
        }
        let credential_id = &encoded[ATTESTATION_CREDENTIAL_ID_OFFSET..minimum];
        let (encoded_public_key, claims) = parse_attestation_tail(&encoded[minimum..])?;
        Ok(Self {
            rp_id_hash,
            counter,
            environment,
            credential_id,
            encoded_public_key,
            claims,
        })
    }
}

struct AssertionAuthenticatorData {
    rp_id_hash: [u8; 32],
    counter: u32,
    claims: Option<AppAttestClaims>,
}

impl AssertionAuthenticatorData {
    fn parse(encoded: &[u8]) -> Result<Self, AppAttestVerificationError> {
        if encoded.len() < ASSERTION_AUTHENTICATOR_DATA_BYTES
            || encoded.len() > MAX_AUTHENTICATOR_DATA_BYTES
        {
            return Err(
                malformed().with_stage(AppAttestVerificationStage::AssertionAuthenticatorLength)
            );
        }
        let flags = encoded[32];
        // App Attest uses 0x40 in its simplified assertion authenticator data,
        // as observed from the supported production client. Do not apply
        // WebAuthn assertion flag semantics to Apple's App Attest structure.
        if flags != APP_ATTEST_AUTHENTICATOR_FLAG {
            return Err(malformed()
                .with_detail(AppAttestFailureDetail::AssertionFlagsUnexpectedValue)
                .with_observed_flags(flags)
                .with_stage(AppAttestVerificationStage::AssertionAuthenticatorFlags));
        }
        let has_extensions = encoded.len() > ASSERTION_AUTHENTICATOR_DATA_BYTES;
        let claims = if !has_extensions {
            None
        } else {
            Some(
                parse_claims(&encoded[ASSERTION_AUTHENTICATOR_DATA_BYTES..]).map_err(|error| {
                    error.with_stage(AppAttestVerificationStage::AssertionExtensions)
                })?,
            )
        };
        Ok(Self {
            rp_id_hash: encoded[0..32].try_into().map_err(|_| malformed())?,
            counter: u32::from_be_bytes(encoded[33..37].try_into().map_err(|_| malformed())?),
            claims,
        })
    }
}

struct AppAttestClaims {
    validation_category: u32,
    bundle_version: String,
}

fn parse_attestation_tail(
    encoded: &[u8],
) -> Result<([u8; COSE_P256_PUBLIC_KEY_BYTES], Option<AppAttestClaims>), AppAttestVerificationError>
{
    let mut cursor = Cursor::new(encoded);
    let cose_key: Value = ciborium::from_reader(&mut cursor)
        .map_err(|_| malformed().with_stage(AppAttestVerificationStage::AttestationCoseKey))?;
    let consumed = usize::try_from(cursor.position())
        .map_err(|_| malformed().with_stage(AppAttestVerificationStage::AttestationCoseKey))?;
    let public_key = parse_cose_public_key(cose_key)
        .map_err(|error| error.with_stage(AppAttestVerificationStage::AttestationCoseKey))?;
    let claims =
        if consumed == encoded.len() {
            None
        } else {
            Some(parse_claims(&encoded[consumed..]).map_err(|error| {
                error.with_stage(AppAttestVerificationStage::AttestationExtensions)
            })?)
        };
    Ok((public_key, claims))
}

fn parse_cose_public_key(
    value: Value,
) -> Result<[u8; COSE_P256_PUBLIC_KEY_BYTES], AppAttestVerificationError> {
    let Value::Map(entries) = value else {
        return Err(malformed());
    };
    if entries.len() != 5 {
        return Err(malformed());
    }
    let mut fields = BTreeMap::new();
    for (key, value) in entries {
        let Value::Integer(key) = key else {
            return Err(malformed());
        };
        let key = i64::try_from(key).map_err(|_| malformed())?;
        if ![1, 3, -1, -2, -3].contains(&key) || fields.insert(key, value).is_some() {
            return Err(malformed());
        }
    }
    for (key, expected) in [(1, 2), (3, -7), (-1, 1)] {
        let Some(Value::Integer(actual)) = fields.remove(&key) else {
            return Err(malformed());
        };
        if i64::try_from(actual).map_err(|_| malformed())? != expected {
            return Err(malformed());
        }
    }
    let x = match fields.remove(&-2) {
        Some(Value::Bytes(value)) if value.len() == 32 => value,
        _ => return Err(malformed()),
    };
    let y = match fields.remove(&-3) {
        Some(Value::Bytes(value)) if value.len() == 32 => value,
        _ => return Err(malformed()),
    };
    let mut public_key = [0; COSE_P256_PUBLIC_KEY_BYTES];
    public_key[0] = 4;
    public_key[1..33].copy_from_slice(&x);
    public_key[33..].copy_from_slice(&y);
    Ok(public_key)
}

fn parse_claims(encoded: &[u8]) -> Result<AppAttestClaims, AppAttestVerificationError> {
    let mut cursor = Cursor::new(encoded);
    let value: Value = ciborium::from_reader(&mut cursor)
        .map_err(|_| malformed().with_detail(AppAttestFailureDetail::ExtensionsCbor))?;
    if cursor.position() != encoded.len() as u64 {
        return Err(malformed().with_detail(AppAttestFailureDetail::ExtensionsTrailingData));
    }
    let Value::Map(entries) = value else {
        return Err(malformed()
            .with_detail(AppAttestFailureDetail::ExtensionsNotMap)
            .with_observed_type(CborValueKind::from(&value)));
    };
    if entries.len() != 2 {
        return Err(malformed()
            .with_detail(AppAttestFailureDetail::ExtensionsFieldCount)
            .with_observed_count(entries.len()));
    }
    let mut fields = BTreeMap::new();
    for (key, value) in entries {
        let Value::Text(key) = key else {
            return Err(malformed()
                .with_detail(AppAttestFailureDetail::ExtensionsKeyType)
                .with_observed_type(CborValueKind::from(&key)));
        };
        if !["apple_validation_category_01", "apple_bundle_version_01"].contains(&key.as_str()) {
            return Err(malformed().with_detail(AppAttestFailureDetail::ExtensionsUnknownKey));
        }
        if fields.insert(key, value).is_some() {
            return Err(malformed().with_detail(AppAttestFailureDetail::ExtensionsDuplicateKey));
        }
    }
    let validation_category = match fields.remove("apple_validation_category_01") {
        Some(Value::Bytes(value)) if value.len() == size_of::<u32>() => {
            u32::from_le_bytes(value.try_into().map_err(|_| malformed())?)
        }
        Some(Value::Bytes(value)) => {
            return Err(malformed()
                .with_detail(AppAttestFailureDetail::ValidationCategoryLength)
                .with_observed_type(CborValueKind::Bytes)
                .with_observed_length(value.len()));
        }
        Some(value) => {
            return Err(malformed()
                .with_detail(AppAttestFailureDetail::ValidationCategoryType)
                .with_observed_type(CborValueKind::from(&value)));
        }
        None => {
            return Err(malformed().with_detail(AppAttestFailureDetail::ValidationCategoryMissing));
        }
    };
    let bundle_version = match fields.remove("apple_bundle_version_01") {
        Some(Value::Text(value)) => value,
        Some(value) => {
            return Err(malformed()
                .with_detail(AppAttestFailureDetail::BundleVersionType)
                .with_observed_type(CborValueKind::from(&value)));
        }
        None => {
            return Err(malformed().with_detail(AppAttestFailureDetail::BundleVersionMissing));
        }
    };
    if bundle_version.is_empty() || bundle_version.len() > MAX_BUNDLE_VERSION_BYTES {
        return Err(malformed()
            .with_detail(AppAttestFailureDetail::BundleVersionLength)
            .with_observed_type(CborValueKind::Text)
            .with_observed_length(bundle_version.len()));
    }
    Ok(AppAttestClaims {
        validation_category,
        bundle_version,
    })
}

fn verify_certificate_chain(
    certificates: &[Vec<u8>],
    root: &CertificateDer<'static>,
) -> Result<(), AppAttestVerificationError> {
    let leaf_bytes = certificates
        .first()
        .ok_or_else(|| AppAttestVerificationError::new(AppAttestFailureCategory::InvalidChain))?;
    let intermediate_bytes = certificates
        .get(1..)
        .ok_or_else(|| AppAttestVerificationError::new(AppAttestFailureCategory::InvalidChain))?;
    if intermediate_bytes.is_empty() {
        return Err(AppAttestVerificationError::new(
            AppAttestFailureCategory::InvalidChain,
        ));
    }
    let leaf = CertificateDer::from(leaf_bytes.as_slice());
    let end_entity = EndEntityCert::try_from(&leaf)
        .map_err(|_| AppAttestVerificationError::new(AppAttestFailureCategory::InvalidChain))?;
    let intermediates = intermediate_bytes
        .iter()
        .map(|certificate| CertificateDer::from(certificate.as_slice()))
        .collect::<Vec<_>>();
    let anchor = anchor_from_trusted_cert(root).map_err(|_| {
        AppAttestVerificationError::new(AppAttestFailureCategory::InvalidTrustAnchor)
    })?;
    end_entity
        .verify_for_usage(
            APPLE_CERTIFICATE_SIGNATURE_ALGORITHMS,
            &[anchor],
            &intermediates,
            UnixTime::now(),
            AnyExtendedKeyUsage,
            None,
            None,
        )
        .map_err(|_| AppAttestVerificationError::new(AppAttestFailureCategory::InvalidChain))?;
    Ok(())
}

static APPLE_CERTIFICATE_SIGNATURE_ALGORITHMS: &[&dyn SignatureVerificationAlgorithm] = &[
    webpki::aws_lc_rs::ECDSA_P256_SHA256,
    webpki::aws_lc_rs::ECDSA_P256_SHA384,
    webpki::aws_lc_rs::ECDSA_P384_SHA256,
    webpki::aws_lc_rs::ECDSA_P384_SHA384,
];

#[derive(Debug)]
struct AnyExtendedKeyUsage;

impl ExtendedKeyUsageValidator for AnyExtendedKeyUsage {
    fn validate(&self, _iter: KeyPurposeIdIter<'_, '_>) -> Result<(), webpki::Error> {
        Ok(())
    }
}

fn extract_certificate_nonce(
    certificate: &x509_parser::certificate::X509Certificate<'_>,
) -> Result<[u8; 32], AppAttestVerificationError> {
    let extension = certificate
        .get_extension_unique(&APPLE_NONCE_EXTENSION_OID)
        .map_err(|_| malformed())?
        .ok_or_else(malformed)?;
    let (remaining, sequence) = parse_der(extension.value).map_err(|_| malformed())?;
    if !remaining.is_empty() {
        return Err(malformed());
    }
    let sequence = sequence.as_sequence().map_err(|_| malformed())?;
    if sequence.len() != 1 {
        return Err(malformed());
    }
    let context = &sequence[0];
    if context.class() != Class::ContextSpecific || context.tag() != Tag(1) {
        return Err(malformed());
    }
    let context_bytes = context.as_slice().map_err(|_| malformed())?;
    let (remaining, octets) = parse_der(context_bytes).map_err(|_| malformed())?;
    if !remaining.is_empty() || octets.tag() != Tag::OctetString {
        return Err(malformed());
    }
    octets
        .as_slice()
        .map_err(|_| malformed())?
        .try_into()
        .map_err(|_| malformed())
}

#[cfg(test)]
mod tests {
    use super::*;
    use p256::{
        ecdsa::{SigningKey, signature::Signer},
        pkcs8::DecodePrivateKey,
    };
    use proptest::prelude::*;
    use rcgen::{
        BasicConstraints, CertificateParams, CertifiedIssuer, CustomExtension, IsCa, KeyPair,
        KeyUsagePurpose, PKCS_ECDSA_P256_SHA256,
    };

    use crate::telemetry_auth::{DevelopmentAssertion, DevelopmentAttestation};

    const TEAM_ID: &str = "TESTTEAM01";
    const APP_IDENTIFIER: &str = "com.example.bleat";
    const BUNDLE_VERSION: &str = "42";
    const VALIDATION_CATEGORY: u32 = 3;

    fn test_policy() -> AppAttestPolicy {
        AppAttestPolicy::new([BUNDLE_VERSION.to_owned()], [VALIDATION_CATEGORY])
            .expect("test policy should be valid")
    }

    struct SyntheticEvidence {
        verifier: ProductionAppAttestVerifier,
        signing_key: SigningKey,
        public_key: Vec<u8>,
        key_id: String,
        attestation: String,
        root: CertificateDer<'static>,
    }

    impl SyntheticEvidence {
        fn new(client_data_hash: &[u8; 32], environment: AppAttestEnvironment) -> Self {
            Self::with_extension_support(client_data_hash, environment, true)
        }

        fn without_extensions(
            client_data_hash: &[u8; 32],
            environment: AppAttestEnvironment,
        ) -> Self {
            Self::with_extension_support(client_data_hash, environment, false)
        }

        fn with_extension_support(
            client_data_hash: &[u8; 32],
            environment: AppAttestEnvironment,
            include_extensions: bool,
        ) -> Self {
            let root_key = KeyPair::generate_for(&PKCS_ECDSA_P256_SHA256)
                .expect("test root key should generate");
            let mut root_params = CertificateParams::default();
            root_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
            root_params.key_usages = vec![
                KeyUsagePurpose::KeyCertSign,
                KeyUsagePurpose::CrlSign,
                KeyUsagePurpose::DigitalSignature,
            ];
            let root = CertifiedIssuer::self_signed(root_params, root_key)
                .expect("test root should generate");

            let intermediate_key = KeyPair::generate_for(&PKCS_ECDSA_P256_SHA256)
                .expect("test intermediate key should generate");
            let mut intermediate_params = CertificateParams::default();
            intermediate_params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
            intermediate_params.key_usages = vec![
                KeyUsagePurpose::KeyCertSign,
                KeyUsagePurpose::CrlSign,
                KeyUsagePurpose::DigitalSignature,
            ];
            let intermediate =
                CertifiedIssuer::signed_by(intermediate_params, intermediate_key, &root)
                    .expect("test intermediate should generate");

            let leaf_key = KeyPair::generate_for(&PKCS_ECDSA_P256_SHA256)
                .expect("test leaf key should generate");
            let public_key = leaf_key.public_key_raw().to_vec();
            let key_id_bytes: [u8; 32] = Sha256::digest(&public_key).into();
            let key_id = STANDARD.encode(key_id_bytes);
            let mut authenticator_data = attestation_authenticator_data(
                TEAM_ID,
                APP_IDENTIFIER,
                environment,
                &key_id_bytes,
                &public_key,
            );
            if !include_extensions {
                let extension_length = encode_cbor_bytes(&app_attest_claims()).len();
                authenticator_data.truncate(authenticator_data.len() - extension_length);
            }
            let mut nonce_input = authenticator_data.to_vec();
            nonce_input.extend_from_slice(client_data_hash);
            let nonce: [u8; 32] = Sha256::digest(nonce_input).into();

            let mut leaf_params = CertificateParams::default();
            leaf_params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
            leaf_params
                .custom_extensions
                .push(CustomExtension::from_oid_content(
                    &[1, 2, 840, 113_635, 100, 8, 2],
                    nonce_extension(&nonce),
                ));
            let leaf = leaf_params
                .signed_by(&leaf_key, &intermediate)
                .expect("test leaf should generate");
            let attestation = encode_attestation(
                leaf.der().as_ref(),
                intermediate.der().as_ref(),
                &authenticator_data,
            );
            let signing_key = SigningKey::from_pkcs8_der(&leaf_key.serialize_der())
                .expect("test leaf PKCS#8 should decode");
            let root_der = root.der().clone();
            let verifier = ProductionAppAttestVerifier::new(
                TEAM_ID,
                APP_IDENTIFIER,
                environment,
                test_policy(),
                root_der.clone(),
            )
            .expect("test verifier should initialize");
            Self {
                verifier,
                signing_key,
                public_key,
                key_id,
                attestation,
                root: root_der,
            }
        }

        fn assertion(&self, client_data_hash: &[u8; 32], counter: u32) -> String {
            let authenticator_data = assertion_authenticator_data(TEAM_ID, APP_IDENTIFIER, counter);
            self.sign_assertion(client_data_hash, &authenticator_data)
        }

        fn assertion_without_extensions(
            &self,
            client_data_hash: &[u8; 32],
            counter: u32,
        ) -> String {
            let mut authenticator_data =
                assertion_authenticator_data(TEAM_ID, APP_IDENTIFIER, counter);
            authenticator_data.truncate(ASSERTION_AUTHENTICATOR_DATA_BYTES);
            self.sign_assertion(client_data_hash, &authenticator_data)
        }

        fn sign_assertion(&self, client_data_hash: &[u8; 32], authenticator_data: &[u8]) -> String {
            let mut nonce_input = authenticator_data.to_vec();
            nonce_input.extend_from_slice(client_data_hash);
            let nonce = Sha256::digest(nonce_input);
            let signature: Signature = self.signing_key.sign(&nonce);
            encode_assertion(signature.to_der().as_bytes(), authenticator_data)
        }
    }

    fn attestation_authenticator_data(
        team_id: &str,
        app_identifier: &str,
        environment: AppAttestEnvironment,
        key_id: &[u8; 32],
        public_key: &[u8],
    ) -> Vec<u8> {
        let mut data = Vec::new();
        data.extend_from_slice(&Sha256::digest(
            format!("{team_id}.{app_identifier}").as_bytes(),
        ));
        data.push(APP_ATTEST_AUTHENTICATOR_FLAG);
        data.extend_from_slice(&0_u32.to_be_bytes());
        match environment {
            AppAttestEnvironment::Development => data.extend_from_slice(b"appattestdevelop"),
            AppAttestEnvironment::Production => {
                data.extend_from_slice(b"appattest");
                data.extend_from_slice(&[0; 7]);
            }
        }
        data.extend_from_slice(&(APP_ATTEST_KEY_ID_BYTES as u16).to_be_bytes());
        data.extend_from_slice(key_id);
        data.extend_from_slice(&encode_cbor_bytes(&cose_public_key(public_key)));
        data.extend_from_slice(&encode_cbor_bytes(&app_attest_claims()));
        data
    }

    fn assertion_authenticator_data(team_id: &str, app_identifier: &str, counter: u32) -> Vec<u8> {
        let mut data = Vec::new();
        data.extend_from_slice(&Sha256::digest(
            format!("{team_id}.{app_identifier}").as_bytes(),
        ));
        data.push(APP_ATTEST_AUTHENTICATOR_FLAG);
        data.extend_from_slice(&counter.to_be_bytes());
        data.extend_from_slice(&encode_cbor_bytes(&app_attest_claims()));
        data
    }

    fn cose_public_key(public_key: &[u8]) -> Value {
        Value::Map(vec![
            (Value::Integer(1.into()), Value::Integer(2.into())),
            (Value::Integer(3.into()), Value::Integer((-7).into())),
            (Value::Integer((-1).into()), Value::Integer(1.into())),
            (
                Value::Integer((-2).into()),
                Value::Bytes(public_key[1..33].to_vec()),
            ),
            (
                Value::Integer((-3).into()),
                Value::Bytes(public_key[33..].to_vec()),
            ),
        ])
    }

    fn app_attest_claims() -> Value {
        Value::Map(vec![
            (
                Value::Text("apple_validation_category_01".to_owned()),
                Value::Bytes(VALIDATION_CATEGORY.to_le_bytes().to_vec()),
            ),
            (
                Value::Text("apple_bundle_version_01".to_owned()),
                Value::Text(BUNDLE_VERSION.to_owned()),
            ),
        ])
    }

    fn nonce_extension(nonce: &[u8; 32]) -> Vec<u8> {
        let mut extension = vec![0x30, 0x24, 0xa1, 0x22, 0x04, 0x20];
        extension.extend_from_slice(nonce);
        extension
    }

    fn encode_attestation(leaf: &[u8], intermediate: &[u8], auth_data: &[u8]) -> String {
        let value = Value::Map(vec![
            (
                Value::Text("fmt".to_owned()),
                Value::Text("apple-appattest".to_owned()),
            ),
            (
                Value::Text("attStmt".to_owned()),
                Value::Map(vec![
                    (
                        Value::Text("x5c".to_owned()),
                        Value::Array(vec![
                            Value::Bytes(leaf.to_vec()),
                            Value::Bytes(intermediate.to_vec()),
                        ]),
                    ),
                    (
                        Value::Text("receipt".to_owned()),
                        Value::Bytes(vec![1, 2, 3]),
                    ),
                ]),
            ),
            (
                Value::Text("authData".to_owned()),
                Value::Bytes(auth_data.to_vec()),
            ),
        ]);
        encode_cbor(&value)
    }

    fn encode_assertion(signature: &[u8], auth_data: &[u8]) -> String {
        encode_cbor(&Value::Map(vec![
            (
                Value::Text("signature".to_owned()),
                Value::Bytes(signature.to_vec()),
            ),
            (
                Value::Text("authenticatorData".to_owned()),
                Value::Bytes(auth_data.to_vec()),
            ),
        ]))
    }

    fn encode_cbor(value: &Value) -> String {
        URL_SAFE_NO_PAD.encode(encode_cbor_bytes(value))
    }

    fn encode_cbor_bytes(value: &Value) -> Vec<u8> {
        let mut bytes = Vec::new();
        ciborium::into_writer(value, &mut bytes).expect("test CBOR should encode");
        bytes
    }

    fn assert_failure<T>(
        result: Result<T, AppAttestVerificationError>,
        expected: AppAttestFailureCategory,
    ) {
        let actual = result.map_or_else(|error| Some(error.category()), |_| None);
        assert_eq!(actual, Some(expected));
    }

    fn development_attestation(
        signing_key: &SigningKey,
        client_data_hash: &[u8; 32],
    ) -> (String, String, Vec<u8>) {
        let public_key = signing_key.verifying_key().to_encoded_point(false);
        let public_key = public_key.as_bytes().to_vec();
        let signature: Signature = signing_key.sign(client_data_hash);
        let evidence = DevelopmentAttestation {
            public_key: URL_SAFE_NO_PAD.encode(&public_key),
            signature: URL_SAFE_NO_PAD.encode(signature.to_der().as_bytes()),
        };
        (
            URL_SAFE_NO_PAD.encode(Sha256::digest(&public_key)),
            URL_SAFE_NO_PAD.encode(
                serde_json::to_vec(&evidence).expect("development attestation should encode"),
            ),
            public_key,
        )
    }

    fn development_assertion(signing_key: &SigningKey, client_data_hash: &[u8; 32]) -> String {
        let signature: Signature = signing_key.sign(client_data_hash);
        let evidence = DevelopmentAssertion {
            signature: URL_SAFE_NO_PAD.encode(signature.to_der().as_bytes()),
        };
        URL_SAFE_NO_PAD
            .encode(serde_json::to_vec(&evidence).expect("development assertion should encode"))
    }

    #[test]
    fn failure_categories_have_stable_metric_names() {
        for (category, expected) in [
            (
                AppAttestFailureCategory::MalformedEvidence,
                "attestation.malformed_evidence",
            ),
            (
                AppAttestFailureCategory::OversizedEvidence,
                "attestation.oversized_evidence",
            ),
            (
                AppAttestFailureCategory::InvalidChain,
                "attestation.invalid_chain",
            ),
            (
                AppAttestFailureCategory::InvalidNonce,
                "attestation.invalid_nonce",
            ),
            (
                AppAttestFailureCategory::WrongApplication,
                "attestation.wrong_application",
            ),
            (
                AppAttestFailureCategory::WrongEnvironment,
                "attestation.wrong_environment",
            ),
            (
                AppAttestFailureCategory::InvalidCredential,
                "attestation.invalid_credential",
            ),
            (
                AppAttestFailureCategory::InvalidSignature,
                "assertion.invalid_signature",
            ),
            (
                AppAttestFailureCategory::InvalidCounter,
                "attestation.invalid_counter",
            ),
            (
                AppAttestFailureCategory::AssertionReplay,
                "assertion.replay",
            ),
            (
                AppAttestFailureCategory::InvalidTrustAnchor,
                "attestation.invalid_trust_anchor",
            ),
        ] {
            assert_eq!(category.metric_name(), expected);
        }
    }

    #[test]
    fn rejection_stages_distinguish_production_parser_failures() {
        let Err(envelope_error) = ParsedAttestation::parse(b"not cbor") else {
            panic!("invalid CBOR should be rejected");
        };
        assert_eq!(
            envelope_error.stage(),
            AppAttestVerificationStage::AttestationEnvelope
        );

        let signing_key = SigningKey::from_slice(&[21; 32]).expect("test key should be valid");
        let public_key = signing_key.verifying_key().to_encoded_point(false);
        let key_id: [u8; 32] = Sha256::digest(public_key.as_bytes()).into();
        let mut authenticator = attestation_authenticator_data(
            TEAM_ID,
            APP_IDENTIFIER,
            AppAttestEnvironment::Production,
            &key_id,
            public_key.as_bytes(),
        );
        authenticator[32] = 0xff;
        let Err(flags_error) = AttestationAuthenticatorData::parse(&authenticator) else {
            panic!("invalid flags should be rejected");
        };
        assert_eq!(
            flags_error.stage(),
            AppAttestVerificationStage::AttestationAuthenticatorFlags
        );
        assert_eq!(
            flags_error.stage().metric_name(),
            "attestation.authenticator.flags"
        );
    }

    #[test]
    fn policy_and_verifier_configuration_reject_invalid_values() {
        for result in [
            AppAttestPolicy::new([], [VALIDATION_CATEGORY]),
            AppAttestPolicy::new([" ".to_owned()], [VALIDATION_CATEGORY]),
            AppAttestPolicy::new(
                ["x".repeat(MAX_BUNDLE_VERSION_BYTES + 1)],
                [VALIDATION_CATEGORY],
            ),
            AppAttestPolicy::new([BUNDLE_VERSION.to_owned()], []),
            AppAttestPolicy::new([BUNDLE_VERSION.to_owned()], [0]),
            AppAttestPolicy::new([BUNDLE_VERSION.to_owned()], [7]),
        ] {
            assert_failure(result, AppAttestFailureCategory::WrongApplication);
        }

        let root = SyntheticEvidence::new(&[1; 32], AppAttestEnvironment::Production).root;
        for (team_id, app_identifier) in [("", APP_IDENTIFIER), (TEAM_ID, " ")] {
            assert_failure(
                ProductionAppAttestVerifier::new(
                    team_id,
                    app_identifier,
                    AppAttestEnvironment::Production,
                    test_policy(),
                    root.clone(),
                ),
                AppAttestFailureCategory::WrongApplication,
            );
        }
        assert_failure(
            ProductionAppAttestVerifier::new(
                TEAM_ID,
                APP_IDENTIFIER,
                AppAttestEnvironment::Production,
                test_policy(),
                CertificateDer::from(vec![0; 8]),
            ),
            AppAttestFailureCategory::InvalidTrustAnchor,
        );
    }

    #[test]
    fn development_verifier_maps_malformed_environment_and_counter_failures() {
        let client_data_hash = [9; 32];
        let signing_key = SigningKey::from_slice(&[17; 32]).expect("test key should be valid");
        let (key_id, attestation, public_key) =
            development_attestation(&signing_key, &client_data_hash);
        let verifier = InstallationEvidenceVerifier::Development;
        let verified = verifier
            .verify_attestation(&key_id, &attestation, &client_data_hash)
            .expect("development attestation should verify");
        assert_eq!(verified.public_key, public_key);
        assert_eq!(verified.environment, InstallationEnvironment::Development);

        assert_failure(
            verifier.verify_attestation(&key_id, "%", &client_data_hash),
            AppAttestFailureCategory::MalformedEvidence,
        );
        let assertion = development_assertion(&signing_key, &client_data_hash);
        assert_failure(
            verifier.verify_assertion(
                &public_key,
                InstallationEnvironment::Production,
                &assertion,
                &client_data_hash,
                0,
            ),
            AppAttestFailureCategory::WrongEnvironment,
        );
        assert_failure(
            verifier.verify_assertion(
                &public_key,
                InstallationEnvironment::Development,
                &assertion,
                &client_data_hash,
                u32::MAX,
            ),
            AppAttestFailureCategory::InvalidCounter,
        );
    }

    #[test]
    fn evidence_decoding_enforces_encoding_and_size_bounds() {
        assert_failure(
            decode_evidence("%", MAX_DECODED_ASSERTION_BYTES),
            AppAttestFailureCategory::MalformedEvidence,
        );
        assert_failure(
            decode_evidence(
                &"A".repeat(MAX_ENCODED_EVIDENCE_BYTES + 1),
                MAX_DECODED_ATTESTATION_BYTES,
            ),
            AppAttestFailureCategory::OversizedEvidence,
        );
        assert_failure(
            decode_evidence(
                &URL_SAFE_NO_PAD.encode(vec![0; MAX_DECODED_ASSERTION_BYTES + 1]),
                MAX_DECODED_ASSERTION_BYTES,
            ),
            AppAttestFailureCategory::OversizedEvidence,
        );
    }

    #[test]
    fn attestation_and_assertion_envelopes_enforce_exact_bounded_shapes() {
        let valid_statement = || {
            Value::Map(vec![
                (
                    Value::Text("x5c".to_owned()),
                    Value::Array(vec![Value::Bytes(vec![1]), Value::Bytes(vec![2])]),
                ),
                (Value::Text("receipt".to_owned()), Value::Bytes(vec![1])),
            ])
        };
        let attestation = |format: Value, statement: Value, authenticator_data: Vec<u8>| {
            encode_cbor_bytes(&Value::Map(vec![
                (Value::Text("fmt".to_owned()), format),
                (Value::Text("attStmt".to_owned()), statement),
                (
                    Value::Text("authData".to_owned()),
                    Value::Bytes(authenticator_data),
                ),
            ]))
        };

        for encoded in [
            attestation(Value::Text("wrong".to_owned()), valid_statement(), vec![1]),
            attestation(
                Value::Text("apple-appattest".to_owned()),
                Value::Map(vec![
                    (
                        Value::Text("x5c".to_owned()),
                        Value::Array(vec![Value::Bytes(vec![1]), Value::Bytes(vec![2])]),
                    ),
                    (Value::Text("receipt".to_owned()), Value::Bytes(Vec::new())),
                ]),
                vec![1],
            ),
            attestation(
                Value::Text("apple-appattest".to_owned()),
                Value::Map(vec![
                    (
                        Value::Text("x5c".to_owned()),
                        Value::Array(vec![
                            Value::Text("not-bytes".to_owned()),
                            Value::Bytes(vec![2]),
                        ]),
                    ),
                    (Value::Text("receipt".to_owned()), Value::Bytes(vec![1])),
                ]),
                vec![1],
            ),
        ] {
            assert_failure(
                ParsedAttestation::parse(&encoded),
                AppAttestFailureCategory::MalformedEvidence,
            );
        }

        let oversized_authenticator = attestation(
            Value::Text("apple-appattest".to_owned()),
            valid_statement(),
            vec![0; MAX_AUTHENTICATOR_DATA_BYTES + 1],
        );
        assert_failure(
            ParsedAttestation::parse(&oversized_authenticator),
            AppAttestFailureCategory::OversizedEvidence,
        );

        let oversized_certificate = attestation(
            Value::Text("apple-appattest".to_owned()),
            Value::Map(vec![
                (
                    Value::Text("x5c".to_owned()),
                    Value::Array(vec![
                        Value::Bytes(vec![0; MAX_CERTIFICATE_BYTES + 1]),
                        Value::Bytes(vec![2]),
                    ]),
                ),
                (Value::Text("receipt".to_owned()), Value::Bytes(vec![1])),
            ]),
            vec![1],
        );
        assert_failure(
            ParsedAttestation::parse(&oversized_certificate),
            AppAttestFailureCategory::OversizedEvidence,
        );

        for signature in [Vec::new(), vec![0; 81]] {
            let assertion = encode_cbor_bytes(&Value::Map(vec![
                (Value::Text("signature".to_owned()), Value::Bytes(signature)),
                (
                    Value::Text("authenticatorData".to_owned()),
                    Value::Bytes(vec![1]),
                ),
            ]));
            assert_failure(
                ParsedAssertion::parse(&assertion),
                AppAttestFailureCategory::MalformedEvidence,
            );
        }
    }

    #[test]
    fn attestation_authenticator_accepts_apple_documented_flag_shape() {
        let signing_key = SigningKey::from_slice(&[22; 32]).expect("test key should be valid");
        let public_key = signing_key.verifying_key().to_encoded_point(false);
        let key_id: [u8; 32] = Sha256::digest(public_key.as_bytes()).into();
        let encoded = attestation_authenticator_data(
            TEAM_ID,
            APP_IDENTIFIER,
            AppAttestEnvironment::Production,
            &key_id,
            public_key.as_bytes(),
        );

        assert_eq!(encoded[32], 0x40);
        let parsed = AttestationAuthenticatorData::parse(&encoded)
            .expect("Apple-documented authenticator flags should parse");
        assert_eq!(parsed.credential_id, key_id);
        let claims = parsed.claims.expect("generated claims should parse");
        assert_eq!(claims.validation_category, VALIDATION_CATEGORY);
        assert_eq!(claims.bundle_version, BUNDLE_VERSION);
    }

    #[test]
    fn apple_validation_guide_authenticator_data_parses_exact_claim_encoding() {
        // Public fixture from Apple's App Attest Attestation Object Validation Guide:
        // https://developer.apple.com/documentation/devicecheck/attestation-object-validation-guide
        let encoded = STANDARD
            .decode(include_str!(
                "../tests/fixtures/apple-app-attest/2026-validation-guide-authenticator-data.b64"
            ).trim())
            .expect("Apple fixture should be valid base64");

        let parsed = AttestationAuthenticatorData::parse(&encoded)
            .expect("Apple fixture authenticator data should parse");

        assert_eq!(
            parsed.rp_id_hash,
            Sha256::digest(b"1234567890.com.example.myapp").as_slice()
        );
        assert_eq!(parsed.counter, 0);
        assert_eq!(parsed.environment, InstallationEnvironment::Production);
        assert_eq!(
            parsed.credential_id,
            STANDARD
                .decode("zgSY9YSD+7TaDXssY6WlOPVS1K3Lmk+pFhlcSWE+ZV0=")
                .expect("Apple fixture key ID should be valid base64")
        );
        assert_eq!(
            Sha256::digest(parsed.encoded_public_key).as_slice(),
            parsed.credential_id
        );
        let claims = parsed.claims.expect("Apple fixture claims should parse");
        assert_eq!(claims.validation_category, 1);
        assert_eq!(claims.bundle_version, "1");
    }

    #[test]
    fn production_verifier_accepts_pre_ios_27_evidence_without_extensions() {
        let client_data_hash = [43; 32];
        let evidence = SyntheticEvidence::without_extensions(
            &client_data_hash,
            AppAttestEnvironment::Production,
        );

        let verified = evidence
            .verifier
            .verify_attestation(&evidence.key_id, &evidence.attestation, &client_data_hash)
            .expect("pre-iOS 27 attestation should verify without extensions");
        assert_eq!(verified.public_key, evidence.public_key);

        let assertion = evidence.assertion_without_extensions(&client_data_hash, 1);
        assert_eq!(
            evidence
                .verifier
                .verify_assertion(
                    &verified.public_key,
                    InstallationEnvironment::Production,
                    &assertion,
                    &client_data_hash,
                    0,
                )
                .expect("pre-iOS 27 assertion should verify without extensions")
                .counter,
            1
        );
    }

    #[test]
    fn assertion_authenticator_requires_apple_flag_shape() {
        let authenticator_data = |flags: u8, include_extensions: bool| {
            let mut data = vec![0; ASSERTION_AUTHENTICATOR_DATA_BYTES];
            data[32] = flags;
            if include_extensions {
                data.extend_from_slice(&encode_cbor_bytes(&app_attest_claims()));
            }
            data
        };

        AssertionAuthenticatorData::parse(&authenticator_data(
            APP_ATTEST_AUTHENTICATOR_FLAG,
            false,
        ))
        .expect("Apple assertion without extensions should parse");
        AssertionAuthenticatorData::parse(&authenticator_data(APP_ATTEST_AUTHENTICATOR_FLAG, true))
            .expect("Apple assertion with extensions should parse");

        for flags in [0x00, 0x01, 0x80, 0xc0] {
            let error = match AssertionAuthenticatorData::parse(&authenticator_data(flags, false)) {
                Ok(_) => panic!("invalid assertion flag shape should fail"),
                Err(error) => error,
            };
            assert_eq!(
                error.stage(),
                AppAttestVerificationStage::AssertionAuthenticatorFlags
            );
            assert_eq!(
                error.detail(),
                AppAttestFailureDetail::AssertionFlagsUnexpectedValue
            );
            assert_eq!(error.observed_flags(), Some(flags));
        }
    }

    #[test]
    fn claim_parser_preserves_safe_structural_failure_details() {
        let cases = [
            (
                Value::Map(vec![(
                    Value::Text("apple_bundle_version_01".to_owned()),
                    Value::Text(BUNDLE_VERSION.to_owned()),
                )]),
                AppAttestFailureDetail::ExtensionsFieldCount,
                None,
                None,
                Some(1),
            ),
            (
                Value::Map(vec![
                    (
                        Value::Text("apple_validation_category_01".to_owned()),
                        Value::Integer(VALIDATION_CATEGORY.into()),
                    ),
                    (
                        Value::Text("apple_bundle_version_01".to_owned()),
                        Value::Text(BUNDLE_VERSION.to_owned()),
                    ),
                ]),
                AppAttestFailureDetail::ValidationCategoryType,
                Some(CborValueKind::Integer),
                None,
                None,
            ),
            (
                Value::Map(vec![
                    (
                        Value::Text("apple_validation_category_01".to_owned()),
                        Value::Bytes(vec![1, 0, 0]),
                    ),
                    (
                        Value::Text("apple_bundle_version_01".to_owned()),
                        Value::Text(BUNDLE_VERSION.to_owned()),
                    ),
                ]),
                AppAttestFailureDetail::ValidationCategoryLength,
                Some(CborValueKind::Bytes),
                Some(3),
                None,
            ),
            (
                Value::Map(vec![
                    (
                        Value::Text("apple_validation_category_01".to_owned()),
                        Value::Bytes(VALIDATION_CATEGORY.to_le_bytes().to_vec()),
                    ),
                    (
                        Value::Text("apple_bundle_version_01".to_owned()),
                        Value::Bytes(vec![1]),
                    ),
                ]),
                AppAttestFailureDetail::BundleVersionType,
                Some(CborValueKind::Bytes),
                None,
                None,
            ),
        ];

        for (claims, detail, observed_type, observed_length, observed_count) in cases {
            let error = parse_claims(&encode_cbor_bytes(&claims))
                .err()
                .expect("invalid claims should preserve their structural failure");
            assert_eq!(error.detail(), detail);
            assert_eq!(error.observed_type(), observed_type);
            assert_eq!(error.observed_length(), observed_length);
            assert_eq!(error.observed_count(), observed_count);
        }
    }

    #[test]
    fn authenticator_cose_and_claim_parsers_reject_boundary_shapes() {
        let signing_key = SigningKey::from_slice(&[23; 32]).expect("test key should be valid");
        let public_key = signing_key.verifying_key().to_encoded_point(false);
        let key_id: [u8; 32] = Sha256::digest(public_key.as_bytes()).into();
        let valid = attestation_authenticator_data(
            TEAM_ID,
            APP_IDENTIFIER,
            AppAttestEnvironment::Production,
            &key_id,
            public_key.as_bytes(),
        );

        for mut encoded in [valid[..54].to_vec(), valid.clone()] {
            if encoded.len() == valid.len() {
                encoded[32] = 0;
            }
            assert_failure(
                AttestationAuthenticatorData::parse(&encoded),
                AppAttestFailureCategory::MalformedEvidence,
            );
        }
        let mut wrong_environment = valid.clone();
        wrong_environment[37..53].fill(b'x');
        assert_failure(
            AttestationAuthenticatorData::parse(&wrong_environment),
            AppAttestFailureCategory::WrongEnvironment,
        );
        let mut wrong_credential_length = valid;
        wrong_credential_length[53..55].copy_from_slice(&31_u16.to_be_bytes());
        assert_failure(
            AttestationAuthenticatorData::parse(&wrong_credential_length),
            AppAttestFailureCategory::InvalidCredential,
        );

        for value in [
            Value::Array(Vec::new()),
            Value::Map(Vec::new()),
            Value::Map(vec![
                (Value::Integer(1.into()), Value::Integer(2.into())),
                (Value::Integer(3.into()), Value::Integer((-8).into())),
                (Value::Integer((-1).into()), Value::Integer(1.into())),
                (Value::Integer((-2).into()), Value::Bytes(vec![0; 32])),
                (Value::Integer((-3).into()), Value::Bytes(vec![0; 32])),
            ]),
            Value::Map(vec![
                (Value::Integer(1.into()), Value::Integer(2.into())),
                (Value::Integer(3.into()), Value::Integer((-7).into())),
                (Value::Integer((-1).into()), Value::Integer(1.into())),
                (Value::Integer((-2).into()), Value::Bytes(vec![0; 31])),
                (Value::Integer((-3).into()), Value::Bytes(vec![0; 32])),
            ]),
        ] {
            assert_failure(
                parse_cose_public_key(value),
                AppAttestFailureCategory::MalformedEvidence,
            );
        }

        for claims in [
            Value::Map(vec![
                (
                    Value::Text("apple_validation_category_01".to_owned()),
                    Value::Text("wrong".to_owned()),
                ),
                (
                    Value::Text("apple_bundle_version_01".to_owned()),
                    Value::Text(BUNDLE_VERSION.to_owned()),
                ),
            ]),
            Value::Map(vec![
                (
                    Value::Text("apple_validation_category_01".to_owned()),
                    Value::Bytes(VALIDATION_CATEGORY.to_le_bytes().to_vec()),
                ),
                (
                    Value::Text("apple_bundle_version_01".to_owned()),
                    Value::Text(String::new()),
                ),
            ]),
        ] {
            assert_failure(
                parse_claims(&encode_cbor_bytes(&claims)),
                AppAttestFailureCategory::MalformedEvidence,
            );
        }
    }

    #[test]
    fn pem_and_chain_parsing_reject_invalid_trust_material() {
        for pem in [
            Vec::new(),
            b"not a certificate".to_vec(),
            [APPLE_ROOT_PEM, APPLE_ROOT_PEM].concat(),
        ] {
            assert_failure(
                parse_single_pem_certificate(&pem),
                AppAttestFailureCategory::InvalidTrustAnchor,
            );
        }
        assert_failure(
            verify_certificate_chain(&[], &CertificateDer::from(vec![0; 8])),
            AppAttestFailureCategory::InvalidChain,
        );
        assert_failure(
            verify_certificate_chain(&[vec![0; 8]], &CertificateDer::from(vec![0; 8])),
            AppAttestFailureCategory::InvalidChain,
        );
    }

    #[test]
    fn production_dispatch_and_early_validation_failures_are_typed() {
        let client_data_hash = [31; 32];
        let evidence = SyntheticEvidence::new(&client_data_hash, AppAttestEnvironment::Production);
        let verifier = InstallationEvidenceVerifier::Production(evidence.verifier.clone());
        let verified = verifier
            .verify_attestation(&evidence.key_id, &evidence.attestation, &client_data_hash)
            .expect("production dispatch should verify attestation");
        let assertion = evidence.assertion(&client_data_hash, 4);
        assert_eq!(
            verifier
                .verify_assertion(
                    &verified.public_key,
                    InstallationEnvironment::Production,
                    &assertion,
                    &client_data_hash,
                    3,
                )
                .expect("production dispatch should verify assertion")
                .counter,
            4
        );

        assert_failure(
            evidence
                .verifier
                .verify_attestation("%", &evidence.attestation, &client_data_hash),
            AppAttestFailureCategory::InvalidCredential,
        );
        assert_failure(
            evidence.verifier.verify_assertion(
                &[0; COSE_P256_PUBLIC_KEY_BYTES],
                InstallationEnvironment::Production,
                &assertion,
                &client_data_hash,
                3,
            ),
            AppAttestFailureCategory::InvalidCredential,
        );

        let decoded = URL_SAFE_NO_PAD
            .decode(&evidence.attestation)
            .expect("synthetic attestation should decode");
        let parsed =
            ParsedAttestation::parse(&decoded).expect("synthetic attestation should parse");
        let mut authenticator_data = parsed.authenticator_data;
        authenticator_data[33..37].copy_from_slice(&1_u32.to_be_bytes());
        let nonzero_counter = encode_attestation(
            &parsed.certificates[0],
            &parsed.certificates[1],
            &authenticator_data,
        );
        assert_failure(
            evidence.verifier.verify_attestation(
                &evidence.key_id,
                &nonzero_counter,
                &client_data_hash,
            ),
            AppAttestFailureCategory::InvalidCounter,
        );
    }

    #[test]
    fn embedded_apple_root_has_pinned_fingerprint() {
        let verifier = ProductionAppAttestVerifier::with_embedded_apple_root(
            TEAM_ID,
            APP_IDENTIFIER,
            AppAttestEnvironment::Production,
            test_policy(),
        );
        assert!(verifier.is_ok());
    }

    #[test]
    fn production_attestation_and_assertion_validate_complete_contract() {
        let client_data_hash = [7; 32];
        let evidence = SyntheticEvidence::new(&client_data_hash, AppAttestEnvironment::Production);
        let attestation = evidence
            .verifier
            .verify_attestation(&evidence.key_id, &evidence.attestation, &client_data_hash)
            .expect("valid attestation should verify");
        assert_eq!(attestation.public_key, evidence.public_key);
        assert_eq!(attestation.environment, InstallationEnvironment::Production);

        let assertion = evidence.assertion(&client_data_hash, 9);
        assert_eq!(
            evidence
                .verifier
                .verify_assertion(
                    &evidence.public_key,
                    InstallationEnvironment::Production,
                    &assertion,
                    &client_data_hash,
                    8,
                )
                .expect("valid assertion should verify")
                .counter,
            9
        );
    }

    #[test]
    fn attestation_rejects_nonce_identity_environment_key_and_chain_mismatches() {
        let client_data_hash = [3; 32];
        let evidence = SyntheticEvidence::new(&client_data_hash, AppAttestEnvironment::Production);
        assert_eq!(
            evidence
                .verifier
                .verify_attestation(&evidence.key_id, &evidence.attestation, &[4; 32])
                .expect_err("wrong nonce should fail")
                .category(),
            AppAttestFailureCategory::InvalidNonce
        );
        assert_eq!(
            ProductionAppAttestVerifier::new(
                TEAM_ID,
                "com.example.other",
                AppAttestEnvironment::Production,
                test_policy(),
                evidence.root.clone(),
            )
            .expect("alternate verifier should initialize")
            .verify_attestation(&evidence.key_id, &evidence.attestation, &client_data_hash)
            .expect_err("wrong app should fail")
            .category(),
            AppAttestFailureCategory::WrongApplication
        );
        assert_eq!(
            ProductionAppAttestVerifier::new(
                TEAM_ID,
                APP_IDENTIFIER,
                AppAttestEnvironment::Production,
                AppAttestPolicy::new(["43".to_owned()], [VALIDATION_CATEGORY])
                    .expect("alternate policy should initialize"),
                evidence.root.clone(),
            )
            .expect("alternate verifier should initialize")
            .verify_attestation(&evidence.key_id, &evidence.attestation, &client_data_hash)
            .expect_err("wrong bundle version should fail")
            .category(),
            AppAttestFailureCategory::WrongApplication
        );
        assert_eq!(
            ProductionAppAttestVerifier::new(
                TEAM_ID,
                APP_IDENTIFIER,
                AppAttestEnvironment::Development,
                test_policy(),
                evidence.root.clone(),
            )
            .expect("development verifier should initialize")
            .verify_attestation(&evidence.key_id, &evidence.attestation, &client_data_hash)
            .expect_err("wrong environment should fail")
            .category(),
            AppAttestFailureCategory::WrongEnvironment
        );
        assert_eq!(
            evidence
                .verifier
                .verify_attestation(
                    &STANDARD.encode([0; 32]),
                    &evidence.attestation,
                    &client_data_hash
                )
                .expect_err("wrong key ID should fail")
                .category(),
            AppAttestFailureCategory::InvalidCredential
        );
        let other = SyntheticEvidence::new(&client_data_hash, AppAttestEnvironment::Production);
        assert_eq!(
            ProductionAppAttestVerifier::new(
                TEAM_ID,
                APP_IDENTIFIER,
                AppAttestEnvironment::Production,
                test_policy(),
                other.root,
            )
            .expect("untrusted verifier should initialize")
            .verify_attestation(&evidence.key_id, &evidence.attestation, &client_data_hash)
            .expect_err("untrusted chain should fail")
            .category(),
            AppAttestFailureCategory::InvalidChain
        );
    }

    #[test]
    fn assertion_rejects_bad_signature_key_app_environment_and_counter() {
        let client_data_hash = [5; 32];
        let evidence = SyntheticEvidence::new(&client_data_hash, AppAttestEnvironment::Production);
        let assertion = evidence.assertion(&client_data_hash, 2);
        assert_eq!(
            evidence
                .verifier
                .verify_assertion(
                    &evidence.public_key,
                    InstallationEnvironment::Production,
                    &assertion,
                    &client_data_hash,
                    2,
                )
                .expect_err("equal counter should fail")
                .category(),
            AppAttestFailureCategory::AssertionReplay
        );
        assert_eq!(
            evidence
                .verifier
                .verify_assertion(
                    &evidence.public_key,
                    InstallationEnvironment::Production,
                    &assertion,
                    &client_data_hash,
                    3,
                )
                .expect_err("lower counter should fail")
                .category(),
            AppAttestFailureCategory::AssertionReplay
        );
        let wrong_environment = evidence
            .verifier
            .verify_assertion(
                &evidence.public_key,
                InstallationEnvironment::Development,
                &assertion,
                &client_data_hash,
                1,
            )
            .expect_err("wrong environment should fail");
        assert_eq!(
            wrong_environment.category(),
            AppAttestFailureCategory::WrongEnvironment
        );
        assert_eq!(
            wrong_environment.stage(),
            AppAttestVerificationStage::AssertionEnvironment
        );
        assert_eq!(
            wrong_environment.stage().metric_name(),
            "assertion.environment"
        );
        let other = SyntheticEvidence::new(&client_data_hash, AppAttestEnvironment::Production);
        assert_eq!(
            evidence
                .verifier
                .verify_assertion(
                    &other.public_key,
                    InstallationEnvironment::Production,
                    &assertion,
                    &client_data_hash,
                    1,
                )
                .expect_err("wrong key should fail")
                .category(),
            AppAttestFailureCategory::InvalidSignature
        );
        assert_eq!(
            ProductionAppAttestVerifier::new(
                TEAM_ID,
                "com.example.other",
                AppAttestEnvironment::Production,
                test_policy(),
                evidence.root.clone(),
            )
            .expect("alternate verifier should initialize")
            .verify_assertion(
                &evidence.public_key,
                InstallationEnvironment::Production,
                &assertion,
                &client_data_hash,
                1,
            )
            .expect_err("wrong app should fail")
            .category(),
            AppAttestFailureCategory::WrongApplication
        );
        assert_eq!(
            ProductionAppAttestVerifier::new(
                TEAM_ID,
                APP_IDENTIFIER,
                AppAttestEnvironment::Production,
                AppAttestPolicy::new([BUNDLE_VERSION.to_owned()], [4])
                    .expect("alternate policy should initialize"),
                evidence.root.clone(),
            )
            .expect("alternate verifier should initialize")
            .verify_assertion(
                &evidence.public_key,
                InstallationEnvironment::Production,
                &assertion,
                &client_data_hash,
                1,
            )
            .expect_err("wrong validation category should fail")
            .category(),
            AppAttestFailureCategory::WrongApplication
        );
        assert_eq!(
            evidence
                .verifier
                .verify_assertion(
                    &evidence.public_key,
                    InstallationEnvironment::Production,
                    &assertion,
                    &[6; 32],
                    1,
                )
                .expect_err("wrong signed client data should fail")
                .category(),
            AppAttestFailureCategory::InvalidSignature
        );
    }

    #[test]
    fn cbor_rejects_trailing_duplicate_and_oversized_data() {
        let mut trailing = vec![0xa0, 0x00];
        assert_eq!(
            ParsedAttestation::parse(&trailing)
                .expect_err("trailing CBOR should fail")
                .category(),
            AppAttestFailureCategory::MalformedEvidence
        );
        trailing.clear();
        let duplicate = Value::Map(vec![
            (Value::Text("signature".to_owned()), Value::Bytes(vec![1])),
            (Value::Text("signature".to_owned()), Value::Bytes(vec![2])),
        ]);
        let encoded = URL_SAFE_NO_PAD
            .decode(encode_cbor(&duplicate))
            .expect("test CBOR should decode");
        assert_eq!(
            ParsedAssertion::parse(&encoded)
                .expect_err("duplicate fields should fail")
                .category(),
            AppAttestFailureCategory::MalformedEvidence
        );
        let unexpected_certificate = encode_cbor_bytes(&Value::Map(vec![
            (
                Value::Text("fmt".to_owned()),
                Value::Text("apple-appattest".to_owned()),
            ),
            (
                Value::Text("attStmt".to_owned()),
                Value::Map(vec![
                    (
                        Value::Text("x5c".to_owned()),
                        Value::Array(vec![
                            Value::Bytes(vec![1]),
                            Value::Bytes(vec![2]),
                            Value::Bytes(vec![3]),
                        ]),
                    ),
                    (Value::Text("receipt".to_owned()), Value::Bytes(vec![1])),
                ]),
            ),
            (Value::Text("authData".to_owned()), Value::Bytes(vec![1])),
        ]));
        assert_eq!(
            ParsedAttestation::parse(&unexpected_certificate)
                .expect_err("an unexpected certificate should fail")
                .category(),
            AppAttestFailureCategory::MalformedEvidence
        );
        assert_eq!(
            decode_evidence(
                &URL_SAFE_NO_PAD.encode(vec![0; MAX_DECODED_ASSERTION_BYTES + 1]),
                MAX_DECODED_ASSERTION_BYTES,
            )
            .expect_err("oversized evidence should fail")
            .category(),
            AppAttestFailureCategory::OversizedEvidence
        );
        assert_eq!(
            verify_certificate_chain(&[vec![0; 8], vec![0; 8]], &CertificateDer::from(vec![0; 8]))
                .expect_err("truncated certificates should fail")
                .category(),
            AppAttestFailureCategory::InvalidChain
        );
    }

    proptest! {
        #[test]
        fn hostile_attestation_and_assertion_bytes_never_panic(bytes in proptest::collection::vec(any::<u8>(), 0..4096)) {
            let _ = ParsedAttestation::parse(&bytes);
            let _ = ParsedAssertion::parse(&bytes);
            let _ = AttestationAuthenticatorData::parse(&bytes);
            let _ = AssertionAuthenticatorData::parse(&bytes);
        }
    }
}
