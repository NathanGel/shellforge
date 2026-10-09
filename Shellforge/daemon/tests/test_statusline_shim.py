"""The shim installed as Claude Code's `statusLine` command.

The callback forwards usage silently unless the user already has a custom status line.
These tests run the real script and capture both its output and the daemon payload. The shim
posts to the port ClaudeDriver records in `hook-port`, which here is the test server's, so nothing
reaches a daemon that happens to be running on the app's own.
"""
import json
import subprocess
import time
from pathlib import Path

import pytest

SHIM = Path(__file__).resolve().parents[2] / "hooks" / "claude-statusline-shim.sh"
PAYLOAD = {
    "model": {"id": "claude-opus-5", "display_name": "Opus 5"},
    "rate_limits": {"five_hour": {"used_percentage": 23.4, "resets_at": 1790000000}},
}


@pytest.fixture
def home(tmp_path, daemon):
    support = tmp_path / "Library" / "Application Support" / "AiTerm"
    support.mkdir(parents=True)
    (support / "hook-port").write_text(f"{daemon.server_port}\n")
    return tmp_path


def run_shim(home, payload=PAYLOAD):
    return subprocess.run([str(SHIM)], input=json.dumps(payload), capture_output=True,
                          text=True, env={"HOME": str(home), "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"})


def forwarded(daemon, timeout=3.0):
    """The POST is fired into the background so the status line is never held up; wait for it."""
    deadline = time.time() + timeout
    while time.time() < deadline and not daemon.received:
        time.sleep(0.02)
    return daemon.received


def support_of(home):
    return home / "Library" / "Application Support" / "AiTerm"


def test_forwards_the_payload_to_the_daemon(home, daemon):
    run_shim(home)
    received = forwarded(daemon)
    assert len(received) == 1
    path, headers, body = received[0]
    assert path == "/statusline"
    assert headers.get("X-AiTerm-Hook") == "1"
    assert body["rate_limits"]["five_hour"]["used_percentage"] == 23.4


def test_without_a_custom_statusline_is_silent_and_still_forwards(home, daemon):
    result = run_shim(home)
    assert result.returncode == 0
    assert result.stdout == ""
    assert result.stderr == ""
    assert forwarded(daemon)


def test_preserves_custom_statusline_and_forwards_the_same_payload(home, daemon):
    original = home / "mine.sh"
    original.write_text("#!/bin/sh\ncat > \"$HOME/original-input.json\"\necho 'my own status line'\n")
    original.chmod(0o755)
    (support_of(home) / "statusline-original.cmd").write_text(str(original))
    result = run_shim(home)
    assert result.returncode == 0
    assert result.stdout.strip() == "my own status line"
    assert json.loads((home / "original-input.json").read_text()) == PAYLOAD
    assert forwarded(daemon)[0][2] == PAYLOAD


@pytest.mark.parametrize("mode", ["quiet", "aiterm", "original", "nonsense"])
def test_legacy_display_modes_do_not_add_a_statusline(home, daemon, mode):
    (support_of(home) / "statusline-mode").write_text(mode + "\n")
    result = run_shim(home)
    assert result.returncode == 0
    assert result.stdout == ""
    assert forwarded(daemon)


def test_legacy_aiterm_mode_no_longer_replaces_custom_statusline(home, daemon):
    original = home / "mine.sh"
    original.write_text("#!/bin/sh\nread -r _line\necho 'my own status line'\n")
    original.chmod(0o755)
    (support_of(home) / "statusline-original.cmd").write_text(str(original))
    (support_of(home) / "statusline-mode").write_text("aiterm\n")
    assert run_shim(home).stdout.strip() == "my own status line"
    assert forwarded(daemon)


def test_posts_to_whatever_port_the_file_names_and_to_no_other(home, daemon):
    # The file is the only place the shim learns the port: one with no port in it posts nowhere,
    # and still shows the user's own status line.
    (support_of(home) / "hook-port").unlink()
    original = home / "mine.sh"
    original.write_text("#!/bin/sh\ncat >/dev/null\necho 'my own status line'\n")
    original.chmod(0o755)
    (support_of(home) / "statusline-original.cmd").write_text(str(original))
    result = run_shim(home)
    assert (result.returncode, result.stdout.strip(), result.stderr) == (0, "my own status line", "")
    time.sleep(0.5)
    assert daemon.received == []


def test_an_unreadable_port_file_is_silent(home, daemon):
    (support_of(home) / "hook-port").chmod(0o000)
    result = run_shim(home)
    assert (result.returncode, result.stdout, result.stderr) == (0, "", "")
    time.sleep(0.5)
    assert daemon.received == []


def test_runs_the_original_command_through_sh_without_reading_zshenv(home, daemon):
    # `#!/bin/zsh -f` and `sh -c`: the user's ~/.zshenv is never sourced on a tick, by the shim or
    # by the command it runs.
    (home / ".zshenv").write_text("echo zshenv-ran >&2\n")
    (support_of(home) / "statusline-original.cmd").write_text("cat >/dev/null; printf 'mine'")
    result = run_shim(home)
    assert (result.stdout, result.stderr) == ("mine", "")
    assert forwarded(daemon)


@pytest.mark.parametrize("written", ["1@127.0.0.1:{port}", "{port}/elsewhere?", "{port}0", "0", "abc", " {port}"])
def test_a_port_file_that_is_not_a_port_posts_nothing_and_still_runs_the_original(home, daemon, written):
    # Only 1-65535 in digits is a port: anything else in the file would put a host, a path or a
    # query into the URL curl is given.
    (support_of(home) / "hook-port").write_text(written.format(port=daemon.server_port) + "\n")
    (support_of(home) / "statusline-original.cmd").write_text("cat >/dev/null; printf 'mine'")
    result = run_shim(home)
    assert (result.returncode, result.stdout, result.stderr) == (0, "mine", "")
    time.sleep(0.5)
    assert daemon.received == []
