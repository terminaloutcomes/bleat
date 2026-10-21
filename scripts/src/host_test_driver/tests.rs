use super::{Error, SigningIdentityField, verify_entitlements};
fn encoded(dictionary: &plist::Dictionary) -> Vec<u8> {
    let mut bytes = Vec::new();
    plist::Value::Dictionary(dictionary.clone())
        .to_writer_xml(&mut bytes)
        .expect("synthetic entitlements");
    bytes
}
#[test]
fn signed_entitlements_require_exact_team_application_and_keychain_group() {
    let identity = "fixture-team.com.terminaloutcomes.Bleat.HostTests";
    let mut original = plist::Dictionary::new();
    original.insert(
        "com.apple.developer.team-identifier".to_owned(),
        "fixture-team".into(),
    );
    original.insert(
        "com.apple.application-identifier".to_owned(),
        identity.into(),
    );
    original.insert(
        "keychain-access-groups".to_owned(),
        plist::Value::Array(vec![identity.into()]),
    );
    assert!(verify_entitlements(&encoded(&original), "fixture-team").is_ok());
    for (key, replacement, expected) in [
        (
            "com.apple.developer.team-identifier",
            plist::Value::String("other-team".to_owned()),
            SigningIdentityField::Team,
        ),
        (
            "com.apple.application-identifier",
            plist::Value::String("other-application".to_owned()),
            SigningIdentityField::Application,
        ),
        (
            "keychain-access-groups",
            plist::Value::Array(vec![identity.into(), "extra-group".into()]),
            SigningIdentityField::KeychainGroups,
        ),
    ] {
        let mut invalid = original.clone();
        invalid.insert(key.to_owned(), replacement);
        let error = verify_entitlements(&encoded(&invalid), "fixture-team")
            .expect_err("specific identity mismatch");
        assert!(matches!(
            (error, expected),
            (
                Error::EntitlementsIdentity(SigningIdentityField::Team),
                SigningIdentityField::Team
            ) | (
                Error::EntitlementsIdentity(SigningIdentityField::Application),
                SigningIdentityField::Application
            ) | (
                Error::EntitlementsIdentity(SigningIdentityField::KeychainGroups),
                SigningIdentityField::KeychainGroups
            )
        ));
    }
    assert!(matches!(
        verify_entitlements(b"not a plist", "fixture-team"),
        Err(Error::EntitlementsFormat)
    ));
}
