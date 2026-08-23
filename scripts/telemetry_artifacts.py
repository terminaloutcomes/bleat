#!/usr/bin/env python3
"""Redact and validate retained telemetry failure artifacts."""

from __future__ import annotations

import argparse
import re
import sys
from collections.abc import Iterable
from pathlib import Path


SECRET_PATTERNS = (
    re.compile(r"(postgres(?:ql)?://[^:\s]+:)[^@\s]+(?=@)", re.IGNORECASE),
    re.compile(
        r"(authorization:\s*bearer\s+)[A-Za-z0-9._-]+",
        re.IGNORECASE,
    ),
    re.compile(
        r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"
    ),
)


def redact(text: str) -> str:
    text = SECRET_PATTERNS[0].sub(r"\1[REDACTED]", text)
    text = SECRET_PATTERNS[1].sub(r"\1[REDACTED]", text)
    return SECRET_PATTERNS[2].sub("[REDACTED_JWT]", text)


def contains_secret(text: str) -> bool:
    return any(pattern.search(text) is not None for pattern in SECRET_PATTERNS)


def artifact_files(root: Path) -> Iterable[Path]:
    if root.is_file():
        yield root
    elif root.is_dir():
        yield from (path for path in root.rglob("*") if path.is_file())


def check_artifacts(root: Path) -> bool:
    for path in artifact_files(root):
        try:
            contents = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return False
        if contains_secret(contents):
            return False
    return True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("redact", help="redact text read from standard input")
    check_parser = subparsers.add_parser(
        "check", help="check retained artifacts for unredacted secrets"
    )
    check_parser.add_argument("path", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.command == "redact":
        sys.stdout.write(redact(sys.stdin.read()))
        return 0
    if check_artifacts(args.path):
        return 0
    print("Unsafe telemetry failure artifacts were detected", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
