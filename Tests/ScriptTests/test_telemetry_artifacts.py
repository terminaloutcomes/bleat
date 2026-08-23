from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "scripts"))

from telemetry_artifacts import check_artifacts, contains_secret, redact


class TelemetryArtifactTests(unittest.TestCase):
    def test_redacts_database_password_authorization_and_jwt(self) -> None:
        raw_jwt = "eyJheader_value.payload-value.signature_value"
        source = (
            "postgresql://bleat:database-secret@postgres/bleat\n"
            f"Authorization: Bearer {raw_jwt}\n"
            f"token={raw_jwt}\n"
        )

        redacted = redact(source)

        self.assertNotIn("database-secret", redacted)
        self.assertNotIn(raw_jwt, redacted)
        self.assertIn("postgresql://bleat:[REDACTED]@postgres/bleat", redacted)
        self.assertIn("Authorization: Bearer [REDACTED]", redacted)
        self.assertIn("token=[REDACTED_JWT]", redacted)

    def test_detects_raw_jwt(self) -> None:
        self.assertTrue(
            contains_secret("eyJheader_value.payload-value.signature_value")
        )

    def test_accepts_redacted_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "containers.log"
            artifact.write_text(
                "Authorization: Bearer [REDACTED]\n",
                encoding="utf-8",
            )

            self.assertTrue(check_artifacts(Path(directory)))

    def test_rejects_artifacts_containing_a_secret(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "containers.log"
            artifact.write_text(
                "postgres://bleat:database-secret@postgres/bleat\n",
                encoding="utf-8",
            )

            self.assertFalse(check_artifacts(Path(directory)))


if __name__ == "__main__":
    unittest.main()
