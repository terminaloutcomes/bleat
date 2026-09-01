#!/usr/bin/env python3

"""Regression tests for Bleat's tracked CloudKit schema validator.

These tests exercise the structural schema, code-record consistency, production
parity, and private-database source policies without contacting CloudKit. They
exist so changes to the release gate cannot silently weaken the safeguards that
prevent missing production record types or public/shared database access.
"""

import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("validate-cloudkit-schema.py")
SPEC = importlib.util.spec_from_file_location("validate_cloudkit_schema", SCRIPT_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load CloudKit schema validator")
VALIDATOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VALIDATOR
SPEC.loader.exec_module(VALIDATOR)


def schema(*record_types: str) -> str:
    records = []
    for record_type in record_types:
        records.append(
            f'''RECORD TYPE {record_type} (
                payload BYTES QUERYABLE SORTABLE,
                GRANT WRITE TO "_creator",
                GRANT CREATE TO "_icloud",
                GRANT READ TO "_world"
            );'''
        )
    return "DEFINE SCHEMA\n" + "\n".join(records)


class CloudKitSchemaValidatorTests(unittest.TestCase):
    def test_private_database_access_policy_accepts_private_scope(self) -> None:
        VALIDATOR.validate_private_database_access(
            {
                "Sources/Sync.swift":
                    "let database = container.privateCloudDatabase"
            }
        )

    def test_private_database_access_policy_rejects_public_scope(self) -> None:
        with self.assertRaisesRegex(
            VALIDATOR.SchemaValidationFailure,
            "production CloudKit access must remain private-only",
        ):
            VALIDATOR.validate_private_database_access(
                {
                    "Sources/Sync.swift":
                        "let database = container.publicCloudDatabase"
                }
            )

    def test_matching_code_and_schema_are_valid(self) -> None:
        parsed = VALIDATOR.validate_desired_schema(
            schema("Configuration"),
            'record(type: "Configuration")',
        )
        self.assertEqual(set(parsed), {"Configuration"})

    def test_missing_code_record_type_is_rejected(self) -> None:
        with self.assertRaisesRegex(
            VALIDATOR.SchemaValidationFailure,
            "missing code record types: RemoteListeningSession",
        ):
            VALIDATOR.validate_desired_schema(
                schema("Configuration"),
                'record(type: "Configuration")\n'
                'record(type: "RemoteListeningSession")',
            )

    def test_invalid_payload_contract_is_rejected(self) -> None:
        invalid = schema("Configuration").replace(
            "payload BYTES QUERYABLE SORTABLE",
            "payload STRING",
        )
        with self.assertRaisesRegex(
            VALIDATOR.SchemaValidationFailure,
            "payload BYTES QUERYABLE SORTABLE",
        ):
            VALIDATOR.validate_desired_schema(
                invalid,
                'record(type: "Configuration")',
            )

    def test_production_drift_is_reported_structurally(self) -> None:
        desired_text = schema("Configuration", "RemoteListeningSession")
        desired = VALIDATOR.validate_desired_schema(
            desired_text,
            'record(type: "Configuration")\n'
            'record(type: "RemoteListeningSession")',
        )
        with self.assertRaisesRegex(
            VALIDATOR.SchemaValidationFailure,
            "missing record types: RemoteListeningSession",
        ):
            VALIDATOR.validate_production_schema(
                desired,
                schema("Configuration"),
            )


if __name__ == "__main__":
    unittest.main()
