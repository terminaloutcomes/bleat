#!/usr/bin/env python3

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


class SchemaValidationFailure(Exception):
    pass


@dataclass(frozen=True)
class Field:
    data_type: str
    options: frozenset[str]


@dataclass(frozen=True)
class RecordType:
    fields: tuple[tuple[str, Field], ...]
    grants: frozenset[tuple[str, str]]


SCHEMA_RECORD_PATTERN = re.compile(
    r"\bRECORD\s+TYPE\s+([A-Za-z][A-Za-z0-9_]*)\s*\((.*?)\)\s*;",
    re.DOTALL,
)
FIELD_PATTERN = re.compile(
    r'^\s*(?:"([^"]+)"|([A-Za-z][A-Za-z0-9_]*))\s+'
    r"([A-Z]+(?:<[A-Z0-9]+>)?)"
    r"((?:\s+(?:QUERYABLE|SORTABLE|SEARCHABLE))*)\s*,?\s*$"
)
GRANT_PATTERN = re.compile(
    r'^\s*GRANT\s+(READ|CREATE|WRITE)\s+TO\s+"([^"]+)"\s*,?\s*$'
)
SOURCE_RECORD_PATTERNS = (
    re.compile(r'\btype:\s*"([A-Z][A-Za-z0-9_]*)"'),
    re.compile(r'\brecordType:\s*"([A-Z][A-Za-z0-9_]*)"'),
)
SYSTEM_RECORD_TYPES = frozenset({"Users"})
PAYLOAD_FIELD = Field("BYTES", frozenset({"QUERYABLE", "SORTABLE"}))
PRIVATE_RECORD_GRANTS = frozenset(
    {
        ("WRITE", "_creator"),
        ("CREATE", "_icloud"),
        ("READ", "_world"),
    }
)
# CloudKit entitlements authorize a container, not an individual database
# scope. Keep this source gate so future production code cannot bypass Bleat's
# private-database boundary and expose records through the public/shared APIs.
FORBIDDEN_DATABASE_ACCESS_PATTERNS = (
    (re.compile(r"\.publicCloudDatabase\b"), "publicCloudDatabase"),
    (re.compile(r"\.sharedCloudDatabase\b"), "sharedCloudDatabase"),
    (
        re.compile(
            r"\.database\s*\(\s*with:\s*\.(?:public|shared)\b"
        ),
        "database(with: public/shared)",
    ),
)


def without_comments(value: str) -> str:
    value = re.sub(r"/\*.*?\*/", "", value, flags=re.DOTALL)
    value = re.sub(r"//.*?$", "", value, flags=re.MULTILINE)
    return re.sub(r"--.*?$", "", value, flags=re.MULTILINE)


def parse_schema(value: str) -> dict[str, RecordType]:
    schema = without_comments(value)
    if not re.search(r"\bDEFINE\s+SCHEMA\b", schema):
        raise SchemaValidationFailure("schema does not declare DEFINE SCHEMA")
    records: dict[str, RecordType] = {}
    for name, body in SCHEMA_RECORD_PATTERN.findall(schema):
        if name in records:
            raise SchemaValidationFailure(f"schema repeats record type {name}")
        fields: dict[str, Field] = {}
        grants: set[tuple[str, str]] = set()
        for line in body.splitlines():
            if not line.strip():
                continue
            if match := FIELD_PATTERN.fullmatch(line):
                field_name = match.group(1) or match.group(2)
                if field_name in fields:
                    raise SchemaValidationFailure(
                        f"record type {name} repeats field {field_name}"
                    )
                fields[field_name] = Field(
                    match.group(3),
                    frozenset(match.group(4).split()),
                )
                continue
            if match := GRANT_PATTERN.fullmatch(line):
                grants.add((match.group(1), match.group(2)))
                continue
            raise SchemaValidationFailure(
                f"record type {name} contains an unsupported declaration"
            )
        records[name] = RecordType(tuple(sorted(fields.items())), frozenset(grants))
    if not records:
        raise SchemaValidationFailure("schema declares no record types")
    return records


def source_record_types(value: str) -> set[str]:
    return {
        match.group(1)
        for pattern in SOURCE_RECORD_PATTERNS
        for match in pattern.finditer(value)
    }


def format_names(values: set[str]) -> str:
    return ", ".join(sorted(values))


def validate_private_database_access(sources: dict[str, str]) -> None:
    violations: list[str] = []
    for path, source in sorted(sources.items()):
        for pattern, description in FORBIDDEN_DATABASE_ACCESS_PATTERNS:
            if pattern.search(source):
                violations.append(f"{path}: {description}")
    if violations:
        raise SchemaValidationFailure(
            "production CloudKit access must remain private-only ("
            + "; ".join(violations)
            + ")"
        )


def validate_desired_schema(schema: str, source: str) -> dict[str, RecordType]:
    records = parse_schema(schema)
    desired_types = set(records) - SYSTEM_RECORD_TYPES
    code_types = source_record_types(source)
    if missing := code_types - desired_types:
        raise SchemaValidationFailure(
            "CloudKit/Bleat.ckdb is missing code record types: "
            + format_names(missing)
        )
    if unused := desired_types - code_types:
        raise SchemaValidationFailure(
            "CloudKit/Bleat.ckdb contains unused app record types: "
            + format_names(unused)
        )
    for name in sorted(desired_types):
        record = records[name]
        fields = dict(record.fields)
        if fields.get("payload") != PAYLOAD_FIELD:
            raise SchemaValidationFailure(
                f"CloudKit record type {name} must contain payload BYTES QUERYABLE SORTABLE"
            )
        if record.grants != PRIVATE_RECORD_GRANTS:
            raise SchemaValidationFailure(
                f"CloudKit record type {name} has unexpected grants"
            )
    return records


def validate_production_schema(
    desired: dict[str, RecordType], production_schema: str
) -> None:
    production = parse_schema(production_schema)
    if desired == production:
        return
    desired_names = set(desired)
    production_names = set(production)
    details: list[str] = []
    if missing := desired_names - production_names:
        details.append("missing record types: " + format_names(missing))
    if unexpected := production_names - desired_names:
        details.append("unexpected record types: " + format_names(unexpected))
    changed = {
        name
        for name in desired_names & production_names
        if desired[name] != production[name]
    }
    if changed:
        details.append("changed record types: " + format_names(changed))
    raise SchemaValidationFailure(
        "CloudKit/Production.ckdb does not match the desired schema ("
        + "; ".join(details)
        + "). Deploy the development schema, then replace the production snapshot."
    )


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(
        description="Validate Bleat's tracked CloudKit schemas"
    )
    parser.add_argument(
        "--require-production",
        action="store_true",
        help="also require the verified production snapshot to match",
    )
    arguments = parser.parse_args()
    try:
        swift_sources = {
            path.relative_to(repository).as_posix(): path.read_text()
            for directory in (repository / "App", repository / "Sources")
            for path in directory.rglob("*.swift")
        }
        validate_private_database_access(swift_sources)
        desired = validate_desired_schema(
            (repository / "CloudKit/Bleat.ckdb").read_text(),
            (repository / "Sources/BleatCore/PrivateCloudSync.swift").read_text(),
        )
        if arguments.require_production:
            validate_production_schema(
                desired,
                (repository / "CloudKit/Production.ckdb").read_text(),
            )
    except (OSError, UnicodeError, SchemaValidationFailure) as error:
        print(f"CloudKit schema validation failed: {error}", file=sys.stderr)
        return 1
    scope = "desired and production schemas" if arguments.require_production else "desired schema"
    print(f"CloudKit {scope} validated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
