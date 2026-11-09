"""`shellforge-status`: the command a custom agent's own hooks call to report working, needs-input
or done. One quiet POST to the helper's /status route; it always exits 0 and never prints."""
import re
import socket
import subprocess
import time
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "hooks" / "shellforge-status"


@pytest.fixture
def home(tmp_path, daemon):
    support = tmp_path / "Library" / "Application Support" / "Shellforge"
    support.mkdir(parents=True)
    (support / "hook-port").write_text(f"{daemon.server_port}\n")
    return tmp_path


def run_status(home, *args, extra_env=None, stdin=None, timeout=10):
    env = {"HOME": str(home), "PATH": "/usr/bin:/bin", "ITERM_SESSION_ID": "w0t0p0:ABC"}
    env.update(extra_env or {})
    return subprocess.run([str(SCRIPT), *args], input=stdin, capture_output=True, text=True, env=env,
                          timeout=timeout)


def wait_for(daemon, count=1):
    deadline = time.monotonic() + 3
    while len(daemon.received) < count and time.monotonic() < deadline:
        time.sleep(0.02)
    return daemon.received


def test_posts_the_state(home, daemon):
    result = run_status(home, "needs-input")
    assert (result.returncode, result.stdout, result.stderr) == (0, "", "")
    path, headers, body = wait_for(daemon)[0]
    assert path == "/status" and body == {"state": "needs-input"}
    assert headers["X-Shellforge-iTerm-Session"] == "w0t0p0:ABC" and headers["X-Shellforge-Hook"] == "1"


def test_sends_the_agent_from_the_environment(home, daemon):
    result = run_status(home, "working", extra_env={"SHELLFORGE_AGENT_ID": "my-agent_1"})
    assert result.returncode == 0
    assert wait_for(daemon)[0][2] == {"state": "working", "agent": "my-agent_1"}


@pytest.mark.parametrize("agent", ['a"b', "a b", "a" * 65, "a\\b", "x$(id)"])
def test_hostile_agent_id_is_left_out(home, daemon, agent):
    result = run_status(home, "done", extra_env={"SHELLFORGE_AGENT_ID": agent})
    assert result.returncode == 0
    assert wait_for(daemon)[0][2] == {"state": "done"}


@pytest.mark.parametrize("args", [(), ("bogus",), ('working"}',), ("working", "extra")])
def test_bad_state_posts_nothing(home, daemon, args):
    result = run_status(home, *args)
    assert (result.returncode, result.stdout, result.stderr) == (0, "", "")
    time.sleep(0.3)
    assert daemon.received == []


def test_no_port_file_exits_zero(home, daemon):
    (home / "Library" / "Application Support" / "Shellforge" / "hook-port").unlink()
    result = run_status(home, "working")
    assert (result.returncode, result.stdout, result.stderr) == (0, "", "")
    time.sleep(0.3)
    assert daemon.received == []


def test_silent_server_still_exits_zero(home):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(5)
    try:
        (home / "Library" / "Application Support" / "Shellforge" / "hook-port").write_text(
            f"{listener.getsockname()[1]}\n")
        result = run_status(home, "working", timeout=10)
        assert (result.returncode, result.stdout, result.stderr) == (0, "", "")
    finally:
        listener.close()


def test_curl_timeout_is_below_one_second():
    match = re.search(r"curl\b[^\n]*?-m\s+([0-9.]+)", SCRIPT.read_text())
    assert match and float(match.group(1)) < 1


def test_large_stdin_does_not_block(home, daemon):
    result = run_status(home, "working", stdin="x" * 1_000_000)
    assert result.returncode == 0
    assert wait_for(daemon)[0][2] == {"state": "working"}


def test_session_id_with_a_line_break_cannot_add_a_header(home, daemon):
    result = run_status(home, "working", extra_env={"ITERM_SESSION_ID": "a\r\nX-Evil: 1"})
    assert result.returncode == 0
    _, headers, body = wait_for(daemon)[0]
    assert "X-Evil" not in headers and headers.get("X-Shellforge-iTerm-Session", "") == ""
    assert body == {"state": "working"}


def test_proxy_variables_and_curlrc_are_ignored(home, daemon):
    (home / ".curlrc").write_text('proxy = "http://127.0.0.1:9"\n')
    proxy = "http://127.0.0.1:9"
    result = run_status(home, "working", extra_env={"http_proxy": proxy, "HTTP_PROXY": proxy, "all_proxy": proxy,
                                                    "ALL_PROXY": proxy})
    assert result.returncode == 0
    assert wait_for(daemon)[0][2] == {"state": "working"}
