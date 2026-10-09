import json

import pytest

from shellforged.claude_sessions import ClaudeSessionFiles
from shellforged.models import RawSession
from shellforged.resolver import SessionResolver
from shellforged.sessions import SessionRegistry


@pytest.fixture
def world(tmp_path):
    """Two Claude tabs and a Codex tab sharing /repo; `b` was seen after `a`."""
    reg = SessionRegistry()
    reg.apply_snapshot([
        RawSession("a", "w1", 0, "claude", 101, "", "/repo", {}),
        RawSession("b", "w1", 1, "claude", 102, "", "/repo", {}),
        RawSession("x", "w1", 2, "codex", 103, "", "/repo", {}),
    ])
    files = ClaudeSessionFiles(tmp_path)
    return SessionResolver(reg, files), reg, files


def claude_file(files, pid, session_id):
    (files.root / f"{pid}.json").write_text(json.dumps({"pid": pid, "sessionId": session_id, "cwd": "/repo", "status": "busy"}))


def test_claude_resolves_by_pid_before_anything_else(world):
    resolver, _, files = world
    claude_file(files, 101, "conv-a")
    resolver.bind("b", "claude", "conv-a")
    assert resolver.resolve("claude", "conv-a", "/repo") == "a"


def test_a_pin_beats_the_directory_heuristic(world):
    resolver, _, _ = world
    # No session file: by directory alone the most recently seen tab, `b`, would win.
    assert resolver.resolve("claude", "conv-a", "/repo") == "b"
    resolver.bind("a", "claude", "conv-a")
    assert resolver.resolve("claude", "conv-a", "/repo") == "a"
    # The pin also survives the agent leaving the shell's directory.
    assert resolver.resolve("claude", "conv-a", "/repo/.worktrees/feat") == "a"


def test_a_pin_is_ignored_once_its_tab_runs_another_agent(world):
    resolver, reg, _ = world
    resolver.bind("a", "claude", "conv-a")
    reg.apply_snapshot([
        RawSession("a", "w1", 0, "-zsh", 201, "", "/repo", {}),
        RawSession("b", "w1", 1, "claude", 102, "", "/repo", {}),
    ])
    assert resolver.resolve("claude", "conv-a", "/repo") == "b"


def test_the_hooks_own_prefixed_tab_id_wins_for_its_agent_only(world):
    resolver, _, _ = world
    assert resolver.resolve("codex", "t1", "/elsewhere", "w1t2p0:x") == "x"
    assert resolver.resolve("pi", "p1", "/elsewhere", "w1t2p0:x") is None


def test_a_codex_thread_waits_for_the_next_snapshot_to_learn_its_process(world):
    resolver, reg, _ = world
    resolver.bind("x", "codex", "thread-1", "UserPromptSubmit")
    # The replacement process posts before iTerm2 has reported its pid.
    reg.apply_snapshot([RawSession("x", "w1", 2, "codex", 104, "", "/repo", {})])
    resolver.snapshot_applied()
    assert resolver.codex_thread("x") == "thread-1"
    # Bound to 104 from here on: another process in the tab is another conversation.
    reg.apply_snapshot([RawSession("x", "w1", 2, "codex", 105, "", "/repo", {})])
    resolver.snapshot_applied()
    assert resolver.codex_thread("x") is None


def test_a_stop_binds_the_thread_to_the_process_it_came_from(world):
    resolver, reg, _ = world
    resolver.bind("x", "codex", "thread-1", "Stop")
    reg.apply_snapshot([RawSession("x", "w1", 2, "codex", 104, "", "/repo", {})])
    resolver.snapshot_applied()
    assert resolver.codex_thread("x") is None


def test_grok_resolves_directly_by_iterm_session(tmp_path):
    reg = SessionRegistry()
    reg.apply_snapshot([RawSession("tab-1", "w1", 0, "grok", 41, "", "/wt", {"shellforge_task": "t1"})])
    resolver = SessionResolver(reg, ClaudeSessionFiles(tmp_path))
    # $ITERM_SESSION_ID carries a pane prefix; iTerm2's API reports only the suffix.
    assert resolver.resolve_directly("grok", "g-1", "w0t0p0:tab-1") == "tab-1"
