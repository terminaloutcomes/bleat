#!/usr/bin/env python3
"""Scan named release surfaces for private sentinel representations."""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import re
import sys
from urllib.parse import quote


def representations(value: str) -> dict[str, bytes]:
    raw = value.encode("utf-8")
    encoded = {
        "raw-utf8": raw,
        "authorization-bearer": f"Bearer {value}".encode("utf-8"),
        "url-percent": quote(value, safe="").encode("ascii"),
        "json-escaped": json.dumps(value, ensure_ascii=False)[1:-1].encode(
            "utf-8"
        ),
        "base64": base64.b64encode(raw),
        "base64url-padded": base64.urlsafe_b64encode(raw),
        "base64url-unpadded": base64.urlsafe_b64encode(raw).rstrip(b"="),
        "utf16-le": value.encode("utf-16-le"),
        "utf16-be": value.encode("utf-16-be"),
        "utf16-le-bom": value.encode("utf-16"),
        "utf16-be-bom": b"\xfe\xff" + value.encode("utf-16-be"),
    }
    return {name: pattern for name, pattern in encoded.items() if pattern}


def load_secrets(manifests: list[Path]) -> dict[str, str]:
    secrets: dict[str, str] = {}
    for manifest in manifests:
        payload = json.loads(manifest.read_text(encoding="utf-8"))
        for entry in payload.get("secrets", []):
            label = entry.get("label")
            value = entry.get("value")
            if not isinstance(label, str) or not label:
                raise ValueError(f"invalid secret label in {manifest.name}")
            if not isinstance(value, str) or len(value.encode("utf-8")) < 16:
                raise ValueError(
                    f"secret {label!r} in {manifest.name} is too short"
                )
            if label in secrets and secrets[label] != value:
                raise ValueError(f"conflicting secret label {label!r}")
            secrets[label] = value
    if not secrets:
        raise ValueError("no secrets were supplied")
    return secrets


def iter_files(root: Path):
    if root.is_file():
        yield root, Path(root.name)
        return
    for directory, names, filenames in os.walk(root, followlinks=False):
        names[:] = sorted(name for name in names if not Path(directory, name).is_symlink())
        for filename in sorted(filenames):
            path = Path(directory, filename)
            if path.is_file() and not path.is_symlink():
                yield path, path.relative_to(root)


def scan_bytes(
    data: bytes, secrets: dict[str, str]
) -> list[tuple[str, str, int]]:
    findings: list[tuple[str, str, int]] = []
    for label, value in secrets.items():
        seen: set[bytes] = set()
        for representation, pattern in representations(value).items():
            if pattern in seen:
                continue
            seen.add(pattern)
            count = data.count(pattern)
            if count:
                findings.append((label, representation, count))
    return findings


def redact_bytes(
    data: bytes, secrets: dict[str, str]
) -> tuple[bytes, list[tuple[str, str, int]]]:
    redactions: list[tuple[str, str, int]] = []
    for label, value in secrets.items():
        patterns = sorted(
            representations(value).items(),
            key=lambda item: len(item[1]),
            reverse=True,
        )
        seen: set[bytes] = set()
        for representation, pattern in patterns:
            if pattern in seen:
                continue
            seen.add(pattern)
            count = data.count(pattern)
            if not count:
                continue
            replacement = f"[REDACTED:{label}:{representation}]".encode()
            data = data.replace(pattern, replacement)
            redactions.append((label, representation, count))
    return data, redactions


def redact_surfaces(
    surfaces: list[tuple[str, Path]], secrets: dict[str, str]
) -> list[dict[str, object]]:
    redactions: list[dict[str, object]] = []
    for surface, root in surfaces:
        if not root.exists():
            raise FileNotFoundError(f"surface {surface!r} does not exist")
        for path, relative_path in iter_files(root):
            original = path.read_bytes()
            redacted, matches = redact_bytes(original, secrets)
            if redacted != original:
                path.write_bytes(redacted)
            for label, representation, count in matches:
                redactions.append(
                    {
                        "surface": surface,
                        "path": relative_path.as_posix(),
                        "label": label,
                        "representation": representation,
                        "count": count,
                    }
                )
    return redactions


def policy_findings(data: bytes) -> list[tuple[str, str, int]]:
    findings: list[tuple[str, str, int]] = []
    for representation, pattern in {
        "raw-utf8": rb"(?i)[?&](?:access_?token|refresh_?token)=",
        "utf16-le": (
            rb"(?i)(?:\?\x00|&\x00)"
            rb"(?:a\x00c\x00c\x00e\x00s\x00s\x00_?\x00?"
            rb"t\x00o\x00k\x00e\x00n\x00|"
            rb"r\x00e\x00f\x00r\x00e\x00s\x00h\x00_?\x00?"
            rb"t\x00o\x00k\x00e\x00n\x00)=\x00"
        ),
    }.items():
        count = len(re.findall(pattern, data))
        if count:
            findings.append(("token-query-parameter", representation, count))
    return findings


def scan_surfaces(
    surfaces: list[tuple[str, Path]], secrets: dict[str, str]
) -> tuple[list[dict[str, object]], int, int]:
    findings: list[dict[str, object]] = []
    file_count = 0
    byte_count = 0
    for surface, root in surfaces:
        if not root.exists():
            raise FileNotFoundError(f"surface {surface!r} does not exist")
        for path, relative_path in iter_files(root):
            data = path.read_bytes()
            file_count += 1
            byte_count += len(data)
            for label, representation, count in scan_bytes(data, secrets):
                findings.append(
                    {
                        "surface": surface,
                        "path": relative_path.as_posix(),
                        "label": label,
                        "representation": representation,
                        "count": count,
                    }
                )
            for label, representation, count in policy_findings(data):
                findings.append(
                    {
                        "surface": surface,
                        "path": relative_path.as_posix(),
                        "label": label,
                        "representation": representation,
                        "count": count,
                    }
                )
    return findings, file_count, byte_count


def parse_surface(value: str) -> tuple[str, Path]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("surface must be LABEL=PATH")
    label, raw_path = value.split("=", 1)
    if not label or not raw_path:
        raise argparse.ArgumentTypeError("surface must be LABEL=PATH")
    return label, Path(raw_path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", action="append", required=True, type=Path)
    parser.add_argument("--surface", action="append", required=True, type=parse_surface)
    parser.add_argument("--redact-surface", action="append", type=parse_surface)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()

    try:
        secrets = load_secrets(args.manifest)
        redactions = redact_surfaces(args.redact_surface or [], secrets)
        findings, file_count, byte_count = scan_surfaces(args.surface, secrets)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"Release secret scan could not run: {error}", file=sys.stderr)
        return 2

    report = {
        "status": "failed" if findings else "passed",
        "secretLabels": sorted(secrets),
        "surfaceLabels": [label for label, _ in args.surface],
        "redactedSurfaceLabels": [
            label for label, _ in (args.redact_surface or [])
        ],
        "redactionCount": sum(
            int(redaction["count"]) for redaction in redactions
        ),
        "redactions": redactions,
        "scannedFileCount": file_count,
        "scannedByteCount": byte_count,
        "findingCount": sum(int(finding["count"]) for finding in findings),
        "findings": findings,
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(
        f"Scanned {file_count} files across {len(args.surface)} surfaces; "
        f"found {report['findingCount']} prohibited sentinel matches."
    )
    if findings:
        for finding in findings:
            print(
                "match "
                f"surface={finding['surface']} path={finding['path']} "
                f"label={finding['label']} "
                f"representation={finding['representation']} "
                f"count={finding['count']}",
                file=sys.stderr,
            )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
