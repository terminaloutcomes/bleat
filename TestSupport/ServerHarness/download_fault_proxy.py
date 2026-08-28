#!/usr/bin/env python3

from __future__ import annotations

import argparse
import http.client
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


DOWNLOAD_PATH = re.compile(r"/api/items/[^/]+/file/[^/]+/download$")
HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}


class FaultState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.armed = False
        self.injected = False
        self.events: list[dict[str, object]] = []
        self.refresh_events: list[dict[str, int]] = []
        self.download_keys: dict[str, str] = {}
        self.next_sequence = 1

    def arm(self) -> None:
        with self.lock:
            self.armed = True
            self.injected = False
            self.events = []
            self.refresh_events = []
            self.download_keys = {}
            self.next_sequence = 1

    def download_key(self, path: str) -> str:
        with self.lock:
            existing = self.download_keys.get(path)
            if existing is not None:
                return existing
            key = f"download-{len(self.download_keys) + 1}"
            self.download_keys[path] = key
            return key

    def claim_fault(self) -> bool:
        with self.lock:
            if not self.armed or self.injected:
                return False
            self.injected = True
            return True

    def record_refresh(self) -> None:
        with self.lock:
            if self.armed:
                self.refresh_events.append({"sequence": self.next_sequence})
                self.next_sequence += 1

    def record_download(
        self,
        *,
        download_key: str,
        status: int,
        range_header: str,
        range_start: int,
        range_end: int,
        if_range: str | None,
        authorization_scheme: str | None,
        has_token_query: bool,
        injected: bool,
    ) -> None:
        with self.lock:
            if not self.armed:
                return
            self.events.append(
                {
                    "sequence": self.next_sequence,
                    "downloadKey": download_key,
                    "status": status,
                    "range": range_header,
                    "rangeStart": range_start,
                    "rangeEnd": range_end,
                    "ifRange": if_range,
                    "authorizationScheme": authorization_scheme,
                    "hasTokenQuery": has_token_query,
                    "injected": injected,
                }
            )
            self.next_sequence += 1

    def evidence(self) -> dict[str, object]:
        with self.lock:
            return {
                "armed": self.armed,
                "injected": self.injected,
                "refreshCount": len(self.refresh_events),
                "refreshEvents": list(self.refresh_events),
                "downloadEvents": list(self.events),
            }


def authorization_scheme(value: str | None) -> str | None:
    if value is None:
        return None
    scheme, separator, _ = value.partition(" ")
    return scheme if separator and scheme else None


def range_bounds(value: str | None) -> tuple[int, int] | None:
    if value is None:
        return None
    match = re.fullmatch(r"bytes=(\d+)-(\d+)", value)
    if match is None:
        return None
    return int(match.group(1)), int(match.group(2))


class FaultProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "BleatDownloadFaultProxy"
    sys_version = ""

    @property
    def fault_server(self) -> "FaultProxyServer":
        return self.server  # type: ignore[return-value]

    def do_GET(self) -> None:
        self._handle_request()

    def do_POST(self) -> None:
        self._handle_request()

    def do_PATCH(self) -> None:
        self._handle_request()

    def do_DELETE(self) -> None:
        self._handle_request()

    def log_message(self, format: str, *args: object) -> None:
        return

    def _handle_request(self) -> None:
        parsed = urlsplit(self.path)
        if parsed.path == "/__bleat_fault__/health":
            self._send_json(200, {"status": "ready"})
            return
        if parsed.path == "/__bleat_fault__/arm" and self.command == "POST":
            self.fault_server.state.arm()
            self._send_json(200, {"armed": True})
            return
        if parsed.path == "/__bleat_fault__/evidence" and self.command == "GET":
            self._send_json(200, self.fault_server.state.evidence())
            return

        normalized_path = parsed.path.removeprefix("/audiobookshelf")
        if normalized_path == "/auth/refresh" and self.command == "POST":
            self.fault_server.state.record_refresh()

        range_header = self.headers.get("Range")
        requested_bounds = range_bounds(range_header)
        is_ranged_download = (
            self.command == "GET"
            and DOWNLOAD_PATH.fullmatch(normalized_path) is not None
            and requested_bounds is not None
        )
        download_key = (
            self.fault_server.state.download_key(normalized_path)
            if is_ranged_download
            else None
        )
        scheme = authorization_scheme(self.headers.get("Authorization"))
        # Download routes have no query contract. Treat any query as a token
        # leakage failure without retaining its name or value.
        has_token_query = bool(parsed.query)

        if (
            is_ranged_download
            and requested_bounds is not None
            and requested_bounds[0] > 0
            and self.fault_server.state.claim_fault()
        ):
            self.fault_server.state.record_download(
                download_key=download_key or "",
                status=401,
                range_header=range_header or "",
                range_start=requested_bounds[0],
                range_end=requested_bounds[1],
                if_range=self.headers.get("If-Range"),
                authorization_scheme=scheme,
                has_token_query=has_token_query,
                injected=True,
            )
            self.send_response(401)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        self._forward(
            download_key=download_key,
            requested_bounds=requested_bounds,
            range_header=range_header,
            if_range=self.headers.get("If-Range"),
            scheme=scheme,
            has_token_query=has_token_query,
        )

    def _forward(
        self,
        *,
        download_key: str | None,
        requested_bounds: tuple[int, int] | None,
        range_header: str | None,
        if_range: str | None,
        scheme: str | None,
        has_token_query: bool,
    ) -> None:
        content_length = int(self.headers.get("Content-Length", "0"))
        request_body = self.rfile.read(content_length) if content_length else None
        headers = {
            name: value
            for name, value in self.headers.items()
            if name.lower() not in HOP_BY_HOP_HEADERS and name.lower() != "host"
        }
        connection = http.client.HTTPConnection(
            self.fault_server.upstream_host,
            self.fault_server.upstream_port,
            timeout=120,
        )
        try:
            connection.request(
                self.command,
                self.path,
                body=request_body,
                headers=headers,
            )
            response = connection.getresponse()
            response_body = response.read()
            if download_key is not None and requested_bounds is not None:
                self.fault_server.state.record_download(
                    download_key=download_key,
                    status=response.status,
                    range_header=range_header or "",
                    range_start=requested_bounds[0],
                    range_end=requested_bounds[1],
                    if_range=if_range,
                    authorization_scheme=scheme,
                    has_token_query=has_token_query,
                    injected=False,
                )
            self.send_response(response.status)
            for name, value in response.getheaders():
                if name.lower() not in HOP_BY_HOP_HEADERS and name.lower() != "content-length":
                    self.send_header(name, value)
            self.send_header("Content-Length", str(len(response_body)))
            self.end_headers()
            self.wfile.write(response_body)
        except (ConnectionError, OSError, http.client.HTTPException):
            self._send_json(502, {"error": "upstream_unavailable"})
        finally:
            connection.close()

    def _send_json(self, status: int, payload: dict[str, object]) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class FaultProxyServer(ThreadingHTTPServer):
    def __init__(
        self,
        address: tuple[str, int],
        upstream_host: str,
        upstream_port: int,
    ) -> None:
        super().__init__(address, FaultProxyHandler)
        self.upstream_host = upstream_host
        self.upstream_port = upstream_port
        self.state = FaultState()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--upstream-host", required=True)
    parser.add_argument("--upstream-port", type=int, required=True)
    arguments = parser.parse_args()
    server = FaultProxyServer(
        ("0.0.0.0", arguments.listen_port),
        arguments.upstream_host,
        arguments.upstream_port,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
