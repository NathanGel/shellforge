"""S-V6/S-V11: the per-user token's file -- made private and whole, never through a link -- and the
two doors it guards: the app-only RPC methods and the hook port."""
import asyncio
import json
import os

import pytest

from shellforged import hook_token
from shellforged.hook_token import HookToken
from shellforged.hooks_server import HookServer
from shellforged.rpc_server import RpcServer


def test_the_token_is_made_once_private_and_whole(tmp_path):
    folder = tmp_path / "support"
    token = hook_token.read_or_create(folder)
    path = folder / "hook-token"
    assert len(token) == 64 and int(token, 16) >= 0
    assert os.stat(path).st_mode & 0o777 == 0o600
    assert path.read_bytes() == f"X-Shellforge-Token: {token}\n".encode()
    assert hook_token.read_or_create(folder) == token
    assert [p.name for p in folder.iterdir()] == ["hook-token"], "no temporary file is left behind"


def test_a_link_in_its_place_is_replaced_not_followed(tmp_path):
    folder = tmp_path / "support"
    folder.mkdir()
    elsewhere = tmp_path / "elsewhere"
    elsewhere.write_bytes(b"X-Shellforge-Token: " + b"a" * 64 + b"\n")
    os.chmod(elsewhere, 0o600)
    (folder / "hook-token").symlink_to(elsewhere)
    assert hook_token.read(folder) is None, "a link is never read"
    token = hook_token.read_or_create(folder)
    assert token != "a" * 64
    assert not (folder / "hook-token").is_symlink()
    assert elsewhere.read_bytes() == b"X-Shellforge-Token: " + b"a" * 64 + b"\n", "what the link named is untouched"


@pytest.mark.parametrize("contents,mode", [(b"X-Shellforge-Token: " + b"b" * 64 + b"\n", 0o644),
                                           (b"not a token\n", 0o600), (b"", 0o600)])
def test_a_file_others_can_read_or_that_holds_no_token_is_replaced(tmp_path, contents, mode):
    folder = tmp_path / "support"
    folder.mkdir()
    (folder / "hook-token").write_bytes(contents)
    os.chmod(folder / "hook-token", mode)
    assert hook_token.read(folder) is None
    token = hook_token.read_or_create(folder)
    assert token != "b" * 64 and hook_token.read(folder) == token


def test_a_token_made_first_by_another_process_is_the_one_used(tmp_path, monkeypatch):
    folder = tmp_path / "support"
    folder.mkdir()
    real_link = os.link

    def other_process_wins(source, target):
        (folder / "hook-token").write_bytes(b"X-Shellforge-Token: " + b"c" * 64 + b"\n")
        os.chmod(folder / "hook-token", 0o600)
        real_link(source, target)

    monkeypatch.setattr(hook_token.os, "link", other_process_wins)
    assert hook_token.read_or_create(folder) == "c" * 64


def test_a_replaced_file_is_read_again_when_a_post_does_not_match(tmp_path):
    folder = tmp_path / "support"
    token = HookToken(folder)
    first = hook_token.read(folder)
    assert token.matches(first) and not token.matches(None) and not token.matches("") and not token.matches("d" * 64)
    (folder / "hook-token").unlink()
    second = hook_token.read_or_create(folder)
    assert token.matches(second) and not token.matches(first)


async def _ask(path, *requests):
    r, w = await asyncio.open_unix_connection(path)
    for i, (method, params) in enumerate(requests):
        w.write(json.dumps({"id": i, "method": method, "params": params}).encode() + b"\n")
    await w.drain()
    replies = {}
    while len(replies) < len(requests):
        reply = json.loads(await asyncio.wait_for(r.readline(), 2))
        replies[reply["id"]] = reply
    w.close()
    return [replies[i] for i in range(len(requests))]


async def test_only_a_connection_that_showed_the_token_calls_app_methods(tmp_path, sock_dir):
    token = HookToken(tmp_path / "support")
    srv = RpcServer(os.path.join(sock_dir, "a.sock"), token=token)

    async def ok(_p):
        return {"ok": True}

    async def take(_p, _caller):
        return {"took": True}

    srv.register("sessions.update", ok)
    srv.register_with_caller("agents.takeLaunch", take, public=True)
    await srv.start()
    try:
        refused, = await _ask(srv.path, ("sessions.update", {}))
        assert refused["error"]["code"] == "unauthorized"
        wrong, still = await _ask(srv.path, ("app.hello", {"token": "e" * 64}), ("sessions.update", {}))
        assert wrong["error"]["code"] == "unauthorized" and still["error"]["code"] == "unauthorized"
        bad, = await _ask(srv.path, ("app.hello", {}))
        assert bad["error"]["code"] == "bad_params"
        assert (await _ask(srv.path, ("agents.takeLaunch", {})))[0]["result"] == {"took": True}
        hello, update = await _ask(srv.path, ("app.hello", {"token": hook_token.read(token.folder)}), ("sessions.update", {}))
        assert hello["result"] == {"ok": True} and update["result"] == {"ok": True}
        # A new connection starts over: what one showed is not another's.
        assert (await _ask(srv.path, ("sessions.update", {})))[0]["error"]["code"] == "unauthorized"
        assert "app.hello" in srv.methods
    finally:
        await srv.stop()


async def _post(port, headers):
    r, w = await asyncio.open_connection("127.0.0.1", port)
    body = b'{"hook_event_name": "Stop"}'
    lines = "".join(f"{k}: {v}\r\n" for k, v in headers.items())
    w.write(f"POST /hook/claude HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n{lines}Content-Length: {len(body)}\r\n\r\n".encode() + body)
    await w.drain()
    status = int((await asyncio.wait_for(r.readline(), 2)).split()[1])
    w.close()
    return status


async def test_the_hook_port_takes_only_posts_with_the_token_once_the_app_says_so(tmp_path):
    token = HookToken(tmp_path / "support")
    value = hook_token.read(token.folder)
    delivered = []

    async def on_post(path, payload):
        delivered.append(path)

    srv = HookServer(on_post=on_post, port=0, token=token)
    await srv.start()
    try:
        marker = {"X-Shellforge-Hook": "1"}
        assert await _post(srv.port, {**marker, "X-Shellforge-Token": value}) == 200
        assert await _post(srv.port, marker) == 200, "an install the app has not rewritten yet still reports"
        assert await _post(srv.port, {**marker, "X-Shellforge-Token": "f" * 64}) == 404, "a wrong token never"
        assert await _post(srv.port, {"X-Shellforge-Token": value}) == 404, "the marker is still asked for"
        srv.accept_tokenless = False
        assert await _post(srv.port, marker) == 404
        assert await _post(srv.port, {**marker, "X-Shellforge-Token": value}) == 200
    finally:
        await srv.stop()
