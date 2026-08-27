#!/usr/bin/env python3
"""Serve one private test secret once without logging its value."""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path


def load_secret(manifest: Path, label: str) -> bytes:
    payload = json.loads(manifest.read_text(encoding="utf-8"))
    matches = [
        entry.get("value")
        for entry in payload.get("secrets", [])
        if entry.get("label") == label
    ]
    if len(matches) != 1 or not isinstance(matches[0], str):
        raise ValueError("private manifest does not contain exactly one label")
    return matches[0].encode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--label", required=True)
    parser.add_argument("--path", required=True)
    parser.add_argument("--port", required=True, type=int)
    args = parser.parse_args()
    if not args.path.startswith("/"):
        parser.error("path must start with a slash")

    secret = load_secret(args.manifest, args.label)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            nonlocal secret
            if self.path == "/health":
                self.send_response(204)
                self.end_headers()
                return
            if self.path != args.path or not secret:
                self.send_response(404)
                self.end_headers()
                return
            response = secret
            secret = b""
            self.send_response(200)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            self.wfile.write(response)
            self.server.delivered = True  # type: ignore[attr-defined]

        def log_message(self, format: str, *args: object) -> None:
            return

    server = HTTPServer(("127.0.0.1", args.port), Handler)
    server.delivered = False  # type: ignore[attr-defined]
    while not server.delivered:  # type: ignore[attr-defined]
        server.handle_request()
    server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
