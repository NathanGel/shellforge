import asyncio
import json
import os
import socket
import signal
import subprocess
import sys

import pytest

from shellforged.__main__ import EXIT_ALREADY_RUNNING, IDLE_EXIT_SECONDS, IdleWatchdog, build_parser, ctl_request, main
from tests.conftest import wait_until


def test_parser_defaults(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    ns = build_parser().parse_args(["run"])
    assert ns.command == "run" and ns.hook_port == 47821
    assert ns.socket == str(tmp_path / "Library/Application Support/AiTerm/shellforged.sock")
    assert ns.idle_exit_seconds == IDLE_EXIT_SECONDS
    assert build_parser().parse_args(["run", "--idle-exit-seconds", "0"]).idle_exit_seconds == 0
    assert not ns.cookies_from_app
    assert build_parser().parse_args(["run", "--cookies-from-app"]).cookies_from_app
    ns = build_parser().parse_args(["ctl", "iterm.status", '{"a":1}'])
    assert ns.method == "iterm.status" and json.loads(ns.params) == {"a": 1}


async def test_ctl_request_round_trip(sock_dir):
    path = sock_dir + "/s.sock"

    async def serve(reader, writer):
        line = await reader.readline()
        req = json.loads(line)
        writer.write((json.dumps({"id": req["id"], "result": {"echo": req["params"]}}) + "\n").encode())
        await writer.drain()
        writer.close()

    server = await asyncio.start_unix_server(serve, path=path)
    try:
        assert await ctl_request(path, "x", {"k": 1}) == {"id": 1, "result": {"echo": {"k": 1}}}
    finally:
        server.close()
        await server.wait_closed()


def test_run_exits_with_already_running_status_without_touching_iterm2(capsys, sock_dir):
    # `run_daemon` starts the RPC socket before ever touching iTerm2, so a
    # bare listening Unix socket at the same path is enough to make
    # `rpc_server.start()` raise before `Service.start()` reaches
    # `iterm.connect()` - this test must never launch or contact iTerm2.
    sock_path = os.path.join(sock_dir, "s.sock")
    srv_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv_sock.bind(sock_path)
    srv_sock.listen(1)
    try:
        result = main(["run", "--socket", sock_path, "--hook-port", "0"])
        # A status of its own, not the generic 1: it is what lets the supervisor tell
        # "another daemon owns the socket" (adopt it) from "the daemon crashed"
        # (restart it). Sharing 1 made the app restart-loop forever against an orphan.
        assert result == EXIT_ALREADY_RUNNING != 1
        captured = capsys.readouterr()
        assert "already running" in captured.err
        assert sock_path in captured.err
    finally:
        srv_sock.close()


def test_run_reports_a_hook_port_in_use_cleanly(capsys, sock_dir):
    blocker = socket.socket()
    blocker.bind(("127.0.0.1", 0))
    blocker.listen(1)
    try:
        sock_path = os.path.join(sock_dir, "s.sock")
        result = main(["run", "--socket", sock_path, "--hook-port", str(blocker.getsockname()[1])])
        assert result == 1
        err = capsys.readouterr().err
        assert "Traceback" not in err and "could not start" in err
        assert not os.path.exists(sock_path)
    finally:
        blocker.close()


def test_ctl_bad_params_exit_code(capsys):
    result = main(["ctl", "x", "{not json", "--socket", "/tmp/none.sock"])
    assert result == 1
    captured = capsys.readouterr()
    assert "error" in captured.err
    assert "bad_params" in captured.err or "JSON" in captured.err


def test_importing_main_does_not_pull_in_the_iterm2_dependency():
    # `run_daemon` imports the iTerm2-backed modules inside the function on purpose, so
    # `ctl` and `--help` keep working on a machine without the `iterm2` package. A
    # module-level import in __main__ silently undoes that, and only `run` would notice.
    probe = "import shellforged.__main__, sys; print('iterm2' in sys.modules, 'shellforged.service' in sys.modules)"
    out = subprocess.run([sys.executable, "-c", probe], capture_output=True, text=True,
                         cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    assert out.returncode == 0, out.stderr
    assert out.stdout.split() == ["False", "False"], out.stdout


class Watched:
    """An IdleWatchdog over a client count the test sets, checking every 20 ms."""

    def __init__(self, idle_exit_seconds=0.15):
        self.clients, self.idled = 0, asyncio.Event()
        self.task = asyncio.get_running_loop().create_task(
            IdleWatchdog(lambda: self.clients, idle_exit_seconds, self.idled.set, check_seconds=0.02).run())


@pytest.fixture
async def watched():
    built: list[Watched] = []

    def make(**kw):
        built.append(Watched(**kw))
        return built[-1]

    yield make
    for w in built:
        w.task.cancel()
        await asyncio.gather(w.task, return_exceptions=True)


async def test_idle_watchdog_fires_when_no_client_ever_connects(watched):
    # The app dying without a graceful quit is the whole reason this exists: the
    # daemon must not outlive it, or it holds the socket the next launch needs.
    w = watched()
    await asyncio.wait_for(w.idled.wait(), 2)


async def test_idle_watchdog_does_not_fire_while_a_client_is_connected(watched):
    w = watched()
    w.clients = 1
    with pytest.raises(asyncio.TimeoutError):
        await asyncio.wait_for(w.idled.wait(), 0.5)
    assert not w.idled.is_set()


async def test_idle_watchdog_fires_after_the_last_client_leaves(watched):
    # Adoption's other half: a daemon that a new app picked up must keep running
    # while that app is attached, and only then start counting down again.
    w = watched()
    w.clients = 1
    await asyncio.sleep(0.3)
    assert not w.idled.is_set()
    w.clients = 0
    await asyncio.wait_for(w.idled.wait(), 2)


async def test_idle_watchdog_is_off_at_zero(watched):
    w = watched(idle_exit_seconds=0)
    await asyncio.wait_for(w.task, 2)  # nothing to watch for
    assert not w.idled.is_set()


async def test_run_daemon_quits_once_its_last_app_has_left(monkeypatch, tmp_path, sock_dir):
    """The watchdog in run_daemon reads the RPC server's own client count: it holds off while an
    app is attached and ends the daemon once it has gone. iTerm2 is a FakeIterm, HOME a tmp dir."""
    import shellforged.__main__ as entry
    from shellforged import iterm_bridge
    from tests.fake_iterm import FakeIterm

    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setattr(iterm_bridge, "ItermBridge", FakeIterm)
    monkeypatch.setattr(entry, "IDLE_CHECK_SECONDS", 0.02)
    sock = os.path.join(sock_dir, "d.sock")
    ns = build_parser().parse_args(["run", "--socket", sock, "--hook-port", "0", "--idle-exit-seconds", "0.2"])
    daemon = asyncio.create_task(entry.run_daemon(ns))
    try:
        await wait_until(lambda: os.path.exists(tmp_path / "Library/Application Support/AiTerm/daemon.json"))
        r, w = await asyncio.open_unix_connection(sock)
        await asyncio.sleep(0.5)  # well past the idle timeout, with the app attached
        assert not daemon.done()
        w.close()
        await asyncio.wait_for(daemon, 2)
        assert not os.path.exists(sock)
    finally:
        daemon.cancel()
        await asyncio.gather(daemon, return_exceptions=True)
        for sig in (signal.SIGINT, signal.SIGTERM):
            asyncio.get_running_loop().remove_signal_handler(sig)
