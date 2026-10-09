import pytest
from shellforged.models import (
    AGENT_BINARIES, END_OF_TURN_SURVIVES_CWD_LOSS, HARNESS_BY_AGENT, USAGE_VENDORS, Frame, SessionInfo, TokenTally, Usage,
    UsageWindow, classify_agent,
)


def test_the_harness_table_derives_what_each_agent_is():
    assert AGENT_BINARIES == {"claude", "codex", "grok", "pi"}
    # Grok's end of turn travels only on hooks spawned in the session's cwd.
    assert END_OF_TURN_SURVIVES_CWD_LOSS == {"claude", "codex", "pi"}
    # Claude's posts are placed by the agent's pid, everyone else's by the tab the header names.
    assert {a: h.placement for a, h in HARNESS_BY_AGENT.items()} == {
        "claude": "pid_file", "codex": "header", "grok": "header", "pi": "header"}
    # Grok and PI have no tick signal: what their hooks say stands.
    assert {a: h.corroboration for a, h in HARNESS_BY_AGENT.items()} == {
        "claude": "claude_file", "codex": "codex_title", "grok": None, "pi": None}
    assert USAGE_VENDORS == ("claude", "codex")


def test_frame_from_json():
    f = Frame.from_json({"x": 324, "y": 36.5, "w": 1104, "h": 852})
    assert (f.x, f.y, f.w, f.h) == (324, 36.5, 1104, 852)


def test_frame_rejects_a_numeric_string():
    # Stricter than float(), deliberately: the app always encodes a frame's coordinates as numbers.
    with pytest.raises(ValueError):
        Frame.from_json({"x": "324", "y": 36, "w": 1104, "h": 852})


@pytest.mark.parametrize("bad", [float("inf"), float("-inf"), float("nan"), True, False, None])
def test_frame_rejects_what_is_not_a_finite_number(bad):
    with pytest.raises(ValueError):
        Frame.from_json({"x": 324, "y": 36, "w": bad, "h": 852})


def test_classify_agent_uses_basename_of_first_token():
    assert classify_agent("claude") == "claude"
    assert classify_agent("/Users/x/.local/bin/claude --model opus") == "claude"
    assert classify_agent("codex -m gpt-5.6") == "codex"
    assert classify_agent("-zsh") == "shell"
    assert classify_agent("node /opt/homebrew/bin/pi") == "pi"
    assert classify_agent("node /opt/homebrew/bin/not-pi") == "shell"
    assert classify_agent(None) == "shell"
    assert classify_agent("") == "shell"


def test_classify_agent_ignores_case_of_the_process_name():
    # Claude Code sets its own process title and, depending on how the session was
    # started, argv[0] is "Claude" rather than "claude" (verified live with `ps`:
    # two concurrent sessions, one of each). A case-sensitive match left those
    # sessions classified as a plain shell, so the sidebar kept the terminal avatar.
    assert classify_agent("Claude") == "claude"
    assert classify_agent("/Users/x/.local/bin/Claude --model opus") == "claude"
    assert classify_agent("Codex") == "codex"


def test_classify_pi_including_its_node_shebang_process():
    assert classify_agent("pi --model openai/gpt") == "pi"
    assert classify_agent("/opt/homebrew/bin/PI") == "pi"
    assert classify_agent("/opt/homebrew/bin/node /opt/homebrew/bin/pi --model openai/gpt") == "pi"
    assert classify_agent("node worker.js") == "shell"


def test_session_info_json_is_camel_case_and_drops_job_pid():
    s = SessionInfo("s1", "w1", 0, "t1", None, "claude", "claude-opus-5", "working", "✳ Claude Code", "/repo", 4242,
                    agent_cwd="/repo/.worktrees/x")
    assert s.to_json() == {
        "sessionId": "s1", "windowId": "w1", "tabIndex": 0, "taskId": "t1", "projectId": None,
        "agent": "claude", "model": "claude-opus-5", "reasoning": None,
        "state": "working", "title": "✳ Claude Code", "cwd": "/repo",
        "agentCwd": "/repo/.worktrees/x", "active": False, "contextPercent": None, "tokens": None,
    }


def test_a_token_tally_is_sent_with_its_cached_share():
    s = SessionInfo("s1", "w1", 0, None, None, "claude", None, "working", "", "/repo", 1,
                    tokens=TokenTally(936_018, 935_988, 5_625), transcript="/t/s.jsonl")
    assert s.to_json()["tokens"] == {"input": 936_018, "cached": 935_988, "output": 5_625}
    assert "transcript" not in s.to_json()


def test_tallies_add_and_an_unknown_cached_share_stays_unknown():
    assert TokenTally(10, 4, 1) + TokenTally(5, 2, 3) == TokenTally(15, 6, 4)
    assert TokenTally(10, 4, 1) + TokenTally(5, None, 3) == TokenTally(15, None, 4)
    assert TokenTally.combined([]) is None
    assert TokenTally.combined([TokenTally(1, 1, 1), TokenTally(2, 0, 2), TokenTally(3, 1, 0)]) == TokenTally(6, 2, 3)


def test_usage_json():
    u = Usage(UsageWindow(23, 1790172996), None, None, "max", 1789568196)
    assert u.to_json() == {"fiveHour": {"usedPercent": 23, "resetsAt": 1790172996}, "sevenDay": None, "spend": None, "plan": "max",
                           "updatedAt": 1789568196}


@pytest.mark.parametrize("command_line", ["grok", "/Users/me/.grok/bin/grok --model grok-4.7", "Grok",
                                          "/Users/me/.grok/downloads/grok-macos-aarch64 -m grok-4.7",
                                          # The resolved name carries the version since 1.0.44, and the
                                          # architecture on an Intel build.
                                          "/Users/me/.grok/downloads/grok-1.0.44-macos-aarch64 -m grok-4.7",
                                          "grok-macos-x86_64", "grok-2.1-macos-x86_64"])
def test_grok_is_classified(command_line):
    assert classify_agent(command_line) == "grok"


@pytest.mark.parametrize("command_line", ["grokker", "node /x/grok-cli.js", "grep grok", "grok-cli",
                                          "grok-1.0.44", "grok-macos-", "grok-v1-macos-aarch64"])
def test_grok_lookalikes_stay_shell(command_line):
    assert classify_agent(command_line) == "shell"
