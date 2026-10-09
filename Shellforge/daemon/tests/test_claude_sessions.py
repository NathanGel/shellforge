import json
import os
from shellforged.claude_sessions import ClaudeSessionFiles


def write(root, pid, **fields):
    (root / f"{pid}.json").write_text(json.dumps({"pid": pid, "sessionId": f"sid-{pid}", "cwd": "/w", "status": "busy",
                                                  "updatedAt": 1, **fields}))


def test_read_existing_and_missing(tmp_path):
    write(tmp_path, 42, status="thinking")
    files = ClaudeSessionFiles(tmp_path)
    f = files.read(42)
    assert (f.pid, f.session_id, f.cwd, f.status) == (42, "sid-42", "/w", "thinking")
    assert files.read(43) is None


def test_read_reports_when_claude_last_wrote_the_file(tmp_path):
    write(tmp_path, 42)
    os.utime(tmp_path / "42.json", (1_700_000_000.25, 1_700_000_000.25))
    assert ClaudeSessionFiles(tmp_path).read(42).written_at == 1_700_000_000.25


def test_read_parses_a_file_again_only_once_it_changes(tmp_path, monkeypatch):
    write(tmp_path, 42, status="busy")
    files = ClaudeSessionFiles(tmp_path)
    parsed = []
    real = ClaudeSessionFiles._parse
    monkeypatch.setattr(ClaudeSessionFiles, "_parse", staticmethod(lambda p, t: parsed.append(p.name) or real(p, t)))

    assert files.read(42).status == "busy"
    assert files.read(42).status == "busy"
    assert files.pid_for_session("sid-42") == 42
    assert parsed == ["42.json"]

    write(tmp_path, 42, status="waiting for you")
    assert files.read(42).status == "waiting for you"
    assert parsed == ["42.json", "42.json"]
    (tmp_path / "42.json").unlink()
    assert files.read(42) is None


def test_malformed_file_is_none(tmp_path):
    (tmp_path / "7.json").write_text("{not json")
    assert ClaudeSessionFiles(tmp_path).read(7) is None


def test_a_pid_that_is_not_a_finite_number_makes_a_file_unreadable_not_the_scan_fail(tmp_path):
    # json.loads accepts `Infinity`, and int() of it raises OverflowError. pid_for_session parses
    # every file in the directory, so one such file would otherwise fail every Claude hook.
    (tmp_path / "7.json").write_text('{"pid": Infinity, "sessionId": "bad"}')
    write(tmp_path, 8)
    files = ClaudeSessionFiles(tmp_path)
    assert files.read(7) is None
    assert files.pid_for_session("sid-8") == 8


def test_pid_for_session_scans_directory(tmp_path):
    write(tmp_path, 1)
    write(tmp_path, 2)
    files = ClaudeSessionFiles(tmp_path)
    assert files.pid_for_session("sid-2") == 2
    assert files.pid_for_session("nope") is None


def test_missing_root_is_fine(tmp_path):
    files = ClaudeSessionFiles(tmp_path / "does-not-exist")
    assert files.read(1) is None and files.pid_for_session("x") is None


def test_pid_lookup_parses_a_file_again_only_once_it_changes(tmp_path, monkeypatch):
    write(tmp_path, 1)
    write(tmp_path, 2)
    files = ClaudeSessionFiles(tmp_path)
    parsed = []
    real = ClaudeSessionFiles._parse
    monkeypatch.setattr(ClaudeSessionFiles, "_parse", staticmethod(lambda p, t: parsed.append(p.name) or real(p, t)))

    assert files.pid_for_session("sid-2") == 2
    assert files.pid_for_session("sid-1") == 1
    assert sorted(parsed) == ["1.json", "2.json"]

    write(tmp_path, 2, sessionId="renamed", cwd="/somewhere/longer")
    assert files.pid_for_session("renamed") == 2
    assert sorted(parsed) == ["1.json", "2.json", "2.json"]

    (tmp_path / "1.json").unlink()
    assert files.pid_for_session("sid-1") is None
