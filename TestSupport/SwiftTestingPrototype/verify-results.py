"""Verify individual prototype outcomes, including the intentional skip."""

import sys
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path


EXPECTED = {
    "synchronousIdentity()",
    "typedThrowingValidation()",
    "bundledFixture()",
    "concurrentActorCalls()",
    "intentionalSkip()",
    "swiftDataAccountIsolation()",
    "timedTranscriptRoundTrip()",
}


def verify(path: Path) -> None:
    root = ET.parse(path).getroot()
    cases = root.findall(".//testcase")
    names = Counter(case.get("name") for case in cases)
    if names != Counter(EXPECTED):
        raise ValueError(f"Unexpected, missing, or duplicate test identifiers: {names}")
    if root.findall(".//failure") or root.findall(".//error"):
        raise ValueError("Prototype contains failed tests")
    skipped = {case.get("name") for case in cases if case.find("skipped") is not None}
    if skipped != {"intentionalSkip()"}:
        raise ValueError(f"Unexpected skipped tests: {skipped}")
    for case in sorted(cases, key=lambda item: item.get("name", "")):
        outcome = "skipped" if case.find("skipped") is not None else "passed"
        print(f"{case.get('name')}: {outcome}")
    print("Verified 7 distinct tests: 6 passed, 1 intentional skip")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: python3 verify-results.py RESULTS.xml")
    try:
        verify(Path(sys.argv[1]))
    except (OSError, ET.ParseError, ValueError) as error:
        sys.exit(str(error))
