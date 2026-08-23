# Apple App Attest validation fixture

`2026-validation-guide-authenticator-data.b64` is the `authData` byte string
extracted without modification from the public attestation object in Apple's
[Attestation Object Validation Guide](https://developer.apple.com/documentation/devicecheck/attestation-object-validation-guide).
It is test data published by Apple, not evidence captured from a Bleat device.

The fixture is the compatibility contract for the production authenticator-data
parser's iOS 27-and-later extension shape. Its regression test checks the
guide's fields together:

- SHA-256 of `1234567890.com.example.myapp` matches the RP ID hash;
- the counter is zero and the AAGUID selects production;
- the credential ID matches the guide's key ID;
- the parsed COSE P-256 public key hashes to that credential ID;
- `apple_validation_category_01` is decoded from Apple's four-byte
  little-endian CBOR byte string; and
- `apple_bundle_version_01` is decoded as CBOR text.

Apple’s WWDC26 App Attest session states that the appended extension structure
starts in iOS 27. The parser also accepts the extension-free authenticator data
produced by earlier supported Apple operating systems; a separate synthetic
production-verifier regression covers both enrollment and assertion evidence
in that form. When extensions are present, they must match this fixture's exact
structure and the configured application policy.

The supported production client emits `0x40` in the flag byte of Apple's
simplified assertion authenticator data. The assertion parser requires that
exact Apple value and deliberately does not apply WebAuthn assertion flag
semantics to it. Extension presence is determined from the remaining Apple
authenticator-data bytes, whose CBOR shape is validated independently. This is
a structural observation only; no device assertion, key, identifier, or other
device-specific evidence is retained in the repository.

Keep the raw bytes unchanged. If Apple publishes a materially different fixture,
add a new dated file and a separate regression case before changing the parser.
Do not replace this with a locally captured attestation, because that would put
device-specific App Attest evidence in the repository.

The complete attestation object is not retained as a permanent end-to-end
verifier fixture. Its leaf certificate has a short validity period, so verifying
that object against the current time would make the suite expire. Synthetic
production-verifier tests cover certificate-chain, nonce-extension, policy,
credential binding, and assertion-signature checks with controlled certificate
validity; this public fixture covers Apple's exact authenticator-data encoding.
