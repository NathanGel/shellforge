"""`shellforge-run <agent-id> -- <command…>`: takes the environment the app armed for this tab from the
helper, and execs the agent with it. Nothing it prints ever holds a value it was given."""
import asyncio
import fcntl
import io
import json
import os
import socket
import subprocess
import sys
import termios
import threading
from pathlib import Path

import pytest

from shellforged import launch_env, run_agent, service
from tests.conftest import wait_until
from shellforged.app_sessions import AppSessions
from shellforged.rpc_server import RpcServer

LAUNCHER = Path(__file__).resolve().parents[2] / "hooks" / "shellforge-run"
SECRET_VALUE = "sk-live-0123456789abcdef"
FAILURE = "shellforge-run: Shellforge didn’t send gemini’s settings. Start the task again from Shellforge.\n"
USAGE = "usage: shellforge-run <agent-id> -- <command> [arguments…]\n"
SESSION = "w0t0p0:ABC-123"


class Execed(Exception):
    def __init__(self, file, args, env):
        super().__init__("execed")
        self.file, self.argv, self.env = file, args, env


def fake_exec(file, args, env):
    raise Execed(file, args, env)


def answering(reply=None, raises=None):
    calls = []

    def request(method, params):
        calls.append((method, params))
        if raises is not None:
            raise raises
        return reply

    request.calls = calls
    return request


def run(argv, env=None, request=None):
    err = io.StringIO()
    env = {"ITERM_SESSION_ID": SESSION, "PATH": "/usr/bin", "HOME": "/Users/x"} if env is None else env
    request = request or answering({"id": 1, "result": {"environment": {"API_KEY": SECRET_VALUE}}})
    try:
        code = run_agent.main(argv, env, request, fake_exec, err)
    except Execed as execed:
        return execed, err.getvalue(), request
    return code, err.getvalue(), request


def test_execs_with_the_environment():
    execed, err, request = run(["gemini", "--", "gemini", "--yolo", "fix it"])
    assert isinstance(execed, Execed) and err == ""
    assert execed.file == "gemini" and execed.argv == ["gemini", "--yolo", "fix it"]
    assert execed.env["API_KEY"] == SECRET_VALUE and execed.env["SHELLFORGE_AGENT_ID"] == "gemini"
    assert execed.env["PATH"] == "/usr/bin" and execed.env["ITERM_SESSION_ID"] == SESSION
    assert request.calls == [("agents.takeLaunch", {"session": SESSION, "agentId": "gemini"})]


def test_an_empty_environment_still_sets_the_agent_id():
    execed, _, _ = run(["goose", "--", "goose"], request=answering({"id": 1, "result": {"environment": {}}}))
    assert isinstance(execed, Execed) and execed.env["SHELLFORGE_AGENT_ID"] == "goose"


def test_the_armed_environment_cannot_change_the_agent_id():
    reply = {"id": 1, "result": {"environment": {"SHELLFORGE_AGENT_ID": "other"}}}
    execed, _, _ = run(["gemini", "--", "gemini"], request=answering(reply))
    assert execed.env["SHELLFORGE_AGENT_ID"] == "gemini"


def test_not_armed_fails_without_exec():
    reply = {"id": 1, "error": {"code": "not_found", "message": "nothing armed for this tab"}}
    code, err, _ = run(["gemini", "--", "gemini"], request=answering(reply))
    assert (code, err) == (1, FAILURE)


@pytest.mark.parametrize("raises", [ConnectionRefusedError(61, "Connection refused"), FileNotFoundError(2, "gone"),
                                    TimeoutError("timed out"), ValueError("not JSON")])
def test_helper_down_fails_without_exec(raises):
    code, err, _ = run(["gemini", "--", "gemini"], request=answering(raises=raises))
    assert (code, err) == (1, FAILURE)


@pytest.mark.parametrize("reply", [{"id": 1, "result": None}, {"id": 1, "result": {"environment": {"A": 1}}},
                                   {"id": 1, "result": {"environment": ["A"]}}, {"id": 1}])
def test_an_unreadable_reply_fails_without_exec(reply):
    code, err, _ = run(["gemini", "--", "gemini"], request=answering(reply))
    assert (code, err) == (1, FAILURE)


@pytest.mark.parametrize("session", [None, "", "w0t0p0:ABC\n", "a" * 200, "w0t0p0:$(id)"])
def test_no_session_fails(session):
    env = {"PATH": "/usr/bin"} if session is None else {"PATH": "/usr/bin", "ITERM_SESSION_ID": session}
    code, err, request = run(["gemini", "--", "gemini"], env=env)
    assert (code, err) == (1, FAILURE) and request.calls == []


@pytest.mark.parametrize("argv", [[], ["gemini"], ["gemini", "gemini"], ["gemini", "--"], ["--", "gemini"],
                                  ["gem ini", "--", "gemini"], ["a\x1b]0;x\x07", "--", "x"], ["a" * 65, "--", "x"]])
def test_missing_dash_dash_is_usage(argv):
    code, err, request = run(argv)
    assert (code, err) == (2, USAGE) and request.calls == []


def test_a_command_that_will_not_start_says_so_without_values():
    def refuse(file, args, env):
        raise FileNotFoundError(2, "No such file or directory", file)

    err = io.StringIO()
    request = answering({"id": 1, "result": {"environment": {"API_KEY": SECRET_VALUE}}})
    code = run_agent.main(["gemini", "--", "gemini"], {"ITERM_SESSION_ID": SESSION}, request, refuse, err)
    assert code == 127
    assert err.getvalue() == "shellforge-run: gemini couldn’t be started: No such file or directory.\n"


def test_a_nul_in_the_command_says_so_in_one_line():
    def nul(file, args, env):
        raise ValueError("embedded null byte")

    err = io.StringIO()
    request = answering({"id": 1, "result": {"environment": {"API_KEY": SECRET_VALUE}}})
    code = run_agent.main(["gemini", "--", "gemini", "a\x00b"], {"ITERM_SESSION_ID": SESSION}, request, nul, err)
    assert code == 127
    assert err.getvalue() == "shellforge-run: gemini couldn’t be started: an argument or setting holds a NUL character.\n"


def test_control_characters_in_the_command_are_not_printed():
    def refuse(file, args, env):
        raise FileNotFoundError(2, "No such file or directory", file)

    err = io.StringIO()
    request = answering({"id": 1, "result": {"environment": {}}})
    code = run_agent.main(["gemini", "--", "gem\x1b]0;owned\x07ini\n"], {"ITERM_SESSION_ID": SESSION}, request, refuse, err)
    assert code == 127
    assert err.getvalue() == "shellforge-run: gem]0;ownedini couldn’t be started: No such file or directory.\n"


def test_control_c_while_waiting_exits_quietly():
    code, err, _ = run(["gemini", "--", "gemini"], request=answering(raises=KeyboardInterrupt()))
    assert (code, err) == (130, "")


def test_no_value_is_ever_printed():
    """Every path, with the secret in the reply, in the error message and in the exception."""
    replies = [
        answering({"id": 1, "result": {"environment": {"API_KEY": SECRET_VALUE}}}),
        answering({"id": 1, "error": {"code": "not_found", "message": SECRET_VALUE}}),
        answering({"id": 1, "result": {"environment": {"API_KEY": SECRET_VALUE, "N": 1}}}),
        answering(raises=OSError(5, SECRET_VALUE)),
        answering(raises=ValueError(SECRET_VALUE)),
        answering(raises=RuntimeError(SECRET_VALUE)),
    ]
    execs = [fake_exec, lambda f, a, e: (_ for _ in ()).throw(OSError(13, SECRET_VALUE, f))]
    for request in replies:
        for execvpe in execs:
            for argv in (["gemini", "--", "gemini"], ["gemini"]):
                err = io.StringIO()
                try:
                    run_agent.main(argv, {"ITERM_SESSION_ID": SESSION}, request, execvpe, err)
                except Execed:
                    pass
                assert SECRET_VALUE not in err.getvalue()


def test_the_socket_outwaits_the_helper():
    assert run_agent.SOCKET_TIMEOUT_SECONDS > launch_env.TAKE_WAIT_SECONDS


def test_the_default_socket_is_the_helpers(monkeypatch):
    assert run_agent.default_socket({"HOME": "/Users/x"}) == "/Users/x/Library/Application Support/Shellforge/shellforged.sock"


def test_the_socket_is_in_the_support_folder_the_app_set():
    env = {"HOME": "/Users/x", "SHELLFORGE_SUPPORT": "/Users/x/Library/Application Support/example-dev"}
    assert run_agent.default_socket(env) == "/Users/x/Library/Application Support/example-dev/shellforged.sock"
    assert run_agent.default_socket({**env, "SHELLFORGE_SUPPORT": ""}).endswith("/Shellforge/shellforged.sock")


def serve_once(path, lines):
    """A Unix socket that reads one request and writes `lines`, each built from the request."""
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(1)
    received = []

    def answer():
        conn, _ = server.accept()
        with conn:
            data = b""
            while not data.endswith(b"\n"):
                data += conn.recv(4096)
            request = json.loads(data)
            received.append(request)
            try:
                for line in lines(request):
                    conn.sendall(line)
            except OSError:
                pass  # the client gave up and left
        server.close()

    thread = threading.Thread(target=answer, daemon=True)
    thread.start()
    return received, thread


def test_socket_request_skips_events_to_its_reply(sock_dir):
    path = os.path.join(sock_dir, "r.sock")

    def lines(request):
        yield (json.dumps({"event": "session.changed", "payload": {"x": 1}}) + "\n").encode()
        reply = json.dumps({"id": request["id"], "result": {"environment": {"A": "b"}}}) + "\n"
        yield reply[:7].encode()  # a reply split across writes
        yield reply[7:].encode()

    received, thread = serve_once(path, lines)
    reply = run_agent.socket_request(path, 2.0)("agents.takeLaunch", {"session": "S", "agentId": "a"})
    thread.join(2)
    assert reply == {"id": received[0]["id"], "result": {"environment": {"A": "b"}}}
    assert received[0]["method"] == "agents.takeLaunch" and received[0]["params"] == {"session": "S", "agentId": "a"}


def test_socket_request_fails_when_the_helper_hangs_up(sock_dir):
    path = os.path.join(sock_dir, "h.sock")
    _, thread = serve_once(path, lambda request: iter(()))
    with pytest.raises(ConnectionError):
        run_agent.socket_request(path, 2.0)("agents.takeLaunch", {})
    thread.join(2)


def test_events_alone_do_not_stretch_the_wait(sock_dir):
    """A helper that keeps broadcasting but never answers: the request still ends at its timeout."""
    path = os.path.join(sock_dir, "e.sock")
    stop = threading.Event()

    def lines(request):
        while not stop.is_set():
            yield b'{"event": "usage.changed", "payload": {}}\n'
            stop.wait(0.02)

    _, thread = serve_once(path, lines)
    try:
        with pytest.raises(TimeoutError):
            run_agent.socket_request(path, 0.3)("agents.takeLaunch", {})
    finally:
        stop.set()
        thread.join(2)


def test_socket_request_fails_when_nothing_listens(sock_dir):
    with pytest.raises(OSError):
        run_agent.socket_request(os.path.join(sock_dir, "none.sock"), 2.0)("agents.takeLaunch", {})


# -- the launcher, end to end -----------------------------------------------------------------

def launcher_env(home, session=SESSION):
    return {"HOME": str(home), "PATH": "/usr/bin:/bin", "ITERM_SESSION_ID": session}


def write_helper_python(home, python):
    support = Path(home) / "Library" / "Application Support" / "Shellforge"
    support.mkdir(parents=True, exist_ok=True)
    (support / "helper-python").write_text(python)
    return support


async def run_launcher(home, *args, session=SESSION):
    proc = await asyncio.create_subprocess_exec(str(LAUNCHER), *args, env=launcher_env(home, session),
                                                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
                                                start_new_session=True)  # on no terminal, wherever pytest runs
    out, err = await asyncio.wait_for(proc.communicate(), 30)
    return proc.returncode, out.decode(), err.decode()


def test_the_launcher_is_executable():
    assert os.access(LAUNCHER, os.X_OK)


async def test_the_launcher_without_a_helper_python_fails(tmp_path):
    assert await run_launcher(tmp_path, "gemini", "--", "/usr/bin/true") == (1, "", FAILURE)
    write_helper_python(tmp_path, str(tmp_path / "no-such-python"))
    assert await run_launcher(tmp_path, "gemini", "--", "/usr/bin/true") == (1, "", FAILURE)


async def test_the_launcher_without_python_still_checks_the_id(tmp_path):
    assert await run_launcher(tmp_path, "a\x1b]0;x\x07", "--", "/usr/bin/true") == (2, "", USAGE)


async def test_the_launcher_with_the_helper_down_fails(sock_dir):
    write_helper_python(sock_dir, sys.executable)
    assert await run_launcher(sock_dir, "gemini", "--", "/usr/bin/true") == (1, "", FAILURE)


async def rpc(r, w, id_, method, params):
    w.write((json.dumps({"id": id_, "method": method, "params": params}) + "\n").encode())
    await w.drain()
    while (reply := json.loads(await asyncio.wait_for(r.readline(), 5))).get("id") != id_:
        pass
    return reply


def read_all(master):
    """A pty's output until its other end closes (EIO on macOS)."""
    output = b""
    while True:
        try:
            chunk = os.read(master, 4096)
        except OSError:
            return output
        if not chunk:
            return output
        output += chunk


def take_terminal():
    """In the child: a session of its own, whose controlling terminal is the pty on its stdin."""
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


async def test_the_launcher_runs_the_agent_with_its_armed_environment(sock_dir, make_service, monkeypatch):
    """End to end, with the kernel's real terminals: the app arms the tab, the launcher runs on that
    tab's terminal (a pty) and gets the values once the app's list names its job; a run from another
    terminal gets nothing and leaves the arm. HOME is the short socket folder, so the helper's socket
    path fits in the 104 bytes macOS allows."""
    monkeypatch.setattr(service, "TAKE_WAIT_SECONDS", 5.0)
    support = write_helper_python(sock_dir, sys.executable)
    svc = make_service(iterm=AppSessions(), rpc=RpcServer(str(support / "shellforged.sock")))
    await svc.start()
    r, w = await asyncio.open_unix_connection(svc.rpc.path)
    master, slave = os.openpty()
    try:
        armed = await rpc(r, w, 1, "agents.armLaunch", {"sessionId": "ABC-123", "agentId": "gemini",
                                                         "environment": {"API_KEY": SECRET_VALUE}})
        assert armed["result"] == {"ok": True}
        check = 'test "$API_KEY" = "$1" && test "$SHELLFORGE_AGENT_ID" = gemini && echo armed'
        argv = [str(LAUNCHER), "gemini", "--", "/bin/sh", "-c", check, "sh", SECRET_VALUE]

        # From a process on no terminal (another tab, a background job): refused, the arm kept.
        monkeypatch.setattr(service, "TAKE_WAIT_SECONDS", 0.2)
        await rpc(r, w, 2, "sessions.update", {"sessions": [{
            "sessionId": "ABC-123", "windowId": "w1", "tabIndex": 0, "commandLine": "zsh", "jobPid": os.getpid(),
            "title": "t", "cwd": "/", "active": True}]})
        assert await run_launcher(sock_dir, *argv[1:]) == (1, "", FAILURE)
        assert svc.launches.armed_sessions() == ["ABC-123"]

        # The tab's own: its job is the launcher itself, as the app's next list says.
        monkeypatch.setattr(service, "TAKE_WAIT_SECONDS", 5.0)
        proc = subprocess.Popen(argv, env=launcher_env(sock_dir, "w0t0p0:ABC-123"),
                                stdin=slave, stdout=slave, stderr=slave, preexec_fn=take_terminal)
        os.close(slave)  # the child's alone now, so the pty ends when it does
        slave = -1
        await wait_until(lambda: len(svc.rpc._requests) == 1, timeout=10)  # its take waits for the list
        await rpc(r, w, 3, "sessions.update", {"sessions": [{
            "sessionId": "ABC-123", "windowId": "w1", "tabIndex": 0, "commandLine": "gemini", "jobPid": proc.pid,
            "title": "t", "cwd": "/", "active": True}]})
        # Read while it runs: a terminal's last close waits for its output to be read.
        output = await asyncio.to_thread(read_all, master)
        assert await asyncio.to_thread(proc.wait, 10) == 0
        assert output.replace(b"\r", b"") == b"armed\n"
        assert svc.launches.armed_sessions() == []
    finally:
        w.close()
        os.close(master)
        if slave >= 0:
            os.close(slave)
