"""Verify host test identities and normalize LLVM's LCOV for Coveralls."""

import argparse
from collections import Counter
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

ENTITLEMENT_SKIP = (
    "BleatCoreTests.TokenVaultTests",
    "testDeleteAllCredentialsRemovesNativeLoginAfterICloudKeychainIsDisabled()",
)


def verify_results(report: Path, inventory: Path) -> tuple[int, int]:
    expected = Counter(
        (suite, name)
        for suite, names in json.loads(inventory.read_text()).items()
        for name in names
    )
    if not expected or any(count != 1 for count in expected.values()):
        raise ValueError("Test inventory is empty or contains duplicate identities")
    root = ET.parse(report).getroot()
    cases = root.findall(".//testcase")
    actual = Counter((case.get("classname"), case.get("name")) for case in cases)
    if actual != expected:
        raise ValueError(
            f"Missing tests: {expected - actual}; unexpected/duplicate tests: {actual - expected}"
        )
    if root.findall(".//failure") or root.findall(".//error"):
        raise ValueError("Host results contain failures")
    skipped = 0
    for case in cases:
        skip = case.find("skipped")
        if skip is not None:
            identity = (case.get("classname"), case.get("name"))
            if identity != ENTITLEMENT_SKIP or "iCloud Keychain entitlement" not in (skip.text or ""):
                raise ValueError(f"Unexpected skip: {identity}")
            skipped += 1
    return len(cases) - skipped, skipped


def normalize_lcov(raw: str, repository: Path) -> str:
    """Keep production Swift sources only, with portable project-relative paths."""
    output = []
    seen = set()
    covered = Counter()
    executable = Counter()
    repository = repository.resolve()
    for record in raw.split("end_of_record"):
        lines = record.strip().splitlines()
        sources = [line[3:] for line in lines if line.startswith("SF:")]
        if not sources:
            if lines:
                raise ValueError("LCOV record has no source")
            continue
        if len(sources) != 1:
            raise ValueError("LCOV record has multiple sources")
        source = Path(sources[0])
        if not source.is_absolute():
            source = repository / source
        try:
            relative = source.resolve().relative_to(repository)
        except ValueError:
            continue
        if len(relative.parts) < 3 or relative.parts[:2] not in (
            ("Sources", "BleatCore"), ("Sources", "BleatTranscription")
        ):
            continue
        if relative in seen:
            raise ValueError(f"Duplicate LCOV source: {relative}")
        seen.add(relative)
        module = relative.parts[1]
        line_numbers = set()
        for line in lines:
            if line.startswith("DA:"):
                fields = line[3:].split(",")
                number, hits = int(fields[0]), int(fields[1])
                if number <= 0 or hits < 0 or number in line_numbers:
                    raise ValueError(f"Invalid or duplicate line coverage: {relative}")
                line_numbers.add(number)
                executable[module] += 1
                covered[module] += hits > 0
        output.extend(
            f"SF:{relative.as_posix()}" if line.startswith("SF:") else line
            for line in lines
        )
        output.append("end_of_record")
    for module in ("BleatCore", "BleatTranscription"):
        if executable[module] == 0 or covered[module] == 0:
            raise ValueError(f"No executed production line coverage for {module}")
    return "\n".join(output) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    results = sub.add_parser("results")
    results.add_argument("inventory", type=Path)
    results.add_argument("output", type=Path)
    results.add_argument("reports", nargs="+", type=Path)
    coverage = sub.add_parser("coverage")
    coverage.add_argument("raw", type=Path)
    coverage.add_argument("repository", type=Path)
    coverage.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "results":
            combined = ET.Element("testsuites")
            for report in args.reports:
                combined.extend(ET.parse(report).getroot())
            ET.ElementTree(combined).write(args.output, encoding="utf-8", xml_declaration=True)
            passed, skipped = verify_results(args.output, args.inventory)
            print(f"Verified host tests: {passed} passed, {skipped} entitlement skips")
        else:
            normalized = normalize_lcov(args.raw.read_text(), args.repository)
            args.output.write_text(normalized)
            print("Exported host LCOV with executed BleatCore and BleatTranscription coverage")
    except (OSError, ValueError, ET.ParseError) as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
