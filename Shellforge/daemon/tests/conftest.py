import asyncio
import json
import os
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from shellforged import connection
from shellforged.claude_sessions import ClaudeSessionFiles
from shellforged.connection import ItermSupervisor
from shellforged.hooks_server import HookServer
from shellforged.rpc_server import RpcServer
from shellforged.service import Service
from tests.fake_iterm import FakeIterm


async def wait_until(predicate, timeout=2.0):
    """Polls `predicate` until it holds, failing the test once `timeout` seconds pass without it."""
    deadline = asyncio.get_running_loop().time() + timeout
    while not predicate():
        assert asyncio.get_running_loop().time() < deadline, "timed out"
        await asyncio.sleep(0.005)


class LaunchRecorder:
    """A launch_iterm that opens nothing, and counts how often it was asked to."""

    def __init__(self):
        self.calls = 0

    async def __call__(self) -> None:
        self.calls += 1


@pytest.fixture(autouse=True)
def temporary_files_in_the_tests_folder(tmp_path, monkeypatch):
    """`tempfile`'s folders — a ledger-less tunnel supervisor's ssh logs — under the test's own
    folder, which pytest removes, rather than left in the user's temporary folder."""
    monkeypatch.setattr(tempfile, "tempdir", str(tmp_path))
    # And for a daemon a test starts as its own process.
    monkeypatch.setenv("TMPDIR", str(tmp_path))


@pytest.fixture(autouse=True)
def no_real_iterm_launch(monkeypatch):
    """Stands in for `open -a iTerm` in every test, and fails the one that reaches it: a supervisor
    built without a launch_iterm of its own would otherwise open the real iTerm2. It records rather
    than raises, because the reconnect loop logs and swallows whatever a launch raises."""
    reached = []

    async def refuse() -> None:
        reached.append(1)

    monkeypatch.setattr(connection, "_launch_iterm", refuse)
    yield
    assert not reached, "a test reached the real `open -a iTerm`: give its ItermSupervisor a launch_iterm"


@pytest.fixture
def sock_dir():
    """A directory for Unix sockets. pytest's tmp_path is longer than the 104 bytes macOS allows
    a socket path."""
    with tempfile.TemporaryDirectory(prefix="t", dir="/tmp") as path:
        yield path


@pytest.fixture
async def make_service(tmp_path, sock_dir):
    """Builds Services, unstarted, and stops every one after the test. Each gets a FakeIterm, its
    own RPC socket, a hook server on a free port, Claude session files under tmp_path, a clock
    stopped at 1000 and an orphan check that finds every directory present -- a fake tab's `/wt`
    need not exist -- unless overridden: any Service argument can be, and `supervisor` can also be a
    dict of ItermSupervisor arguments, built over that service's iTerm2 and RPC server. A supervisor
    the factory builds opens iTerm2 through a LaunchRecorder, unless told otherwise."""
    built: list[Service] = []

    def make(*, supervisor=None, **overrides) -> Service:
        iterm = overrides.pop("iterm", None) or FakeIterm()
        rpc = overrides.pop("rpc", None) or RpcServer(os.path.join(sock_dir, f"s{len(built)}.sock"))
        if supervisor is None or isinstance(supervisor, dict):
            options = {"launch_iterm": LaunchRecorder(), **(supervisor or {})}
            supervisor = ItermSupervisor(iterm, rpc.broadcast, lambda: rpc.client_count, **options)
        arguments = {"hooks": HookServer(on_post=None, port=0), "claude_files": ClaudeSessionFiles(tmp_path / "claude-sessions"),
                     "clock": lambda: 1000, "path_missing": lambda path: False, **overrides}
        built.append(Service(iterm=iterm, rpc=rpc, supervisor=supervisor, **arguments))
        return built[-1]

    yield make
    for svc in built:
        await svc.stop()


class _Collector(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler's naming
        body = self.rfile.read(int(self.headers.get("content-length", 0) or 0))
        self.server.received.append((self.path, dict(self.headers), json.loads(body or b"{}")))
        self.send_response(200)
        self.send_header("content-length", "2")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *_):
        pass


@pytest.fixture
def daemon():
    """A stand-in for the daemon's hook port that records every POST in `.received` as (path,
    headers, body). It polls for shutdown every 10 ms: `serve_forever` defaults to 0.5 s, which
    `shutdown()` waits out and which was half the suite's wall time."""
    server = HTTPServer(("127.0.0.1", 0), _Collector)
    server.received = []
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
    thread.start()
    yield server
    server.shutdown()
    server.server_close()
    thread.join()
