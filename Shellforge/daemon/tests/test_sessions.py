from shellforged.models import RawSession, TokenTally
from shellforged.sessions import SessionRegistry


def raw(sid="s1", win="w1", tab=0, cmd="-zsh", pid=100, title="zsh", cwd="/home", active=False, **vars_):
    return RawSession(sid, win, tab, cmd, pid, title, cwd, dict(vars_), active=active)


def test_first_snapshot_opens_sessions_with_agent_and_tag():
    reg = SessionRegistry()
    assert reg.apply_snapshot([raw(cmd="claude", shellforge_task="t1")]).opened == ["s1"]
    assert reg.get("s1").to_json() == ({
        "sessionId": "s1", "windowId": "w1", "tabIndex": 0, "taskId": "t1", "projectId": None,
        "agent": "claude", "model": None, "reasoning": None, "state": "idle", "title": "zsh", "cwd": "/home",
        "agentCwd": None, "active": False, "contextPercent": None, "tokens": None})


def test_untagged_session_in_tagged_window_inherits_task():
    reg = SessionRegistry()
    reg.apply_snapshot([raw(sid="s1", shellforge_task="t1")])
    assert reg.apply_snapshot([raw(sid="s1", shellforge_task="t1"), raw(sid="s2", tab=1)]).opened == ["s2"]
    assert reg.get("s2").task_id == "t1"


def test_changed_and_closed_events_and_state_preserved():
    reg = SessionRegistry()
    reg.apply_snapshot([raw(sid="s1", cmd="-zsh")])
    assert reg.set_state("s1", "working") is True
    assert reg.set_state("s1", "working") is False
    diff = reg.apply_snapshot([raw(sid="s1", cmd="codex -m gpt-5.6", title="◆ repo")])
    assert (diff.opened, diff.changed, diff.closed, diff.replaced) == ([], ["s1"], [], [])
    assert reg.get("s1").agent == "codex" and reg.get("s1").state == "working"
    assert reg.apply_snapshot([]).closed == ["s1"]
    assert reg.get("s1") is None


def test_lookups():
    reg = SessionRegistry()
    reg.apply_snapshot([raw(sid="a", cmd="claude", pid=1, cwd="/x", shellforge_task="t1"),
                        raw(sid="b", win="w2", cmd="claude", pid=2, cwd="/x")])
    assert reg.by_job_pid(2).session_id == "b"
    assert [s.session_id for s in reg.by_cwd_and_agent("/x", "claude")] == ["a", "b"]
    assert [s.session_id for s in reg.for_task("t1")] == ["a"]
    assert reg.set_model("a", "claude-opus-5") is True and reg.get("a").model == "claude-opus-5"
    assert reg.set_reasoning("a", "high") is True and reg.get("a").reasoning == "high"


def test_most_recent_uses_first_seen_order():
    reg = SessionRegistry()
    reg.apply_snapshot([raw(sid="b", win="w2", cmd="claude", cwd="/x")])
    # "a" is only discovered in this later snapshot, in a window ("w1") that
    # sorts before "w2" -- by_cwd_and_agent's (window_id, tab_index) order
    # would put "a" first, but most_recent must still prefer it because it
    # was *seen* later, not because of how it sorts.
    reg.apply_snapshot([raw(sid="b", win="w2", cmd="claude", cwd="/x"), raw(sid="a", win="w1", cmd="claude", cwd="/x")])
    candidates = reg.by_cwd_and_agent("/x", "claude")
    assert [s.session_id for s in candidates] == ["a", "b"]
    assert reg.most_recent(candidates).session_id == "a"
    assert reg.most_recent([]) is None


def test_window_tags_are_evicted_when_window_closes():
    reg = SessionRegistry()
    # Create sessions with task and project tags in different windows
    reg.apply_snapshot([raw(sid="s1", win="w1", shellforge_task="t1"), raw(sid="s2", win="w3", shellforge_project="p1")])
    assert reg.task_for_window("w1") == "t1"
    assert reg._window_project.get("w3") == "p1"
    # Close all windows - both tag dicts should be cleaned up
    reg.apply_snapshot([])
    assert reg.task_for_window("w1") is None
    assert reg._window_project == {}


def test_project_for_window_answers_alongside_task_for_window():
    reg = SessionRegistry()
    reg.apply_snapshot([raw(sid="s1", win="w1", shellforge_task="t1"), raw(sid="s2", win="w3", shellforge_project="p1")])
    assert reg.project_for_window("w3") == "p1"
    assert reg.project_for_window("w1") is None
    reg.apply_snapshot([])
    assert reg.project_for_window("w3") is None


def test_agent_cwd_survives_a_snapshot_and_is_published():
    reg = SessionRegistry()
    reg.apply_snapshot([raw(cmd="claude", pid=4242, cwd="/repo")])
    assert reg.set_agent_cwd("s1", "/repo/.worktrees/feat") is True
    assert reg.set_agent_cwd("s1", "/repo/.worktrees/feat") is False  # idempotent
    assert reg.set_agent_cwd("s1", None) is False                     # nothing to learn
    reg.apply_snapshot([raw(cmd="claude", pid=4242, cwd="/repo", title="busy")])
    assert reg.get("s1").agent_cwd == "/repo/.worktrees/feat"
    assert reg.get("s1").to_json()["agentCwd"] == "/repo/.worktrees/feat"


def test_active_session_is_remembered_per_window():
    reg = SessionRegistry()
    reg.apply_snapshot([raw(sid="s1", tab=0, cmd="claude"), raw(sid="s2", tab=1, active=True)])
    assert reg.active_for_window("w1") == "s2"
    assert reg.get("s2").to_json()["active"] is True
    assert reg.get("s1").to_json()["active"] is False
    # A snapshot that marks nothing active (iTerm2 not frontmost) keeps the last answer.
    reg.apply_snapshot([raw(sid="s1", tab=0, cmd="claude"), raw(sid="s2", tab=1)])
    assert reg.active_for_window("w1") == "s2"
    # A window that goes away takes its answer with it.
    reg.apply_snapshot([])
    assert reg.active_for_window("w1") is None


def test_set_context_reports_only_real_changes():
    reg = SessionRegistry()
    reg.apply_snapshot([raw(sid="a", cmd="claude", pid=1, cwd="/x")])
    assert reg.get("a").context_percent is None
    assert reg.set_context("a", 42) is True and reg.get("a").context_percent == 42
    # Unchanged: the statusline ticks constantly and must not broadcast a no-op.
    assert reg.set_context("a", 42) is False
    assert reg.set_context("a", 43) is True
    assert reg.set_context("missing", 10) is False


def test_context_percent_is_published_on_the_session():
    reg = SessionRegistry()
    reg.apply_snapshot([raw(sid="a", cmd="claude", pid=1, cwd="/x")])
    reg.set_context("a", 42)
    assert reg.get("a").to_json()["contextPercent"] == 42


def test_context_survives_the_next_iterm_snapshot():
    reg = SessionRegistry()
    reg.apply_snapshot([raw(sid="a", cmd="claude", pid=1, cwd="/x")])
    reg.set_context("a", 42)

    assert reg.apply_snapshot([raw(sid="a", cmd="claude", pid=1, cwd="/y")]).changed == ["a"]

    assert reg.get("a").context_percent == 42
    assert reg.get("a").to_json()["contextPercent"] == 42


def test_tokens_and_transcript_survive_the_next_iterm_snapshot():
    reg = SessionRegistry()
    reg.apply_snapshot([raw(sid="a", cmd="claude", pid=1, cwd="/x")])
    assert reg.set_tokens("a", TokenTally(10, 4, 2)) is True
    assert reg.set_tokens("a", TokenTally(10, 4, 2)) is False
    assert reg.set_transcript("a", "/t/a.jsonl") is True

    reg.apply_snapshot([raw(sid="a", cmd="claude", pid=1, cwd="/y")])

    assert reg.get("a").tokens == TokenTally(10, 4, 2)
    assert reg.get("a").transcript == "/t/a.jsonl"


def test_tokens_do_not_survive_a_tab_starting_another_agent():
    reg = SessionRegistry()
    reg.apply_snapshot([raw(sid="a", cmd="claude", pid=1, cwd="/x")])
    reg.set_tokens("a", TokenTally(10, 4, 2))
    reg.set_transcript("a", "/t/a.jsonl")

    reg.apply_snapshot([raw(sid="a", cmd="codex", pid=2, cwd="/x")])

    assert reg.get("a").tokens is None and reg.get("a").transcript is None


def test_reasoning_survives_the_next_iterm_snapshot_and_is_published():
    reg = SessionRegistry()
    reg.apply_snapshot([raw(sid="a", cmd="pi", pid=1, cwd="/x")])
    reg.set_reasoning("a", "high")

    reg.apply_snapshot([raw(sid="a", cmd="pi", pid=1, cwd="/x", title="busy")])

    assert reg.get("a").reasoning == "high"
    assert reg.get("a").to_json()["reasoning"] == "high"


def test_context_does_not_cross_providers_when_a_tab_starts_another_agent():
    reg = SessionRegistry()
    reg.apply_snapshot([raw(sid="a", cmd="claude", pid=1, cwd="/x")])
    reg.set_context("a", 42)

    diff = reg.apply_snapshot([raw(sid="a", cmd="codex", pid=2, cwd="/x")])

    assert reg.get("a").agent == "codex"
    assert reg.get("a").context_percent is None
    assert (diff.changed, diff.replaced) == (["a"], ["a"])


def test_a_shell_tab_drops_the_exited_agents_metadata():
    reg = SessionRegistry()
    reg.apply_snapshot([raw(sid="a", cmd="claude", pid=100, cwd="/repo")])
    reg.set_agent_cwd("a", "/repo/.worktrees/feat")
    reg.set_model("a", "claude-opus-5")
    reg.set_reasoning("a", "high")
    reg.set_state("a", "done")

    reg.apply_snapshot([raw(sid="a", cmd="-zsh", pid=200, cwd="/repo")])

    s = reg.get("a")
    assert (s.agent, s.agent_cwd, s.model, s.reasoning) == ("shell", None, None, None)
    # The state is the status engine's to settle: an unseen `done` stays until then -- which, for a
    # tab back at its shell, is the same tick (StatusEngine.agent_exited).
    assert s.state == "done"


def test_the_same_agent_under_a_new_process_starts_without_the_old_metadata():
    reg = SessionRegistry()
    reg.apply_snapshot([raw(sid="a", cmd="claude", pid=100, cwd="/repo")])
    reg.set_agent_cwd("a", "/repo/.worktrees/feat")
    reg.set_model("a", "claude-opus-5")

    reg.apply_snapshot([raw(sid="a", cmd="claude", pid=300, cwd="/repo")])

    assert (reg.get("a").agent_cwd, reg.get("a").model) == (None, None)


def test_a_title_only_change_is_no_change_but_the_registry_keeps_the_new_title():
    """A Codex spinner turns on almost every poll. Clients do not read the title, so announcing
    each turn only has them decode and discard it; the status engine, which does, reads it from
    the registry."""
    reg = SessionRegistry()
    reg.apply_snapshot([raw(sid="s1", cmd="codex", title="⠋ repo")])

    diff = reg.apply_snapshot([raw(sid="s1", cmd="codex", title="⠙ repo")])

    assert (diff.opened, diff.changed, diff.closed, diff.replaced) == ([], [], [], [])
    assert reg.get("s1").title == "⠙ repo"


def test_a_title_change_alongside_another_change_is_still_announced_with_the_new_title():
    reg = SessionRegistry()
    reg.apply_snapshot([raw(sid="s1", cmd="codex", title="⠋ repo", cwd="/a")])

    diff = reg.apply_snapshot([raw(sid="s1", cmd="codex", title="⠙ repo", cwd="/b")])

    assert diff.changed == ["s1"]
    assert reg.get("s1").title == "⠙ repo" and reg.get("s1").to_json()["title"] == "⠙ repo"


def test_a_folder_matches_whichever_way_a_symlink_spells_it(tmp_path):
    """iTerm2 reports a tab's folder as the shell spells it (/tmp/…), an agent's hook as the process
    resolved it (/private/tmp/…): one folder, so one match, however a symlink spells it."""
    real = tmp_path / "real" / "repo"
    real.mkdir(parents=True)
    link = tmp_path / "link"
    link.symlink_to(tmp_path / "real")
    r = SessionRegistry()
    r.apply_snapshot([raw("s1", cmd="claude", cwd=str(link / "repo"))])
    assert [s.session_id for s in r.by_cwd_and_agent(str(real), "claude")] == ["s1"]
    assert r.by_cwd_and_agent(str(tmp_path / "elsewhere"), "claude") == []
