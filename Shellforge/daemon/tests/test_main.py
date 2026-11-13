import asyncio
import json
import os
import socket
import signal
import subprocess
import sys
from pathlib import Path

import pytest

from shellforged.__main__ import EXIT_ALREADY_RUNNING, IDLE_EXIT_SECONDS, IdleWatchdog, ctl_request, main, parse_args
from tests.conftest import wait_until


def test_parser_defaults(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    ns = parse_args(["run"])
    assert ns.command == "run" and ns.hook_port == 47831
    assert ns.socket == str(tmp_path / "Library/Application Support/Shellforge/shellforged.sock")
    assert ns.idle_exit_seconds == IDLE_EXIT_SECONDS
    assert parse_args(["run", "--idle-exit-seconds", "0"]).idle_exit_seconds == 0
    assert not ns.cookies_from_app
    assert parse_args(["run", "--cookies-from-app"]).cookies_from_app
    ns = parse_args(["ctl", "iterm.status", '{"a":1}'])
    assert ns.method == "iterm.status" and json.loads(ns.params) == {"a": 1}


def test_the_support_folder_comes_from_the_option_then_the_environment(tmp_path, monkeypatch):
    """A dev build passes --support-dir; a shell it started has SHELLFORGE_SUPPORT; without either
    the folder is the installed app's under HOME, as before."""
    monkeypatch.setenv("HOME", str(tmp_path))
    default = tmp_path / "Library/Application Support/Shellforge"
    assert parse_args(["run"]).support_dir == default
    option = tmp_path / "Application Support/example-dev"
    ns = parse_args(["run", "--support-dir", str(option)])
    assert ns.support_dir == option and ns.socket == str(option / "shellforged.sock")
    assert ns.hook_port == 47831  # the app passes a dev build's port; the default is unchanged
    assert parse_args(["run", "--support-dir", str(option), "--socket", "/tmp/x.sock"]).socket == "/tmp/x.sock"
    assert parse_args(["ctl", "sessions.list", "--support-dir", str(option)]).socket == str(option / "shellforged.sock")
    env_folder = tmp_path / "from-env"
    monkeypatch.setenv("SHELLFORGE_SUPPORT", str(env_folder))
    assert parse_args(["run"]).socket == str(env_folder / "shellforged.sock")
    assert parse_args(["run", "--support-dir", str(option)]).support_dir == option
    monkeypatch.setenv("SHELLFORGE_SUPPORT", "")
    assert parse_args(["run"]).support_dir == default
    monkeypatch.setenv("SHELLFORGE_SUPPORT", "~/x")  # absolute only, as the shims read it: never expanded
    assert parse_args(["run"]).support_dir == Path("~/x")


async def test_the_helper_writes_its_files_in_the_support_folder_it_is_given(monkeypatch, tmp_path, sock_dir):
    """daemon.json and helper-python go to --support-dir, never to HOME's folder."""
    import shellforged.__main__ as entry

    home = tmp_path / "home"
    monkeypatch.setenv("HOME", str(home))
    support = tmp_path / "example-dev"
    ns = parse_args(["run", "--support-dir", str(support), "--socket", os.path.join(sock_dir, "f.sock"), "--hook-port", "0"])
    daemon = asyncio.create_task(entry.run_daemon(ns))
    try:
        await wait_until(lambda: os.path.exists(support / "daemon.json"))
        assert (support / "helper-python").read_text() == sys.executable
        assert not (home / "Library/Application Support/Shellforge").exists()
    finally:
        daemon.cancel()
        await asyncio.gather(daemon, return_exceptions=True)
        for sig in (signal.SIGINT, signal.SIGTERM):
            asyncio.get_running_loop().remove_signal_handler(sig)


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
    ns = parse_args(["run", "--socket", sock, "--hook-port", "0", "--idle-exit-seconds", "0.2"])
    daemon = asyncio.create_task(entry.run_daemon(ns))
    try:
        await wait_until(lambda: os.path.exists(tmp_path / "Library/Application Support/Shellforge/daemon.json"))
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


async def test_with_sessions_from_the_app_no_iterm2_cookie_is_asked_for(monkeypatch, tmp_path, sock_dir):
    """--cookies-from-app is for reading sessions from iTerm2. With the app as the source there is
    no cookie to ask for: asking would send the app to iTerm2 for one (an automation prompt), and
    applying it would import the iterm2 package the app source must not need."""
    import shellforged.__main__ as entry

    monkeypatch.setenv("HOME", str(tmp_path))
    sock = os.path.join(sock_dir, "c.sock")
    ns = parse_args(["run", "--socket", sock, "--hook-port", "0", "--cookies-from-app"])
    daemon = asyncio.create_task(entry.run_daemon(ns))
    try:
        await wait_until(lambda: os.path.exists(tmp_path / "Library/Application Support/Shellforge/daemon.json"))
        r, w = await asyncio.open_unix_connection(sock)
        w.write(b'{"id": 1, "method": "workspace.snapshot", "params": null}\n')
        await w.drain()
        lines = []
        deadline = asyncio.get_running_loop().time() + 0.5
        while (left := deadline - asyncio.get_running_loop().time()) > 0:
            try:
                lines.append(json.loads(await asyncio.wait_for(r.readline(), left)))
            except TimeoutError:
                break
        snapshot = next(m["result"] for m in lines if m.get("id") == 1)
        assert snapshot["connected"] and snapshot["itermCookieRequest"] is None
        assert not [m for m in lines if m.get("event") == "iterm.cookieRequested"]
        w.close()
    finally:
        daemon.cancel()
        await asyncio.gather(daemon, return_exceptions=True)
        for sig in (signal.SIGINT, signal.SIGTERM):
            asyncio.get_running_loop().remove_signal_handler(sig)


def test_the_tunnel_ledger_lives_beside_the_socket(sock_dir, tmp_path, monkeypatch):
    """A daemon run on a socket of its own keeps its tunnels beside it, never in the user's support
    folder: the app's socket is in that folder, a test's is not."""
    home = tmp_path / "home"
    monkeypatch.setenv("HOME", str(home))
    blocker = socket.socket()
    blocker.bind(("127.0.0.1", 0))
    blocker.listen(1)
    try:
        main(["run", "--socket", os.path.join(sock_dir, "s.sock"), "--hook-port", str(blocker.getsockname()[1])])
    finally:
        blocker.close()
    assert os.path.exists(os.path.join(sock_dir, "tunnels.json"))
    assert not (home / "Library/Application Support/Shellforge/tunnels.json").exists()


async def test_the_helper_writes_its_python_for_shellforge_run(monkeypatch, tmp_path, sock_dir):
    """`shellforge-run` runs under the helper's own Python, which it finds in `helper-python`."""
    import shellforged.__main__ as entry

    monkeypatch.setenv("HOME", str(tmp_path))
    support = tmp_path / "Library/Application Support/Shellforge"
    support.mkdir(parents=True)
    (support / "helper-python").write_text("/an/older/python\n")
    ns = parse_args(["run", "--socket", os.path.join(sock_dir, "p.sock"), "--hook-port", "0"])
    daemon = asyncio.create_task(entry.run_daemon(ns))
    try:
        await wait_until(lambda: os.path.exists(support / "daemon.json"))
        assert (support / "helper-python").read_text() == sys.executable
    finally:
        daemon.cancel()
        await asyncio.gather(daemon, return_exceptions=True)
        for sig in (signal.SIGINT, signal.SIGTERM):
            asyncio.get_running_loop().remove_signal_handler(sig)


def test_helper_python_is_replaced_whole(tmp_path, monkeypatch):
    """Written beside and moved into place: a reader never sees half a path, and nothing is left behind."""
    import shellforged.__main__ as entry

    target = tmp_path / "helper-python"
    target.write_text("/old/python")
    replaced = []
    real_replace = os.replace

    def replace(source, destination):
        assert target.read_text() == "/old/python"  # untouched until the move
        replaced.append((os.path.dirname(source), destination))
        real_replace(source, destination)

    monkeypatch.setattr(entry.os, "replace", replace)
    entry.write_atomically(target, "/new/python")
    assert target.read_text() == "/new/python" and replaced == [(str(tmp_path), target)]
    assert sorted(p.name for p in tmp_path.iterdir()) == ["helper-python"]
