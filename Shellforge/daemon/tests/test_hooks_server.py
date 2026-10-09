import asyncio
import json
import pytest
import pytest_asyncio
from shellforged import hooks_server
from shellforged.hooks_server import HookServer


async def http(port, method, path, body=None, header=True, iterm_session_id=None):
    r, w = await asyncio.open_connection("127.0.0.1", port)
    data = json.dumps(body).encode() if body is not None else b""
    hook_header = "X-AiTerm-Hook: 1\r\n" if header else ""
    session_header = f"X-AiTerm-iTerm-Session: {iterm_session_id}\r\n" if iterm_session_id else ""
    w.write(f"{method} {path} HTTP/1.1\r\nHost: x\r\n{hook_header}{session_header}"
            f"Content-Type: application/json\r\nContent-Length: {len(data)}\r\n\r\n".encode() + data)
    await w.drain()
    status_line = await asyncio.wait_for(r.readline(), 2)
    w.close()
    return int(status_line.split()[1])


async def mcp(port, body, iterm_session_id=None):
    r, w = await asyncio.open_connection("127.0.0.1", port)
    data = json.dumps(body).encode()
    session_header = f"X-AiTerm-iTerm-Session: {iterm_session_id}\r\n" if iterm_session_id else ""
    w.write(
        f"POST /mcp HTTP/1.1\r\nHost: x\r\nX-AiTerm-Hook: 1\r\n{session_header}"
        f"Content-Type: application/json\r\nContent-Length: {len(data)}\r\n\r\n".encode() + data
    )
    await w.drain()
    status = int((await asyncio.wait_for(r.readline(), 2)).split()[1])
    headers = {}
    while line := (await r.readline()).decode().strip():
        key, _, value = line.partition(":")
        headers[key.lower()] = value.strip()
    response = await r.readexactly(int(headers.get("content-length", "0"))) if headers.get("content-length") else b""
    w.close()
    return status, json.loads(response) if response else None


async def post_json(port, path, body):
    r, w = await asyncio.open_connection("127.0.0.1", port)
    data = json.dumps(body).encode()
    w.write(
        f"POST {path} HTTP/1.1\r\nHost: x\r\nX-AiTerm-Hook: 1\r\n"
        f"Content-Type: application/json\r\nContent-Length: {len(data)}\r\n\r\n".encode() + data
    )
    await w.drain()
    status = int((await asyncio.wait_for(r.readline(), 2)).split()[1])
    headers = {}
    while line := (await r.readline()).decode().strip():
        key, _, value = line.partition(":")
        headers[key.lower()] = value.strip()
    response = await r.readexactly(int(headers.get("content-length", "0")))
    w.close()
    return status, json.loads(response)


class Received(list):
    """Every delivered post, in order. A post is delivered after its reply is written, so a test
    waits for it with `delivered(n)` instead of reading the list straight after the reply."""

    def __init__(self):
        super().__init__()
        self._changed = asyncio.Condition()

    async def add(self, item):
        async with self._changed:
            self.append(item)
            self._changed.notify_all()

    async def delivered(self, count):
        async with self._changed:
            await asyncio.wait_for(self._changed.wait_for(lambda: len(self) >= count), 2)


@pytest_asyncio.fixture
async def server():
    received = Received()

    async def on_post(path, body):
        await received.add((path, body))
        if body.get("boom"):
            raise RuntimeError("handler failed")

    srv = HookServer(port=0, on_post=on_post)
    await srv.start()
    yield srv, received
    await srv.stop()


async def closed_by_server(r):
    """Reads the rest of the reply, returning once the server has closed its end: its handler for
    that request has finished."""
    await asyncio.wait_for(r.read(), 2)
    assert r.at_eof()


def test_the_routes_derive_from_the_harness_table():
    assert hooks_server.ROUTES == {"/hook/claude", "/hook/codex", "/hook/grok", "/hook/pi", "/mcp",
                                   "/statusline", "/statusline/grok"}


async def test_post_routes_deliver_body(server):
    srv, received = server
    assert await http(srv.port, "POST", "/hook/claude", {"hook_event_name": "Stop"}) == 200
    assert await http(srv.port, "POST", "/statusline", {"model": {"id": "x"}}) == 200
    await received.delivered(2)
    assert received == [("/hook/claude", {"hook_event_name": "Stop"}), ("/statusline", {"model": {"id": "x"}})]


async def test_codex_hook_forwards_the_inherited_iterm_session_id(server):
    srv, received = server
    assert await http(srv.port, "POST", "/hook/codex", {"hook_event_name": "SubagentStart"}, iterm_session_id="w0t0p0:child") == 200
    await received.delivered(1)
    assert received == [("/hook/codex", {"hook_event_name": "SubagentStart", "_aiterm_iterm_session_id": "w0t0p0:child"})]


async def test_a_client_supplied_iterm_session_id_without_the_header_is_dropped(server):
    # The field is trusted as the inherited $ITERM_SESSION_ID; only the header may set it.
    srv, received = server
    assert await http(srv.port, "POST", "/hook/codex", {"hook_event_name": "Stop", "_aiterm_iterm_session_id": "w0t0p0:other"}) == 200
    await received.delivered(1)
    assert received == [("/hook/codex", {"hook_event_name": "Stop"})]


@pytest.mark.parametrize("path", ["/hook/grok", "/statusline/grok"])
async def test_grok_routes_take_the_tab_from_the_header_over_the_body(server, path):
    srv, received = server
    body = {"hook_event_name": "Stop", "_aiterm_iterm_session_id": "w0t0p0:forged"}
    assert await http(srv.port, "POST", path, body, iterm_session_id="w0t0p0:grok-tab") == 200
    assert await http(srv.port, "POST", path, body) == 200
    await received.delivered(2)
    # Each post is delivered after its own reply, so the two can land in either order.
    assert len(received) == 2
    assert (path, {"hook_event_name": "Stop", "_aiterm_iterm_session_id": "w0t0p0:grok-tab"}) in received
    assert (path, {"hook_event_name": "Stop"}) in received


@pytest.mark.parametrize("length", [b"-5", b"abc", b"+3"])
async def test_an_unusable_content_length_is_a_400(server, length):
    srv, received = server
    r, w = await asyncio.open_connection("127.0.0.1", srv.port)
    w.write(b"POST /hook/claude HTTP/1.1\r\nX-AiTerm-Hook: 1\r\nContent-Length: " + length + b"\r\n\r\n{}")
    await w.drain()
    assert int((await asyncio.wait_for(r.readline(), 2)).split()[1]) == 400
    w.close()
    assert received == []


async def test_pi_route_forwards_the_inherited_iterm_session_id(server):
    srv, received = server
    assert await http(srv.port, "POST", "/hook/pi", {"hook_event_name": "agent_start"}, iterm_session_id="w0t0p0:pi") == 200
    await received.delivered(1)
    assert received == [("/hook/pi", {"hook_event_name": "agent_start", "_aiterm_iterm_session_id": "w0t0p0:pi"})]


@pytest.mark.parametrize("path", sorted(hooks_server.ROUTES - {"/mcp"}))
@pytest.mark.parametrize("probe,answer", [
    ({"_aiterm_daemon_test_id": "daemon-3"}, {"ok": True, "daemonTestId": "daemon-3"}),
    # The PI extension sends its probe on a real event, which must not count.
    ({"_aiterm_test_id": "probe-7", "hook_event_name": "agent_start", "session_id": "s"}, {"ok": True, "testId": "probe-7"}),
])
async def test_a_probe_is_answered_without_being_delivered(server, path, probe, answer):
    srv, received = server
    status, response = await post_json(srv.port, path, probe)
    assert status == 200 and response == answer
    # A real post sent after it is delivered first: the probe was never handed on.
    assert await http(srv.port, "POST", path, {"hook_event_name": "Stop"}) == 200
    await received.delivered(1)
    assert received == [(path, {"hook_event_name": "Stop"})]


@pytest.mark.parametrize("path", ["/hook/claude", "/hook/codex"])
async def test_pretooluse_is_ordinary_telemetry_acknowledged_before_delivery(path):
    # No hook response carries a decision: the agent is never held up while the daemon works.
    release, delivered = asyncio.Event(), Received()

    async def on_post(received_path, body):
        await release.wait()
        await delivered.add((received_path, body["hook_event_name"]))
        return {"hookSpecificOutput": {"permissionDecision": "allow"}}

    srv = HookServer(port=0, on_post=on_post)
    await srv.start()
    try:
        status, response = await post_json(srv.port, path, {"hook_event_name": "PreToolUse", "tool_name": "Bash"})
        assert status == 200 and response == {}
        assert delivered == []
        release.set()
        await delivered.delivered(1)
        assert delivered == [(path, "PreToolUse")]
    finally:
        release.set()
        await srv.stop()


async def test_mcp_stop_hook_uses_an_existing_connection_and_delivers_to_codex_route(server):
    srv, received = server
    status, initialized = await mcp(srv.port, {
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}},
    })
    assert status == 200
    assert initialized["result"]["capabilities"] == {"tools": {"listChanged": False}}

    status, listed = await mcp(srv.port, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
    assert status == 200 and listed["result"]["tools"][0]["name"] == "post_codex_hook"

    event = {"hook_event_name": "Stop", "session_id": "thread-1", "cwd": "/deleted/worktree", "model": "gpt-5.6"}
    status, called = await mcp(srv.port, {
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": {"name": "post_codex_hook", "arguments": event},
    }, iterm_session_id="w0t0p0:codex")
    assert status == 200 and called["result"]["structuredContent"] == {}
    assert received == [("/hook/codex", {**event, "_aiterm_iterm_session_id": "w0t0p0:codex"})]


async def test_unknown_path_bad_json_and_handler_error(server):
    srv, _ = server
    assert await http(srv.port, "POST", "/nope", {}) == 404
    assert await http(srv.port, "GET", "/hook/claude") == 404
    r, w = await asyncio.open_connection("127.0.0.1", srv.port)
    w.write(b"POST /hook/codex HTTP/1.1\r\nX-AiTerm-Hook: 1\r\nContent-Length: 3\r\n\r\n{{{")
    await w.drain()
    assert int((await r.readline()).split()[1]) == 400
    w.close()
    assert await http(srv.port, "POST", "/hook/codex", {"boom": True}) == 200


@pytest.mark.parametrize("path", ["/hook/claude", "/hook/codex", "/hook/grok", "/hook/pi", "/statusline/grok"])
async def test_every_hook_route_rejects_non_object_and_malformed_json(path, server):
    srv, _ = server
    assert await http(srv.port, "POST", path, ["not", "an", "object"]) == 400
    r, w = await asyncio.open_connection("127.0.0.1", srv.port)
    w.write(f"POST {path} HTTP/1.1\r\nX-AiTerm-Hook: 1\r\nContent-Length: 3\r\n\r\n".encode() + b"{{{")
    await w.drain()
    assert int((await r.readline()).split()[1]) == 400
    w.close()


@pytest.mark.parametrize("path", ["/hook/claude", "/hook/codex", "/hook/grok", "/hook/pi", "/statusline", "/statusline/grok"])
async def test_missing_hook_header_is_404(path, server):
    srv, received = server
    assert await http(srv.port, "POST", path, {"hook_event_name": "Stop"}, header=False) == 404
    r, w = await asyncio.open_connection("127.0.0.1", srv.port)
    w.write(b"GET /hook/claude HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n")
    await w.drain()
    assert int((await r.readline()).split()[1]) == 404
    await closed_by_server(r)
    w.close()
    assert received == []  # the handler never even sees a request without the header


async def _status_for_head(port, head: bytes) -> int:
    r, w = await asyncio.open_connection("127.0.0.1", port)
    w.write(head)
    await w.drain()
    status = int((await asyncio.wait_for(r.readline(), 2)).split()[1])
    await closed_by_server(r)
    w.close()
    return status


@pytest.mark.parametrize("filler", [
    b"".join(b"X-Filler-%d: x\r\n" % i for i in range(hooks_server.MAX_HEADER_LINES)),   # too many lines
    b"X-Filler: " + b"x" * 40_000 + b"\r\n",                                              # too many bytes
], ids=["lines", "bytes"])
async def test_a_head_past_the_cap_is_a_431_before_the_hook_header_is_read(server, filler):
    # Each line is capped at 64 KiB by the stream, but their number was not, for the whole read timeout.
    srv, received = server
    body = b'{"hook_event_name": "Stop"}'
    head = b"POST /hook/claude HTTP/1.1\r\n" + filler + b"X-AiTerm-Hook: 1\r\nContent-Length: %d\r\n\r\n" % len(body)
    assert await _status_for_head(srv.port, head + body) == 431
    assert received == []


async def test_a_head_just_under_the_cap_is_served(server):
    srv, received = server
    filler = b"".join(b"X-Filler-%d: x\r\n" % i for i in range(hooks_server.MAX_HEADER_LINES - 3))
    head = b"POST /hook/claude HTTP/1.1\r\nHost: x\r\n" + filler + b"X-AiTerm-Hook: 1\r\nContent-Length: 2\r\n\r\n{}"
    assert await _status_for_head(srv.port, head) == 200
    await received.delivered(1)


async def test_server_without_callback_still_replies_200():
    """Test that server works without a callback (callback is optional)."""
    srv = HookServer(port=0)
    await srv.start()
    try:
        assert await http(srv.port, "POST", "/statusline", {"model": {"id": "x"}}) == 200
        assert await http(srv.port, "POST", "/hook/claude", {"test": "data"}) == 200
    finally:
        await srv.stop()


async def test_stalled_client_is_dropped():
    """A client that never completes its request is dropped once the read timeout passes."""
    srv = HookServer(port=0, read_timeout=0.1)
    await srv.start()
    try:
        r, w = await asyncio.open_connection("127.0.0.1", srv.port)
        # Send only the request line, no headers or body
        w.write(b"POST /statusline HTTP/1.1\r\n")
        await w.drain()
        result = await asyncio.wait_for(r.read(), 2)
        assert result == b"", "Server should close connection on stalled client"
        w.close()
    finally:
        await srv.stop()


async def test_a_deeply_nested_body_is_a_400(server, caplog, monkeypatch):
    srv, received = server
    caplog.set_level("ERROR")
    # How deep the parser goes before RecursionError depends on the interpreter's C stack:
    # Homebrew's 3.14 parses this body, mise's gives up. Raise it outright so every build tests
    # the same path: a parser that gives up is a bad request, not a dropped connection.
    def too_deep(*_args, **_kwargs):
        raise RecursionError("maximum recursion depth exceeded while decoding a JSON object")

    monkeypatch.setattr(hooks_server.json, "loads", too_deep)
    nested = ('{"a":' * 100_000 + "1" + "}" * 100_000).encode()
    r, w = await asyncio.open_connection("127.0.0.1", srv.port)
    w.write(b"POST /hook/claude HTTP/1.1\r\nX-AiTerm-Hook: 1\r\nContent-Length: %d\r\n\r\n" % len(nested) + nested)
    await w.drain()
    status_line = await asyncio.wait_for(r.readline(), 2)
    await closed_by_server(r)
    w.close()
    assert int(status_line.split()[1]) == 400
    assert received == [] and not caplog.records


async def test_expect_100_continue_gets_interim_response_then_200(server):
    srv, received = server
    body = json.dumps({"hook_event_name": "Stop"}).encode()
    r, w = await asyncio.open_connection("127.0.0.1", srv.port)
    w.write(
        f"POST /hook/claude HTTP/1.1\r\nHost: x\r\nX-AiTerm-Hook: 1\r\n"
        f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\nExpect: 100-continue\r\n\r\n".encode()
    )
    await w.drain()
    interim = await asyncio.wait_for(r.readline(), 2)
    assert interim.split()[1] == b"100"
    await asyncio.wait_for(r.readline(), 2)  # the blank line terminating the interim response
    w.write(body)
    await w.drain()
    status_line = await asyncio.wait_for(r.readline(), 2)
    assert int(status_line.split()[1]) == 200
    w.close()
    await received.delivered(1)
    assert ("/hook/claude", {"hook_event_name": "Stop"}) in received


async def test_oversized_body_is_rejected_with_413():
    """Test that Content-Length exceeding MAX_BODY is rejected with 413."""
    srv = HookServer(port=0)
    await srv.start()
    try:
        r, w = await asyncio.open_connection("127.0.0.1", srv.port)
        # Send headers with oversized Content-Length
        w.write(b"POST /statusline HTTP/1.1\r\nContent-Length: 2000000\r\n\r\n")
        await w.drain()
        status_line = await asyncio.wait_for(r.readline(), 2)
        status = int(status_line.split()[1])
        assert status == 413, f"Expected 413 for oversized body, got {status}"
        w.close()
    finally:
        await srv.stop()


async def test_pi_oversized_body_is_rejected_with_413():
    srv = HookServer(port=0)
    await srv.start()
    try:
        r, w = await asyncio.open_connection("127.0.0.1", srv.port)
        w.write(b"POST /hook/pi HTTP/1.1\r\nX-AiTerm-Hook: 1\r\nContent-Length: 2000000\r\n\r\n")
        await w.drain()
        assert int((await asyncio.wait_for(r.readline(), 2)).split()[1]) == 413
        w.close()
    finally:
        await srv.stop()
