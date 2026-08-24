#!/usr/bin/env python3
import json
import os
import sys
from typing import Optional
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def usage() -> None:
    print(
        """Usage:
  bleat-logs.py health
  bleat-logs.py request METHOD PATH [JSON_BODY]
  bleat-logs.py curl METHOD PATH [JSON_BODY]
  bleat-logs.py search QUERY [LIMIT]

Environment:
  BLEAT_LOGS_BASE_URL       Backend URL
  BLEAT_LOGS_TOKEN          Optional Bearer token
  BLEAT_LOGS_SOURCE_ID      Optional ClickStack log source ID
  BLEAT_LOGS_TIMEOUT        Request timeout seconds (default: 10)"""
    )


def fail(message: str) -> int:
    print(message, file=sys.stderr)
    usage()
    return 64


def request(
    base_url: str,
    method: str,
    path: str,
    token: str,
    timeout: float,
    body: Optional[str] = None,
) -> tuple[int, str]:
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = body.encode()
    endpoint = f"{base_url.rstrip('/')}/{path.lstrip('/')}"
    try:
        with urlopen(
            Request(endpoint, data=data, headers=headers, method=method),
            timeout=timeout,
        ) as response:
            return response.status, response.read().decode(errors="replace")
    except HTTPError as error:
        return error.code, error.read().decode(errors="replace")
    except URLError as error:
        raise RuntimeError(error.reason) from error


class MCPClient:
    def __init__(self, base_url: str, token: str, timeout: float) -> None:
        self.url = f"{base_url.rstrip('/')}/api/mcp"
        self.token = token
        self.timeout = timeout
        self.next_id = 1

    def post(self, payload: dict, response_required: bool = True) -> dict:
        headers = {
            "Accept": "application/json, text/event-stream",
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
        }
        try:
            with urlopen(
                Request(
                    self.url,
                    data=json.dumps(payload).encode(),
                    headers=headers,
                    method="POST",
                ),
                timeout=self.timeout,
            ) as response:
                body = response.read().decode(errors="replace")
        except HTTPError as error:
            raise RuntimeError(f"MCP request failed with HTTP {error.code}") from error
        except URLError as error:
            raise RuntimeError(error.reason) from error
        for line in body.splitlines():
            if line.startswith("data:"):
                return json.loads(line.removeprefix("data:").strip())
        if not response_required:
            return {}
        raise RuntimeError("MCP response did not contain a JSON-RPC message")

    def initialize(self) -> None:
        message = self.post(
            {
                "jsonrpc": "2.0",
                "id": self.next_id,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-03-26",
                    "capabilities": {},
                    "clientInfo": {"name": "bleat-logs", "version": "1.0"},
                },
            }
        )
        self.next_id += 1
        if "error" in message or "result" not in message:
            raise RuntimeError("MCP initialization failed")
        self.post(
            {
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
                "params": {},
            },
            response_required=False,
        )

    def call_tool(self, name: str, arguments: dict) -> list[dict]:
        message = self.post(
            {
                "jsonrpc": "2.0",
                "id": self.next_id,
                "method": "tools/call",
                "params": {"name": name, "arguments": arguments},
            }
        )
        self.next_id += 1
        result = message.get("result")
        if "error" in message or not isinstance(result, dict):
            raise RuntimeError(f"MCP tool call failed: {name}")
        if result.get("isError"):
            raise RuntimeError(f"MCP tool reported failure: {name}")
        content = result.get("content")
        if not isinstance(content, list):
            raise RuntimeError(f"MCP tool returned no content: {name}")
        return content


def text_content(content: list[dict]) -> str:
    values = [
        item["text"]
        for item in content
        if item.get("type") == "text" and isinstance(item.get("text"), str)
    ]
    if not values:
        raise RuntimeError("MCP response did not include text content")
    return "\n".join(values)


def search_logs(
    base_url: str, token: str, timeout: float, query: str, limit: int
) -> str:
    if not token:
        raise RuntimeError("BLEAT_LOGS_TOKEN is required for search")
    client = MCPClient(base_url, token, timeout)
    client.initialize()
    source_id = os.environ.get("BLEAT_LOGS_SOURCE_ID")
    if not source_id:
        source_catalog = json.loads(
            text_content(client.call_tool("clickstack_list_sources", {}))
        )
        source_id = next(
            (
                source.get("id")
                for source in source_catalog.get("sources", [])
                if source.get("kind") == "log" and source.get("id")
            ),
            None,
        )
    if not source_id:
        raise RuntimeError("MCP did not return a log source")
    return text_content(
        client.call_tool(
            "clickstack_search",
            {"sourceId": source_id, "where": query, "maxResults": limit},
        )
    )


def main(arguments: list[str]) -> int:
    if not arguments or arguments[0] in {"-h", "--help", "help"}:
        usage()
        return 0 if arguments else 64

    base_url = os.environ.get("BLEAT_LOGS_BASE_URL")
    if not base_url:
        return fail("Set BLEAT_LOGS_BASE_URL")
    token = os.environ.get("BLEAT_LOGS_TOKEN", "")
    try:
        timeout = float(os.environ.get("BLEAT_LOGS_TIMEOUT", "10"))
    except ValueError:
        return fail("BLEAT_LOGS_TIMEOUT must be a number")

    command, *values = arguments
    method: str
    path: str
    body: Optional[str] = None
    if command == "health":
        if values:
            return fail("health does not accept arguments")
        method, path = "GET", "/api/health"
    elif command == "search":
        if not values:
            return fail("search requires QUERY")
        if len(values) > 2:
            return fail("search accepts QUERY and an optional LIMIT")
        query = values[0]
        try:
            limit = int(values[1]) if len(values) == 2 else 25
        except ValueError:
            return fail("search LIMIT must be an integer from 1 to 2000")
        if not 1 <= limit <= 2000:
            return fail("search LIMIT must be an integer from 1 to 2000")
        try:
            print(search_logs(base_url, token, timeout, query, limit), end="")
        except RuntimeError as error:
            print(f"Search failed: {error}", file=sys.stderr)
            return 1
        return 0
    elif command in {"request", "curl"}:
        if len(values) < 2 or len(values) > 3:
            return fail("request requires METHOD, PATH, and an optional JSON body")
        method, path = values[0], values[1]
        if method.upper() in {"POST", "PUT"} and len(values) == 3:
            body = values[2]
    else:
        return fail(f"Unknown command: {command}")

    try:
        _, response = request(base_url, method, path, token, timeout, body)
    except RuntimeError as error:
        print(f"Request failed: {error}", file=sys.stderr)
        return 1
    print(response, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
