import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).parents[2] / "scripts" / "scan-release-secrets.py"
SPEC = importlib.util.spec_from_file_location("scan_release_secrets", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
SCANNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCANNER)


class ReleaseSecretScannerTests(unittest.TestCase):
    def test_every_supported_representation_is_detected(self):
        secret = 'sentinel-!"\\/+% unicode-羊-0123456789'
        for name, value in SCANNER.representations(secret).items():
            with self.subTest(representation=name):
                findings = SCANNER.scan_bytes(value, {"fixture": secret})
                self.assertTrue(findings, name)
                self.assertTrue(
                    any(finding[0] == "fixture" for finding in findings)
                )

    def test_safe_surface_has_zero_matches(self):
        findings = SCANNER.scan_bytes(
            b"typed failure code=network.transport stage=library status=failed",
            {"password": "private-password-0123456789"},
        )
        self.assertEqual(findings, [])

    def test_private_server_artifact_is_redacted_before_scanning(self):
        secret = "private-refresh-token-0123456789"
        original = f"refreshToken: '{secret}'".encode()
        redacted, redactions = SCANNER.redact_bytes(
            original, {"refresh-token": secret}
        )
        self.assertNotIn(secret.encode(), redacted)
        self.assertEqual(
            redactions,
            [("refresh-token", "raw-utf8", 1)],
        )
        self.assertEqual(
            SCANNER.scan_bytes(redacted, {"refresh-token": secret}), []
        )

    def test_token_query_parameters_are_detected_without_a_sentinel(self):
        self.assertEqual(
            SCANNER.policy_findings(b"https://books.example/file?accessToken=x"),
            [("token-query-parameter", "raw-utf8", 1)],
        )

    def test_report_never_contains_values_or_digests(self):
        secret = "private-password-0123456789"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "safe.log").write_text("status=passed", encoding="utf-8")
            findings, file_count, byte_count = SCANNER.scan_surfaces(
                [("logs", root)], {"password": secret}
            )
            report = {
                "secretLabels": ["password"],
                "scannedFileCount": file_count,
                "scannedByteCount": byte_count,
                "findings": findings,
            }
            encoded = json.dumps(report)
            self.assertNotIn(secret, encoded)
            self.assertEqual(findings, [])


if __name__ == "__main__":
    unittest.main()
