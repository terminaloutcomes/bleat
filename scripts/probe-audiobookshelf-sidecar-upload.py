#!/usr/bin/env python3
"""Probe v2.36.0 generic upload behavior using disposable Audiobookshelf data.


#Validate the pinned server's generic upload behavior for a VTT sidecar with

The probe uses a disposable writable media copy. It uploads a VTT beside a
conventionally named item, downloads it through the authenticated item-file
route, and verifies that the returned bytes match the upload exactly.
Discovering the uploaded file's inode may require the existing item to be
rescanned.
"""

from __future__ import annotations

import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.error import HTTPError
from urllib.request import Request, urlopen

PROBE_AUTHOR = "Bleat Upload Probe Author"
PROBE_SERIES = "Bleat Upload Probe Series"
PROBE_TITLE = "Bleat Upload Probe Book"
PROBE_AUDIO_FILENAME = "01.m4b"
PROBE_VTT_FILENAME = "bleat-sidecar-probe.vtt"
PROBE_VTT = b"WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nBleat upload probe\n"
ITEM_POLL_TIMEOUT_SECONDS = 75
WATCHER_POLL_TIMEOUT_SECONDS = 30
POLL_INTERVAL_SECONDS = 1


class ProbeFailure(RuntimeError):
    """A source-contract assertion made by the probe failed."""


@dataclass(frozen=True)
class HTTPResult:
    status: int
    body: bytes


def available_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def request(
    url: str,
    *,
    method: str = "GET",
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
) -> HTTPResult:
    request_headers = headers.copy() if headers else {}
    http_request = Request(url, data=body, headers=request_headers, method=method)
    try:
        with urlopen(http_request, timeout=15) as response:
            return HTTPResult(status=response.status, body=response.read())
    except HTTPError as error:
        return HTTPResult(status=error.code, body=error.read())


def request_json(
    url: str,
    *,
    method: str = "GET",
    payload: dict[str, Any] | None = None,
    headers: dict[str, str] | None = None,
) -> tuple[HTTPResult, Any]:
    request_headers = headers.copy() if headers else {}
    body = None
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        request_headers["Content-Type"] = "application/json"
    result = request(url, method=method, body=body, headers=request_headers)
    try:
        return result, json.loads(result.body)
    except json.JSONDecodeError as error:
        raise ProbeFailure(
            f"{method} {url} returned non-JSON status {result.status}"
        ) from error


def multipart_body(
    fields: dict[str, str], filename: str, contents: bytes
) -> tuple[str, bytes]:
    boundary = f"----bleat-sidecar-probe-{secrets.token_hex(12)}"
    parts: list[bytes] = []
    for name, value in fields.items():
        parts.extend(
            [
                f"--{boundary}\r\n".encode("ascii"),
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode(),
                value.encode("utf-8"),
                b"\r\n",
            ]
        )
    parts.extend(
        [
            f"--{boundary}\r\n".encode("ascii"),
            (
                f'Content-Disposition: form-data; name="0"; filename="{filename}"\r\n'
            ).encode(),
            b"Content-Type: text/vtt\r\n\r\n",
            contents,
            b"\r\n",
            f"--{boundary}--\r\n".encode("ascii"),
        ]
    )
    return boundary, b"".join(parts)


def command_environment(media_root: Path) -> tuple[dict[str, str], str, str]:
    environment = os.environ.copy()
    root_port, prefix_port, https_root_port, https_prefix_port, oidc_https_port = (
        available_port() for _ in range(5)
    )
    project_name = f"bleat-sidecar-upload-{secrets.token_hex(6)}"
    username = f"bleat-upload-{secrets.token_hex(8)}"
    password = secrets.token_urlsafe(32)
    environment.update(
        {
            "BLEAT_COMPOSE_PROJECT_NAME": project_name,
            "BLEAT_TEST_USERNAME": username,
            "BLEAT_TEST_PASSWORD": password,
            "BLEAT_MEDIA_ROOT": str(media_root),
            "BLEAT_MEDIA_ACCESS_MODE": "rw",
            "BLEAT_ABS_ROOT_PORT": str(root_port),
            "BLEAT_ABS_PREFIX_PORT": str(prefix_port),
            "BLEAT_HTTPS_ROOT_PORT": str(https_root_port),
            "BLEAT_HTTPS_PREFIX_PORT": str(https_prefix_port),
            "BLEAT_OIDC_HTTPS_PORT": str(oidc_https_port),
        }
    )
    return environment, username, f"http://127.0.0.1:{root_port}"


def run_environment(script: Path, environment: dict[str, str], action: str) -> None:
    subprocess.run([str(script), action], check=True, env=environment)


def bearer_headers(access_token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {access_token}"}


def login(base_url: str, username: str, password: str) -> str:
    result, payload = request_json(
        f"{base_url}/login",
        method="POST",
        payload={"username": username, "password": password},
        headers={"x-return-tokens": "true"},
    )
    if result.status != 200:
        raise ProbeFailure(f"login returned status {result.status}")
    access_token = payload.get("user", {}).get("accessToken")
    if not isinstance(access_token, str) or not access_token:
        raise ProbeFailure("login response did not include an access token")
    return access_token


def probe_library(base_url: str, headers: dict[str, str]) -> tuple[str, str]:
    result, payload = request_json(f"{base_url}/api/libraries", headers=headers)
    if result.status != 200:
        raise ProbeFailure(f"library lookup returned status {result.status}")
    for library in payload.get("libraries", []):
        if library.get("name") != "Bleat Live Fixtures":
            continue
        folders = library.get("folders") or library.get("libraryFolders") or []
        if not folders or not isinstance(folders[0].get("id"), str):
            raise ProbeFailure("fixture library did not expose a folder ID")
        return library["id"], folders[0]["id"]
    raise ProbeFailure("fixture library was not found")


def wait_for_item(
    base_url: str,
    library_id: str,
    headers: dict[str, str],
) -> dict[str, Any]:
    expected_rel_path = f"{PROBE_AUTHOR}/{PROBE_SERIES}/{PROBE_TITLE}"
    deadline = time.monotonic() + ITEM_POLL_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        result, payload = request_json(
            f"{base_url}/api/libraries/{library_id}/items?limit=100&page=0",
            headers=headers,
        )
        if result.status != 200:
            raise ProbeFailure(f"item lookup returned status {result.status}")
        for item in payload.get("results", []):
            if item.get("relPath") == expected_rel_path:
                return item
        time.sleep(POLL_INTERVAL_SECONDS)
    raise ProbeFailure("conventional probe item was not scanned")


def expanded_item(
    base_url: str, item_id: str, headers: dict[str, str]
) -> dict[str, Any]:
    result, payload = request_json(
        f"{base_url}/api/items/{item_id}?expanded=1", headers=headers
    )
    if result.status != 200:
        raise ProbeFailure(f"expanded-item lookup returned status {result.status}")
    return payload


def wait_for_sidecar(
    base_url: str,
    item_id: str,
    headers: dict[str, str],
    timeout_seconds: int,
) -> dict[str, Any] | None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        item = expanded_item(base_url, item_id, headers)
        for library_file in item.get("libraryFiles", []):
            if library_file.get("metadata", {}).get("filename") == PROBE_VTT_FILENAME:
                return library_file
        time.sleep(POLL_INTERVAL_SECONDS)
    return None


def scan_item(base_url: str, item_id: str, headers: dict[str, str]) -> None:
    result = request(
        f"{base_url}/api/items/{item_id}/scan",
        method="POST",
        headers=headers,
    )
    if result.status != 200:
        raise ProbeFailure(f"explicit item scan returned status {result.status}")


def validate_server_version(base_url: str) -> None:
    result, payload = request_json(f"{base_url}/status")
    if result.status != 200:
        raise ProbeFailure(f"status lookup returned status {result.status}")
    if payload.get("serverVersion") != "2.36.0":
        raise ProbeFailure("probe did not start Audiobookshelf 2.36.0")


def run_probe(environment: dict[str, str], username: str, base_url: str) -> None:
    validate_server_version(base_url)
    password = environment["BLEAT_TEST_PASSWORD"]
    access_token = login(base_url, username, password)
    headers = bearer_headers(access_token)
    library_id, folder_id = probe_library(base_url, headers)

    media_root = Path(environment["BLEAT_MEDIA_ROOT"])
    target_directory = media_root / PROBE_AUTHOR / PROBE_SERIES / PROBE_TITLE
    target_directory.mkdir(parents=True)
    target_directory.chmod(0o777)
    shutil.copy2(
        media_root / "direct" / "music.m4b",
        target_directory / PROBE_AUDIO_FILENAME,
    )

    scan_result = request(
        f"{base_url}/api/libraries/{library_id}/scan",
        method="POST",
        headers=headers,
    )
    if scan_result.status != 200:
        raise ProbeFailure(
            f"explicit target-item scan returned status {scan_result.status}"
        )
    item = wait_for_item(base_url, library_id, headers)
    item_id = item.get("id")
    if not isinstance(item_id, str) or not item_id:
        raise ProbeFailure("scanned probe item did not have an ID")

    boundary, body = multipart_body(
        {
            "library": library_id,
            "folder": folder_id,
            "author": PROBE_AUTHOR,
            "series": PROBE_SERIES,
            "title": PROBE_TITLE,
        },
        PROBE_VTT_FILENAME,
        PROBE_VTT,
    )
    upload_result = request(
        f"{base_url}/api/upload",
        method="POST",
        body=body,
        headers={
            **headers,
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
    )
    if upload_result.status != 200:
        raise ProbeFailure(f"generic upload returned status {upload_result.status}")

    sidecar = wait_for_sidecar(
        base_url,
        item_id,
        headers,
        WATCHER_POLL_TIMEOUT_SECONDS,
    )
    scan_mode = "watcher"
    if sidecar is None:
        scan_item(base_url, item_id, headers)
        sidecar = wait_for_sidecar(base_url, item_id, headers, 15)
        scan_mode = "explicit item scan"
    if sidecar is None:
        raise ProbeFailure(
            "uploaded VTT was not added to the existing item's library files"
        )
    file_id = sidecar.get("ino")
    if not isinstance(file_id, (int, str)) or not str(file_id):
        raise ProbeFailure("uploaded VTT did not expose a library-file inode")
    download_result = request(
        f"{base_url}/api/items/{item_id}/file/{file_id}/download", headers=headers
    )
    if download_result.status != 200:
        raise ProbeFailure(
            f"uploaded VTT download returned status {download_result.status}"
        )
    if download_result.body != PROBE_VTT:
        raise ProbeFailure("downloaded VTT bytes differed from the uploaded payload")

    print(
        "PASS: v2.36.0 uploaded and downloaded identical VTT bytes beside a "
        f"conventionally named existing item after {scan_mode}."
    )


def main() -> int:
    repository_root = Path(__file__).resolve().parent.parent
    environment_script = repository_root / "scripts" / "live-test-environment.sh"
    source_media = repository_root / "TestSupport" / "ServerHarness" / "media"
    if not environment_script.is_file() or not source_media.is_dir():
        raise ProbeFailure("probe must run from the Bleat repository")

    with tempfile.TemporaryDirectory(
        prefix="bleat-sidecar-upload-"
    ) as temporary_directory:
        media_root = Path(temporary_directory) / "media"
        shutil.copytree(source_media, media_root)
        media_root.chmod(0o777)
        environment, username, base_url = command_environment(media_root)
        try:
            run_environment(environment_script, environment, "reset")
            run_probe(environment, username, base_url)
        finally:
            try:
                run_environment(environment_script, environment, "down")
            except subprocess.CalledProcessError as error:
                print(
                    f"WARNING: disposable sidecar-upload cleanup failed with {error.returncode}",
                    file=sys.stderr,
                )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ProbeFailure, subprocess.CalledProcessError) as error:
        print(f"sidecar-upload probe failed: {error}", file=sys.stderr)
        raise SystemExit(1)
