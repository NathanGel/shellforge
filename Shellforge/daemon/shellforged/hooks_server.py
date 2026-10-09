"""Minimal HTTP/1.1 receiver for agent hooks and the Codex hook MCP bridge."""
from __future__ import annotations
import asyncio
import json
import logging
from collections.abc import Awaitable, Callable
from typing import Any

from .hook_events import HOOK_PARSERS, STATUSLINE_PARSERS
from .models import ITERM_SESSION_FIELD

log = logging.getLogger(__name__)
ROUTES = {*HOOK_PARSERS, *STATUSLINE_PARSERS, "/mcp"}
MAX_BODY = 1 << 20
# The most header lines, and bytes in the request line and headers together, a request may send.
# The stream caps each line at 64 KiB; without these, any local process could send distinct headers
# for the whole read timeout, before the X-AiTerm-Hook check turns it away. A hook sends about six.
MAX_HEADER_LINES = 100
MAX_HEAD_BYTES = 32 << 10
# How long a client may take to send its whole request before the connection is dropped.
READ_TIMEOUT_SECONDS = 5.0
MCP_PROTOCOL_VERSION = "2025-06-18"


class _HeadTooLarge(Exception):
    pass


class HookServer:
    def __init__(self, on_post: Callable[[str, dict[str, Any]], Awaitable[dict[str, Any] | None]] | None = None,
                 host: str = "127.0.0.1", port: int = 47821, read_timeout: float = READ_TIMEOUT_SECONDS):
        self.host, self.port, self.on_post = host, port, on_post
        self.read_timeout = read_timeout
        self._server: asyncio.AbstractServer | None = None

    async def start(self) -> None:
        self._server = await asyncio.start_server(self._serve, self.host, self.port)
        self.port = self._server.sockets[0].getsockname()[1]

    async def stop(self) -> None:
        if self._server:
            self._server.close()
            await self._server.wait_closed()

    async def _serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            # Read the request line and headers only; the body (and the
            # 100-continue interim reply, if requested) is handled after,
            # since curl won't send the body until it sees 100 Continue.
            async def _read_head() -> tuple[str, str, dict[str, str]]:
                raw = await reader.readline()
                request_line, size, lines = raw.decode("latin-1").strip(), len(raw), 0
                headers: dict[str, str] = {}
                while (line := (raw := await reader.readline()).decode("latin-1").strip()):
                    size, lines = size + len(raw), lines + 1
                    if lines > MAX_HEADER_LINES or size > MAX_HEAD_BYTES:
                        raise _HeadTooLarge
                    k, _, v = line.partition(":")
                    headers[k.strip().lower()] = v.strip()
                parts = request_line.split()
                method, path = (parts + ["", ""])[:2]
                return method, path, headers

            async def _read_request() -> tuple[str, str, dict[str, str], int, bytes]:
                method, path, headers = await _read_head()
                raw_length = headers.get("content-length", "0") or "0"
                # -1 marks a length that is not a plain decimal: `int()` alone accepts "-5" and "+3".
                content_length = int(raw_length) if raw_length.isascii() and raw_length.isdigit() else -1
                if content_length < 0 or content_length > MAX_BODY:
                    return method, path, headers, content_length, b""
                if headers.get("expect", "").lower() == "100-continue":
                    writer.write(b"HTTP/1.1 100 Continue\r\n\r\n")
                    await writer.drain()
                body = await reader.readexactly(content_length) if content_length else b""
                return method, path, headers, content_length, body

            try:
                method, path, headers, content_length, body = await asyncio.wait_for(_read_request(), self.read_timeout)
            except _HeadTooLarge:
                await self._reply(writer, 431, "request header fields too large")
                return

            if content_length < 0:
                await self._reply(writer, 400, "bad content-length")
                return
            if content_length > MAX_BODY:
                await self._reply(writer, 413, "payload too large")
                return

            # Never reveal that a route exists to a caller that doesn't send
            # our marker header - any local process or a browser page (CORS
            # simple POST) can otherwise reach these routes.
            if headers.get("x-aiterm-hook") != "1":
                await self._reply(writer, 404, "not found")
                return

            if method != "POST" or path not in ROUTES:
                await self._reply(writer, 404, "not found")
                return
            try:
                payload = json.loads(body or b"{}")
                if not isinstance(payload, dict):
                    raise ValueError("body must be an object")
            except (ValueError, RecursionError) as exc:  # RecursionError: nested past the parser's limit
                await self._reply(writer, 400, str(exc))
                return
            if path == "/mcp":
                await self._handle_mcp(writer, payload, headers)
                return

            if (probe := self._probe_reply(payload)) is not None:
                await self._reply(writer, 200, probe)
                return
            self._add_iterm_session(payload, headers)
            await self._reply(writer, 200, "{}")
            await self._deliver(path, payload)
        except (TimeoutError, asyncio.IncompleteReadError, ConnectionError, ValueError):
            pass
        finally:
            writer.close()

    @staticmethod
    def _probe_reply(payload: dict[str, Any]) -> str | None:
        """The answer to a Harness Test probe, which is never delivered: it echoes its id, and so it
        cannot change state on any route, a status line's included. `_aiterm_daemon_test_id` asks
        whether the daemon answers at all, so the app can tell a dead daemon from a route that does
        not reach it; `_aiterm_test_id` asks whether a post on this route reaches it, and the PI
        extension sends it on a real event's body, which it leaves inert."""
        for field, key in (("_aiterm_daemon_test_id", "daemonTestId"), ("_aiterm_test_id", "testId")):
            if isinstance(test_id := payload.get(field), str) and test_id:
                return json.dumps({"ok": True, key: test_id}, separators=(",", ":"))
        return None

    async def _deliver(self, path: str, payload: dict[str, Any]) -> dict[str, Any] | None:
        if self.on_post is None:
            return None
        try:
            return await self.on_post(path, payload)
        except Exception:  # noqa: BLE001 - telemetry must never break the agent hook
            log.exception("hook handler failed for %s", path)
            return None

    @staticmethod
    def _add_iterm_session(payload: dict[str, Any], headers: dict[str, str]) -> None:
        # Codex, Grok and PI payloads identify their own session but not the terminal tab. Their
        # hook process inherits iTerm's session ID, so carry it through as a trusted private field
        # -- which only the header may set.
        if iterm_session := headers.get("x-aiterm-iterm-session"):
            payload[ITERM_SESSION_FIELD] = iterm_session
        else:
            payload.pop(ITERM_SESSION_FIELD, None)

    async def _handle_mcp(self, writer: asyncio.StreamWriter, message: dict[str, Any], headers: dict[str, str]) -> None:
        """Small stateless Streamable HTTP MCP server used by Codex's Stop hook.

        Codex command hooks are spawned with the session cwd. Once Superpowers removes that
        directory, even an absolute curl command cannot start. The MCP connection is established
        while the worktree still exists, so its tool call remains available for the final event.
        """
        request_id = message.get("id")
        method = message.get("method")
        if request_id is None:
            # MCP notifications (notably notifications/initialized) have no response body.
            await self._reply(writer, 202, "")
            return

        if method == "initialize":
            result: dict[str, Any] = {
                "protocolVersion": MCP_PROTOCOL_VERSION,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "aiterm-hooks", "version": "1"},
            }
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": [{
                "name": "post_codex_hook",
                "description": "Deliver a Codex lifecycle event to the local AiTerm daemon.",
                "inputSchema": {"type": "object", "additionalProperties": True},
            }]}
        elif method == "tools/call":
            params = message.get("params")
            name = params.get("name") if isinstance(params, dict) else None
            arguments = params.get("arguments") if isinstance(params, dict) else None
            if name != "post_codex_hook" or not isinstance(arguments, dict):
                await self._mcp_error(writer, request_id, -32602, "invalid tool call")
                return
            payload = dict(arguments)
            self._add_iterm_session(payload, headers)
            await self._deliver("/hook/codex", payload)
            # Stop hooks expect an object-shaped result. Returning the same empty object in both
            # MCP result forms works with clients that prefer structuredContent and older clients
            # that inspect the text content.
            result = {"content": [{"type": "text", "text": "{}"}], "structuredContent": {}, "isError": False}
        else:
            await self._mcp_error(writer, request_id, -32601, f"method not found: {method}")
            return

        body = json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}, separators=(",", ":"))
        await self._reply(writer, 200, body)

    async def _mcp_error(self, writer: asyncio.StreamWriter, request_id: Any, code: int, message: str) -> None:
        body = json.dumps({"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}, separators=(",", ":"))
        await self._reply(writer, 200, body)

    @staticmethod
    async def _reply(writer: asyncio.StreamWriter, status: int, text: str) -> None:
        reason = {200: "OK", 202: "Accepted", 400: "Bad Request", 404: "Not Found", 413: "Payload Too Large",
                  431: "Request Header Fields Too Large"}[status]
        body = text.encode()
        head = f"HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n"
        writer.write(head.encode() + body)
        await writer.drain()
