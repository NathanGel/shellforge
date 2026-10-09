import asyncio
import json
import os
import stat

import pytest

from shellforged.rpc_server import RpcError, RpcServer
from tests.conftest import wait_until


async def _client(path):
    return await asyncio.open_unix_connection(path)


async def _call(reader, writer, obj):
    writer.write((json.dumps(obj) + "\n").encode())
    await writer.drain()
    return json.loads(await asyncio.wait_for(reader.readline(), 2))


@pytest.fixture
async def server(sock_dir):
    srv = RpcServer(os.path.join(sock_dir, "t.sock"))
    srv.register("echo", lambda params: _async_identity(params))

    async def boom(params):
        raise RpcError("not_found", "no such window")

    srv.register("boom", boom)
    await srv.start()
    yield srv
    await srv.stop()


async def _async_identity(x):
    return x


async def test_dispatches_and_echoes_id(server):
    r, w = await _client(server.path)
    assert await _call(r, w, {"id": 5, "method": "echo", "params": {"a": 1}}) == {"id": 5, "result": {"a": 1}}
    w.close()


async def test_unknown_method_and_handler_errors(server):
    r, w = await _client(server.path)
    assert await _call(r, w, {"id": 1, "method": "nope"}) == {"id": 1, "error": {"code": "unknown_method", "message": "nope"}}
    assert await _call(r, w, {"id": 2, "method": "boom"}) == {"id": 2, "error": {"code": "not_found", "message": "no such window"}}
    w.close()


async def test_malformed_line_gets_protocol_error_and_connection_survives(server):
    r, w = await _client(server.path)
    w.write(b"garbage\n")
    await w.drain()
    resp = json.loads(await asyncio.wait_for(r.readline(), 2))
    assert resp["error"]["code"] == "protocol"
    assert await _call(r, w, {"id": 9, "method": "echo", "params": 1}) == {"id": 9, "result": 1}
    w.close()


async def test_a_lone_surrogate_neither_closes_the_connection_nor_fails_a_broadcast(server):
    r, w = await _client(server.path)
    w.write(b'{"id": 1, "method": "echo", "params": "\\ud800"}\n')
    await w.drain()
    assert json.loads(await asyncio.wait_for(r.readline(), 2)) == {"id": 1, "result": "?"}
    await server.broadcast("session.changed", {"title": "\ud800"})
    assert json.loads(await asyncio.wait_for(r.readline(), 2))["payload"] == {"title": "?"}
    w.close()


async def test_broadcast_reaches_every_client(server):
    r1, w1 = await _client(server.path)
    r2, w2 = await _client(server.path)
    await wait_until(lambda: server.client_count == 2)
    await server.broadcast("iterm.connected", {"version": "3.7.2"})
    for r in (r1, r2):
        assert json.loads(await asyncio.wait_for(r.readline(), 2)) == {"event": "iterm.connected", "payload": {"version": "3.7.2"}}
    w1.close()
    w2.close()


async def test_socket_file_has_restricted_permissions(sock_dir):
    sock_path = os.path.join(sock_dir, "t.sock")
    srv = RpcServer(sock_path)
    await srv.start()
    assert stat.S_IMODE(os.stat(sock_path).st_mode) == 0o600
    await srv.stop()


async def test_socket_file_removed_after_stop(sock_dir):
    sock_path = os.path.join(sock_dir, "t.sock")
    srv = RpcServer(sock_path)
    await srv.start()
    assert os.path.exists(sock_path)
    await srv.stop()
    assert not os.path.exists(sock_path)


async def test_second_daemon_is_refused_and_first_keeps_working(sock_dir):
    sock_path = os.path.join(sock_dir, "t.sock")
    first = RpcServer(sock_path)
    first.register("echo", lambda params: _async_identity(params))
    await first.start()
    try:
        second = RpcServer(sock_path)
        with pytest.raises(RuntimeError, match="already running"):
            await second.start()
        # The first instance's socket must still be live and unmodified.
        r, w = await _client(sock_path)
        assert await _call(r, w, {"id": 1, "method": "echo", "params": "still alive"}) == {"id": 1, "result": "still alive"}
        w.close()
    finally:
        await first.stop()


async def test_oversized_line_disconnects_client_without_crashing_server(server, caplog):
    # A line over the stream `limit` makes `readline()` raise (internally, a
    # `LimitOverrunError`, but it re-raises that as `ValueError` - see the
    # comment in rpc_server.py). Before the fix this propagated out of
    # `_serve` unhandled and asyncio's default handler logged it as a crash;
    # the connection was still cleaned up either way (Python's `finally`
    # runs on an unhandled exception too), so the real regression this test
    # guards is *silent, log-free* handling, not server-wide breakage.
    caplog.set_level("ERROR")
    r, w = await _client(server.path)
    try:
        for _ in range(4):
            w.write(b"x" * (1024 * 1024))  # no newline: exceeds the 1 MiB stream limit
            await w.drain()
        await asyncio.wait_for(r.read(), 2)
    except (ConnectionError, OSError):
        pass
    finally:
        w.close()
    # The server's end is gone once the handler has finished; its exception, if any, is reported
    # by a callback scheduled in that same step, so one more pass of the loop runs it.
    await wait_until(lambda: server.client_count == 0)
    await asyncio.sleep(0)

    assert not any("client_connected_cb" in rec.message or "LimitOverrunError" in rec.message for rec in caplog.records)

    r2, w2 = await _client(server.path)
    assert await _call(r2, w2, {"id": 9, "method": "echo", "params": "ok"}) == {"id": 9, "result": "ok"}
    w2.close()


async def test_client_count_tracks_connected_clients(sock_dir):
    # The idle watchdog exits the daemon once no app has been connected for a
    # while, so it needs an honest count of live RPC clients.
    srv = RpcServer(os.path.join(sock_dir, "s.sock"))
    await srv.start()
    try:
        assert srv.client_count == 0
        r1, w1 = await asyncio.open_unix_connection(srv.path)
        r2, w2 = await asyncio.open_unix_connection(srv.path)
        await wait_until(lambda: srv.client_count == 2)
        assert srv.client_count == 2
        w1.close()
        await wait_until(lambda: srv.client_count == 1)
        assert srv.client_count == 1
        w2.close()
        await wait_until(lambda: srv.client_count == 0)
        assert srv.client_count == 0
    finally:
        await srv.stop()


async def test_failed_second_server_cannot_unlink_the_first_socket(server):
    second = RpcServer(server.path)
    with pytest.raises(RuntimeError, match="already running"):
        await second.start()
    await second.stop()
    r, w = await _client(server.path)
    assert (await _call(r, w, {"id": 1, "method": "echo", "params": "alive"}))["result"] == "alive"
    w.close()


async def test_invalid_method_type_does_not_crash_connection(server):
    r, w = await _client(server.path)
    reply = await _call(r, w, {"id": 1, "method": {"bad": "type"}})
    assert reply["error"]["code"] == "protocol"
    assert (await _call(r, w, {"id": 2, "method": "echo", "params": "alive"}))["result"] == "alive"
    w.close()


async def test_a_deeply_nested_line_is_a_protocol_error_not_a_dropped_connection(server):
    r, w = await _client(server.path)
    w.write(("[" * 100_000 + "]" * 100_000 + "\n").encode())
    await w.drain()
    reply = json.loads(await asyncio.wait_for(r.readline(), 2))
    assert reply["error"]["code"] == "protocol"
    assert (await _call(r, w, {"id": 2, "method": "echo", "params": "alive"}))["result"] == "alive"
    w.close()


async def test_a_slow_request_does_not_hold_up_the_ones_behind_it(server):
    release = asyncio.Event()

    async def slow(params):
        await release.wait()
        return "slow"

    server.register("slow", slow)
    r, w = await _client(server.path)
    w.write((json.dumps({"id": 1, "method": "slow"}) + "\n" + json.dumps({"id": 2, "method": "echo", "params": "fast"}) + "\n").encode())
    await w.drain()
    assert json.loads(await asyncio.wait_for(r.readline(), 2)) == {"id": 2, "result": "fast"}
    release.set()
    assert json.loads(await asyncio.wait_for(r.readline(), 2)) == {"id": 1, "result": "slow"}
    w.close()


async def test_a_reply_is_written_before_any_event_broadcast_after_its_handler_returns(server):
    """The documented barrier: the workspace.snapshot reply is on the wire ahead of every event
    that follows it, so the app can apply later events on top of the snapshot."""
    release = asyncio.Event()

    started = asyncio.Event()

    async def snapshot(params):
        started.set()
        await release.wait()  # as the real one awaits a tick
        # Queued now, to run the moment this handler yields control -- which it never does again.
        asyncio.get_running_loop().create_task(server.broadcast("session.changed", {"after": True}))
        return {"state": "at the snapshot"}

    server.register("snapshot", snapshot)
    r, w = await _client(server.path)
    w.write((json.dumps({"id": 1, "method": "snapshot"}) + "\n").encode())
    await w.drain()
    await asyncio.wait_for(started.wait(), 2)
    release.set()
    first = json.loads(await asyncio.wait_for(r.readline(), 2))
    second = json.loads(await asyncio.wait_for(r.readline(), 2))
    assert first == {"id": 1, "result": {"state": "at the snapshot"}}
    assert second == {"event": "session.changed", "payload": {"after": True}}
    w.close()


async def test_a_request_outliving_its_client_is_finished_quietly(server, caplog):
    caplog.set_level("WARNING")
    started, release, finished = asyncio.Event(), asyncio.Event(), asyncio.Event()

    async def slow(params):
        started.set()
        await release.wait()
        finished.set()
        return "late"

    server.register("slow", slow)
    r, w = await _client(server.path)
    w.write((json.dumps({"id": 1, "method": "slow"}) + "\n").encode())
    await w.drain()
    await asyncio.wait_for(started.wait(), 2)
    w.close()
    await wait_until(lambda: server.client_count == 0)
    release.set()
    await asyncio.wait_for(finished.wait(), 2)
    await wait_until(lambda: not server._requests)  # its reply dropped, its task done
    assert not caplog.records


async def test_stop_cancels_the_requests_still_running(sock_dir):
    srv = RpcServer(os.path.join(sock_dir, "s.sock"))
    started, cancelled = asyncio.Event(), asyncio.Event()

    async def forever(params):
        started.set()
        try:
            await asyncio.Event().wait()
        finally:
            cancelled.set()

    srv.register("forever", forever)
    await srv.start()
    r, w = await _client(srv.path)
    w.write((json.dumps({"id": 1, "method": "forever"}) + "\n").encode())
    await w.drain()
    await asyncio.wait_for(started.wait(), 2)
    await asyncio.wait_for(srv.stop(), 2)
    assert cancelled.is_set()
    w.close()


async def test_stop_does_not_wait_on_a_client_that_stopped_reading(server):
    """A client dropped with its buffer unflushed -- here by broadcast's 1 MiB guard -- is never
    flushed, and waiting for its transport to close would hold stop() for good."""
    r, w = await _client(server.path)  # and never reads
    await wait_until(lambda: server.client_count == 1)
    first = asyncio.create_task(server.broadcast("session.changed", {"blob": "x" * (3 << 20)}))
    await asyncio.sleep(0)  # written, and waiting on a drain that will not come
    await server.broadcast("session.changed", {"after": True})  # over the guard: dropped
    assert server.client_count == 0
    await asyncio.wait_for(server.stop(), 2)
    await asyncio.wait_for(first, 2)
    w.close()


class _Writer:
    """Enough of a StreamWriter for `_serve`, which the next test drives directly."""

    def __init__(self):
        self.transport, self.written = self, []

    def write(self, data):
        self.written.append(data)

    def is_closing(self):
        return False

    def close(self):
        pass

    abort = close

    def get_write_buffer_size(self):
        return 0

    async def drain(self):
        pass


async def test_no_request_starts_once_stop_has_begun(server):
    """A line read in the same pass of the loop that stop() began in must not start a request
    stop() has already stopped cancelling."""
    started = []

    async def record(params):
        started.append(params)

    server.register("record", record)
    reader = asyncio.StreamReader()
    serving = asyncio.create_task(server._serve(reader, _Writer()))
    await asyncio.sleep(0)  # waiting on its first line
    stopping = asyncio.create_task(server.stop())  # scheduled ahead of the line's wakeup
    reader.feed_data((json.dumps({"id": 1, "method": "record", "params": "late"}) + "\n").encode())
    reader.feed_eof()
    await asyncio.wait_for(stopping, 2)
    await asyncio.wait_for(serving, 2)
    await asyncio.sleep(0.01)  # time for a request, had one been started, to run
    assert started == []
