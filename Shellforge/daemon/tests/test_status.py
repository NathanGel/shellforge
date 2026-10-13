import pytest
from shellforged import status
from shellforged.claude_subagents import TranscriptTail
from shellforged.hook_events import HookEvent
from shellforged.models import RawSession, TokenTally
from shellforged.sessions import SessionRegistry
from shellforged.status import StatusEngine, path_is_missing


class Clock:
    def __init__(self) -> None:
        self.now = 100.0

    def __call__(self) -> float:
        return self.now


# When a session file was written, for a test about what it says rather than about its age: after
# any hook the engine's clock has stamped.
FRESH = 1000.0


def hook(kind, subagent_id=None, **fields):
    """A hook that reports `kind`: the engine reads only what it says of the turn, not whose it is."""
    return HookEvent("claude", kind, None, None, None, subagent_id, **fields)


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def eng(clock):
    reg = SessionRegistry()
    reg.apply_snapshot([RawSession("s1", "w1", 0, "claude", 1, "", "/x", {"shellforge_task": "t1"}),
                        RawSession("s2", "w1", 1, "codex", 2, "", "/x", {})])
    return StatusEngine(reg, clock), reg


@pytest.mark.parametrize("sequence,expected", [
    (["working"], "working"),
    (["working", "needsInput"], "needsInput"),
    (["working", "needsInput", "working"], "working"),
    (["working", "done"], "done"),
    (["working", "needsInput", "done"], "done"),
])
def test_hook_signal_transitions(eng, sequence, expected):
    engine, reg = eng
    for kind in sequence:
        engine.apply_event("s1", hook(kind))
    assert reg.get("s1").state == expected


@pytest.mark.parametrize("before,after", [
    ("working", "done"), ("needsInput", "done"),
    # A backstop that fires a minute after the turn ended: an unread done stays unread, and a
    # seen one is not marked again.
    ("done", "done"), ("idle", "idle"),
])
def test_settle_ends_only_a_turn_still_in_flight(eng, before, after):
    engine, reg = eng
    reg.set_state("s1", before)
    assert engine.apply_event("s1", hook("settle")) == (["s1"] if before != after else [])
    assert reg.get("s1").state == after


def test_a_late_report_for_an_earlier_turn_is_ignored(eng):
    # Grok dispatches a cancelled turn's report off its command loop, so it can land after the next
    # turn's UserPromptSubmit.
    engine, reg = eng
    engine.apply_event("s1", hook("working", turn_id="p1", starts_turn=True))
    engine.apply_event("s1", hook("working", turn_id="p2", starts_turn=True))
    for kind in ("done", "needsInput", "working"):
        assert engine.apply_event("s1", hook(kind, turn_id="p1")) == []
    engine.apply_event("s1", hook("needsInput", turn_id="p2"))
    assert reg.get("s1").state == "needsInput"
    engine.apply_event("s1", hook("done", turn_id="p2"))
    assert reg.get("s1").state == "done"


def test_a_report_for_a_turn_never_seen_to_start_leaves_idle_alone(eng):
    # An interrupted bash-mode command reports StopCancelled without a UserPromptSubmit.
    engine, reg = eng
    assert engine.apply_event("s1", hook("done", turn_id="bash-1")) == []
    assert reg.get("s1").state == "idle"
    engine.apply_event("s1", hook("working", turn_id="p1", starts_turn=True))
    engine.apply_event("s1", hook("done", turn_id="p1"))
    engine.mark_seen("t1")
    assert engine.apply_event("s1", hook("done", turn_id="bash-2")) == []
    assert reg.get("s1").state == "idle"


def test_a_report_without_a_turn_id_still_applies(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working", turn_id="p1", starts_turn=True))
    engine.apply_event("s1", hook("done"))
    assert reg.get("s1").state == "done"


def test_a_working_row_takes_the_turn_end_of_a_turn_it_never_saw_start(eng):
    # A daemon restarted mid-turn knows no turn: the row's own state is all it has to go on.
    engine, reg = eng
    reg.set_state("s1", "working")
    engine.apply_event("s1", hook("done", turn_id="p1"))
    assert reg.get("s1").state == "done"


def test_reset_turn_forgets_the_current_turn(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working", turn_id="p1", starts_turn=True))
    engine.reset_turn("s1")
    engine.apply_event("s1", hook("done", turn_id="p0"))
    assert reg.get("s1").state == "done"


def test_model_signal_sets_model_without_touching_state(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    assert engine.apply_metadata("s1", model="claude-opus-5") == ["s1"]
    assert reg.get("s1").model == "claude-opus-5" and reg.get("s1").state == "working"
    assert engine.apply_metadata("s1", model="claude-opus-5") == []


def test_reasoning_signal_sets_reasoning_without_touching_state(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    assert engine.apply_metadata("s1", reasoning="high") == ["s1"]
    assert reg.get("s1").reasoning == "high" and reg.get("s1").state == "working"
    assert engine.apply_metadata("s1", reasoning="high") == []


def test_claude_file_status_mapping(eng):
    engine, reg = eng
    assert engine.apply_claude_file_status("s1", "idle", FRESH) == []          # idle at start: nothing
    engine.apply_claude_file_status("s1", "thinking", FRESH)
    assert reg.get("s1").state == "working"
    engine.apply_claude_file_status("s1", "waiting", FRESH)
    assert reg.get("s1").state == "needsInput"
    engine.apply_claude_file_status("s1", "busy", FRESH)
    engine.apply_claude_file_status("s1", "idle", FRESH)
    assert reg.get("s1").state == "done"


@pytest.mark.parametrize("start_state,file_status,expected", [
    ("needsInput", "busy", "working"),
    ("needsInput", "thinking", "working"),
    ("needsInput", "running", "working"),
    ("needsInput", "waiting", "needsInput"),
    ("needsInput", "idle", "done"),
    ("working", "idle", "done"),
])
def test_claude_file_status_tracks_resume_after_input(eng, start_state, file_status, expected):
    engine, reg = eng
    reg.set_state("s1", start_state)
    engine.apply_claude_file_status("s1", file_status, FRESH)
    assert reg.get("s1").state == expected


def test_codex_title_spinner(eng):
    engine, reg = eng
    engine.apply_codex_title("s2", "⠋ acme-web")
    assert reg.get("s2").state == "working"
    engine.apply_codex_title("s2", "acme-web")
    assert reg.get("s2").state == "done"
    assert engine.apply_codex_title("s2", "acme-web") == []


def test_codex_title_without_spinner_waits_for_background_subagent(eng):
    engine, reg = eng
    engine.apply_codex_title("s2", "⠋ acme-web")
    engine.apply_event("s2", hook("subagentStart", "child-1"))
    engine.apply_event("s2", hook("subagentStart", "child-2"))
    engine.apply_codex_title("s2", "acme-web")
    assert reg.get("s2").state == "working"
    engine.apply_event("s2", hook("subagentStop", "child-1"))
    assert reg.get("s2").state == "working"
    engine.apply_event("s2", hook("subagentStop", "child-2"))
    assert reg.get("s2").state == "done"


def test_claude_idle_file_waits_for_background_subagent(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    engine.apply_event("s1", hook("subagentStart", "child-1"))
    engine.apply_claude_file_status("s1", "idle", FRESH)
    assert reg.get("s1").state == "working"
    engine.apply_event("s1", hook("subagentStop", "child-1"))
    assert reg.get("s1").state == "done"


def test_a_new_prompt_is_not_completed_by_the_previous_turns_deferred_done(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    engine.apply_event("s1", hook("subagentStart", "child-1"))
    engine.apply_event("s1", hook("done"))  # deferred: the child is still running
    engine.apply_event("s1", hook("working"))  # the next prompt, before the child reports back
    engine.apply_event("s1", hook("subagentStop", "child-1"))
    assert reg.get("s1").state == "working"


def test_session_start_forgets_a_subagent_whose_stop_was_lost(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    engine.apply_event("s1", hook("subagentStart", "lost"))
    engine.apply_event("s1", hook("sessionStart"))
    engine.apply_claude_file_status("s1", "idle", FRESH)
    assert reg.get("s1").state == "done"


def test_a_replaced_process_forgets_the_previous_turns_subagents(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    engine.apply_event("s1", hook("subagentStart", "lost"))
    engine.apply_event("s1", hook("done"))
    engine.reset_turn("s1")
    engine.apply_event("s1", hook("working"))
    engine.apply_claude_file_status("s1", "idle", FRESH)
    assert reg.get("s1").state == "done"
    engine.apply_event("s1", hook("subagentStop", "lost"))
    assert reg.get("s1").state == "done"


@pytest.mark.parametrize("start_state", ["working", "needsInput", "done"])
def test_an_unknown_claude_file_status_is_ignored(eng, start_state):
    engine, reg = eng
    reg.set_state("s1", start_state)
    assert engine.apply_claude_file_status("s1", "compacting", FRESH) == []
    assert reg.get("s1").state == start_state


def test_needs_input_wins_over_background_subagent_completion(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    engine.apply_event("s1", hook("subagentStart", "child-1"))
    engine.apply_event("s1", hook("needsInput"))
    engine.apply_event("s1", hook("done"))
    engine.apply_event("s1", hook("subagentStop", "child-1"))
    assert reg.get("s1").state == "needsInput"


def test_claude_idle_file_does_not_hide_needs_input_while_child_runs(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    engine.apply_event("s1", hook("subagentStart", "child-1"))
    engine.apply_event("s1", hook("needsInput"))
    engine.apply_claude_file_status("s1", "idle", FRESH)
    assert reg.get("s1").state == "needsInput"


def test_codex_spinner_restores_working_after_input(eng):
    engine, reg = eng
    engine.apply_event("s2", hook("needsInput"))
    engine.apply_codex_title("s2", "⠋ acme-web")
    assert reg.get("s2").state == "working"


def test_codex_title_without_spinner_keeps_needs_input(eng):
    engine, reg = eng
    engine.apply_event("s2", hook("needsInput"))
    engine.apply_codex_title("s2", "acme-web")
    assert reg.get("s2").state == "needsInput"


def test_mark_seen_by_sessions(eng):
    """A terminal's tabs are seen by their session ids: only those, never the task's."""
    engine, reg = eng
    engine.apply_event("s1", hook("done"))
    engine.apply_event("s2", hook("done"))
    assert engine.mark_seen_sessions(["s2", "nope"]) == ["s2"]
    assert reg.get("s2").state == "idle" and reg.get("s1").state == "done"


def test_mark_seen_and_agent_exit(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("done"))
    assert engine.mark_seen("t1") == ["s1"] and reg.get("s1").state == "idle"
    engine.apply_event("s2", hook("needsInput"))
    assert engine.agent_exited("s2") == ["s2"] and reg.get("s2").state == "idle"


def test_unknown_session_is_ignored(eng):
    engine, _ = eng
    assert engine.apply_event("nope", hook("working")) == []


def test_context_signal_stays_with_its_provider_without_touching_state(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    assert engine.apply_metadata("s1", context=42) == ["s1"]
    assert reg.get("s1").context_percent == 42 and reg.get("s1").state == "working"
    assert reg.get("s2").context_percent is None and reg.get("s2").state == "idle"
    assert engine.apply_metadata("s1", context=42) == []


def test_context_signal_replaces_the_tasks_value_when_a_tab_rereports_the_same_number():
    reg = SessionRegistry()
    reg.apply_snapshot([
        RawSession("a", "w1", 0, "claude", 1, "", "/x", {"shellforge_task": "t1"}),
        RawSession("b", "w1", 1, "claude", 2, "", "/x", {}),
    ])
    reg.set_context("a", 42)
    reg.set_context("b", 18)
    engine = StatusEngine(reg, Clock())

    assert engine.apply_metadata("b", context=18) == ["a"]
    assert [session.context_percent for session in reg.for_task("t1")] == [18, 18]
    assert engine.apply_metadata("b", context=18) == []


def test_tokens_stay_on_their_own_tab():
    reg = SessionRegistry()
    reg.apply_snapshot([
        RawSession("a", "w1", 0, "claude", 1, "", "/x", {"shellforge_task": "t1"}),
        RawSession("b", "w1", 1, "claude", 2, "", "/x", {"shellforge_task": "t1"}),
    ])
    engine = StatusEngine(reg, Clock())

    assert engine.apply_metadata("a", tokens=TokenTally(10, 4, 2)) == ["a"]
    assert reg.get("a").tokens == TokenTally(10, 4, 2) and reg.get("b").tokens is None
    assert engine.apply_metadata("a", tokens=TokenTally(10, 4, 2)) == []


def test_a_new_transcript_starts_the_tally_over(eng):
    engine, reg = eng
    engine.apply_metadata("s1", transcript="/t/first.jsonl", tokens=TokenTally(10, 4, 2))
    assert engine.apply_metadata("s1", transcript="/t/first.jsonl") == []

    assert engine.apply_metadata("s1", transcript="/t/second.jsonl") == ["s1"]
    assert reg.get("s1").tokens is None and reg.get("s1").transcript == "/t/second.jsonl"


@pytest.mark.parametrize("before", ["idle", "done", "working"])
def test_a_closed_prompt_restores_the_state_it_interrupted(eng, before):
    engine, reg = eng
    reg.set_state("s1", before)
    assert engine.apply_event("s1", hook("promptStart")) == ["s1"]
    assert reg.get("s1").state == "needsInput"
    engine.apply_event("s1", hook("promptEnd"))
    assert reg.get("s1").state == before


def test_a_closed_prompt_keeps_the_completion_a_background_child_holds(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    engine.apply_event("s1", hook("subagentStart", "child-1"))
    engine.apply_event("s1", hook("done"))  # deferred: the child is still running
    engine.apply_event("s1", hook("promptStart"))
    engine.apply_event("s1", hook("promptEnd"))
    assert reg.get("s1").state == "working"
    engine.apply_event("s1", hook("subagentStop", "child-1"))
    assert reg.get("s1").state == "done"


def test_a_prompt_opened_over_another_restores_the_state_before_the_first(eng):
    engine, reg = eng
    reg.set_state("s1", "done")
    engine.apply_event("s1", hook("promptStart"))
    engine.apply_event("s1", hook("promptStart"))
    engine.apply_event("s1", hook("promptEnd"))
    engine.apply_event("s1", hook("promptEnd"))
    assert reg.get("s1").state == "done"


def test_a_nested_prompt_closing_leaves_the_outer_one_visible(eng):
    engine, reg = eng
    reg.set_state("s1", "working")
    engine.apply_event("s1", hook("promptStart"))
    engine.apply_event("s1", hook("promptStart"))
    assert engine.apply_event("s1", hook("promptEnd")) == []
    assert reg.get("s1").state == "needsInput", "the first prompt is still open"
    engine.apply_event("s1", hook("promptEnd"))
    assert reg.get("s1").state == "working"


def test_a_completion_deferred_during_a_prompt_ends_the_turn_the_prompt_restores(eng):
    """The done a child defers is not a hook that says what the turn is doing now: the turn is
    still working, so the prompt keeps what it interrupted and the last child completes it."""
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    engine.apply_event("s1", hook("subagentStart", "child-1"))
    engine.apply_event("s1", hook("promptStart"))
    engine.apply_event("s1", hook("done"))  # deferred: the child is still running
    engine.apply_event("s1", hook("subagentStop", "child-1"))
    assert reg.get("s1").state == "needsInput", "the open prompt stays visible"
    engine.apply_event("s1", hook("promptEnd"))
    assert reg.get("s1").state == "done"


def test_a_prompt_closing_before_the_deferred_completion_lands_restores_working(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    engine.apply_event("s1", hook("subagentStart", "child-1"))
    engine.apply_event("s1", hook("promptStart"))
    engine.apply_event("s1", hook("done"))  # deferred: the child is still running
    engine.apply_event("s1", hook("promptEnd"))
    assert reg.get("s1").state == "working"
    engine.apply_event("s1", hook("subagentStop", "child-1"))
    assert reg.get("s1").state == "done"


def test_a_prompt_end_without_its_start_changes_nothing(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("needsInput"))
    assert engine.apply_event("s1", hook("promptEnd")) == []
    assert reg.get("s1").state == "needsInput"


def test_a_hook_during_a_prompt_supersedes_the_state_it_interrupted(eng):
    engine, reg = eng
    reg.set_state("s1", "working")
    engine.apply_event("s1", hook("promptStart"))
    engine.apply_event("s1", hook("done"))
    assert engine.apply_event("s1", hook("promptEnd")) == []
    assert reg.get("s1").state == "done"


@pytest.mark.parametrize("kind,file_status", [
    ("needsInput", "busy"),     # a permission prompt, over the file of the turn it interrupted
    ("working", "idle"),        # a new prompt, over the file of the turn before
    ("done", "busy"),           # the end of the turn, before Claude rewrites its file
])
def test_a_session_file_older_than_the_last_hook_does_not_override_it(eng, clock, kind, file_status):
    engine, reg = eng
    engine.apply_event("s1", hook(kind))
    assert engine.apply_claude_file_status("s1", file_status, clock.now - 0.5) == []
    assert engine.apply_claude_file_status("s1", file_status, clock.now) == []
    assert reg.get("s1").state == kind


def test_a_session_file_written_after_the_last_hook_still_moves_the_row(eng, clock):
    engine, reg = eng
    engine.apply_event("s1", hook("needsInput"))
    # The prompt was answered: Claude marks its file busy again and no hook says so.
    assert engine.apply_claude_file_status("s1", "busy", clock.now + 0.5) == ["s1"]
    assert reg.get("s1").state == "working"


def test_a_codex_prompt_is_not_ended_before_its_spinner_first_appears(eng):
    engine, reg = eng
    engine.apply_event("s2", hook("working"))
    assert engine.apply_codex_title("s2", "acme-web") == []
    assert reg.get("s2").state == "working"
    engine.apply_codex_title("s2", "⠋ acme-web")
    engine.apply_codex_title("s2", "acme-web")
    assert reg.get("s2").state == "done"


def test_the_previous_turns_spinner_does_not_end_the_next_prompt(eng):
    engine, reg = eng
    engine.apply_codex_title("s2", "⠋ acme-web")
    engine.apply_codex_title("s2", "acme-web")
    engine.apply_event("s2", hook("working"))
    engine.apply_codex_title("s2", "acme-web")
    assert reg.get("s2").state == "working"


def test_a_spinner_after_an_answered_prompt_lets_its_absence_end_the_turn(eng):
    engine, reg = eng
    engine.apply_event("s2", hook("working"))
    engine.apply_event("s2", hook("needsInput"))
    engine.apply_codex_title("s2", "⠋ acme-web")
    engine.apply_codex_title("s2", "acme-web")
    assert reg.get("s2").state == "done"


def test_a_child_finishing_during_a_prompt_completes_the_turn_the_prompt_restores(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("working"))
    engine.apply_event("s1", hook("subagentStart", "child-1"))
    engine.apply_event("s1", hook("done"))  # deferred: the child is still running
    engine.apply_event("s1", hook("promptStart"))
    engine.apply_event("s1", hook("subagentStop", "child-1"))
    assert reg.get("s1").state == "needsInput", "the open prompt stays visible"
    engine.apply_event("s1", hook("promptEnd"))
    assert reg.get("s1").state == "done"


@pytest.mark.parametrize("before", ["idle", "done"])
def test_a_child_starting_during_a_prompt_leaves_the_turn_working_once_it_closes(eng, before):
    engine, reg = eng
    reg.set_state("s1", before)
    engine.apply_event("s1", hook("promptStart"))
    engine.apply_event("s1", hook("subagentStart", "child-1"))
    assert reg.get("s1").state == "needsInput", "the open prompt stays visible"
    engine.apply_event("s1", hook("promptEnd"))
    assert reg.get("s1").state == "working"


def test_a_done_seen_during_a_prompt_is_not_restored_unseen(eng):
    engine, reg = eng
    engine.apply_event("s1", hook("done"))
    engine.apply_event("s1", hook("promptStart"))
    assert engine.mark_seen("t1") == [], "the prompt is still what the row shows"
    engine.apply_event("s1", hook("promptEnd"))
    assert reg.get("s1").state == "idle"


GONE = {"/gone"}
PRESENT: set[str] = set()


def _grok_engine(clock, agent="grok", state_cwd="/gone"):
    """A task tab running `agent`, whose orphan window runs on `clock`. The wall clock stands still:
    the window must not depend on it."""
    reg = SessionRegistry()
    reg.apply_snapshot([RawSession("g1", "w1", 0, agent, 7, "", "/shell", {"shellforge_task": "t1"})])
    eng = StatusEngine(reg, lambda: 5000.0, monotonic=clock)
    eng.apply_metadata("g1", cwd=state_cwd)
    return eng, reg


def test_orphaned_grok_session_settles_after_ten_seconds(clock):
    eng, reg = _grok_engine(clock)
    eng.apply_event("g1", hook("working"))
    assert eng.orphan_paths() == {"/gone"}
    assert eng.settle_orphans(GONE) == []          # first seen missing
    clock.now += 9.9
    assert eng.settle_orphans(GONE) == []
    clock.now += 0.1
    assert eng.settle_orphans(GONE) == ["g1"]
    assert reg.get("g1").state == "done"


def test_a_settled_orphan_still_tells_a_late_report_from_its_own_turn(clock):
    # The settle forgets what the turn waited on, not which turn it was: an earlier turn's report,
    # delivered late, stays ignored.
    eng, reg = _grok_engine(clock)
    eng.apply_event("g1", hook("working", turn_id="p1", starts_turn=True))
    eng.apply_event("g1", hook("subagentStart", "child"))
    eng.settle_orphans(GONE)
    clock.now += 10
    assert eng.settle_orphans(GONE) == ["g1"]
    turn = eng.turn("g1")
    assert turn is not None and turn.turn_id == "p1" and not turn.children and turn.cwd_missing_since is None
    assert eng.apply_event("g1", hook("needsInput", turn_id="p0")) == []
    assert reg.get("g1").state == "done"


def test_the_window_ignores_the_wall_clock(clock):
    # An NTP step forward must not end a turn early.
    reg = SessionRegistry()
    reg.apply_snapshot([RawSession("g1", "w1", 0, "grok", 7, "", "/gone", {"shellforge_task": "t1"})])
    wall = Clock()
    eng = StatusEngine(reg, wall, monotonic=clock)
    eng.apply_event("g1", hook("working"))
    eng.settle_orphans(GONE)
    wall.now += 3600
    assert eng.settle_orphans(GONE) == []


def test_needs_input_settles_too(clock):
    eng, reg = _grok_engine(clock)
    eng.apply_event("g1", hook("needsInput"))
    eng.settle_orphans(GONE)
    clock.now += 10
    assert eng.settle_orphans(GONE) == ["g1"]


def test_a_real_stop_inside_the_window_wins(clock):
    eng, reg = _grok_engine(clock)
    eng.apply_event("g1", hook("working"))
    eng.settle_orphans(GONE)
    eng.apply_event("g1", hook("done"))
    eng.mark_seen("t1")                            # the user looked: idle
    clock.now += 10
    assert eng.orphan_paths() == set()
    assert eng.settle_orphans(GONE) == []
    assert reg.get("g1").state == "idle"


@pytest.mark.parametrize("kind", ["working", "needsInput"])
def test_a_hook_inside_the_window_restarts_it(clock, kind):
    # A hook that arrives at all was spawned in a directory that exists, whatever the check said.
    eng, reg = _grok_engine(clock)
    eng.apply_event("g1", hook("working"))
    eng.settle_orphans(GONE)
    clock.now += 9
    eng.apply_event("g1", hook(kind))
    assert eng.settle_orphans(GONE) == []          # missing again, from now
    clock.now += 9.9
    assert eng.settle_orphans(GONE) == []
    clock.now += 0.1
    assert eng.settle_orphans(GONE) == ["g1"]


def test_a_reappearing_directory_cancels(clock):
    eng, reg = _grok_engine(clock)
    eng.apply_event("g1", hook("working"))
    eng.settle_orphans(GONE)
    clock.now += 5
    assert eng.settle_orphans(PRESENT) == []
    clock.now += 6                                 # 11 s since first seen, 6 s since it came back
    assert eng.settle_orphans(GONE) == []
    clock.now += 10
    assert eng.settle_orphans(GONE) == ["g1"]


def test_forced_past_a_deferred_subagent_completion(clock):
    eng, reg = _grok_engine(clock)
    eng.apply_event("g1", hook("working"))
    eng.subagent_started("g1", "child")
    eng.apply_event("g1", hook("done"))                  # deferred: a child is still running
    assert reg.get("g1").state == "working"
    eng.settle_orphans(GONE)
    clock.now += 10
    assert eng.settle_orphans(GONE) == ["g1"]
    assert reg.get("g1").state == "done"


@pytest.mark.parametrize("agent", ["claude", "codex", "pi"])
def test_listed_harnesses_are_never_settled(clock, agent):
    # Their end-of-turn signal survives a removed cwd; a guess would only be wrong.
    eng, reg = _grok_engine(clock, agent=agent)
    eng.apply_event("g1", hook("working"))
    assert eng.orphan_paths() == set(), "nothing to check"
    eng.settle_orphans(GONE)
    clock.now += 60
    assert eng.settle_orphans(GONE) == []
    assert reg.get("g1").state == "working"


@pytest.mark.parametrize("state", ["idle", "done"])
def test_settled_states_are_untouched(clock, state):
    eng, reg = _grok_engine(clock)
    reg.set_state("g1", state)
    assert eng.orphan_paths() == set()
    eng.settle_orphans(GONE)
    clock.now += 60
    assert eng.settle_orphans(GONE) == []


def test_shell_cwd_is_the_fallback_path(clock):
    eng, reg = _grok_engine(clock, state_cwd=None)
    eng.apply_event("g1", hook("working"))
    assert eng.orphan_paths() == {"/shell"}


def test_only_a_removed_directory_is_missing(tmp_path):
    (tmp_path / "file").write_text("")
    assert not path_is_missing(str(tmp_path))
    assert path_is_missing(str(tmp_path / "gone"))
    assert path_is_missing(str(tmp_path / "file" / "sub")), "ENOTDIR: a component is no longer a directory"
    # A NUL can arrive in a cwd another process posted; os.stat raises ValueError for it.
    assert not path_is_missing("/tmp/\0x")


@pytest.mark.parametrize("error", [PermissionError(13, "denied"), OSError(5, "I/O error"), OSError(70, "stale NFS handle"),
                                   TimeoutError(60, "timed out")])
def test_a_directory_that_cannot_be_read_is_not_missing(monkeypatch, error):
    # EACCES on a TCC-protected folder, EIO, a stale or unreachable network mount: nothing proves it is gone.
    def fail(path):
        raise error
    monkeypatch.setattr(status.os, "stat", fail)
    assert not path_is_missing("/Volumes/share/wt")


# -- a Claude subagent that died without SubagentStop -------------------------------------------

TRANSCRIPT = "/p/sess/subagents/agent-c1.jsonl"


def _claude_engine(monotonic):
    """A Claude tab whose turn ended while child `c1` runs in the background: its Stop is deferred.
    The child started at wall-clock 100; its transcript quiet window runs on `monotonic`."""
    reg = SessionRegistry()
    reg.apply_snapshot([RawSession("s1", "w1", 0, "claude", 1, "", "/x", {"shellforge_task": "t1"})])
    wall = Clock()
    eng = StatusEngine(reg, wall, monotonic=monotonic)
    eng.apply_event("s1", hook("working"))
    eng.apply_event("s1", hook("subagentStart", "c1", subagent_transcript=TRANSCRIPT))
    eng.apply_event("s1", hook("done"))
    assert reg.get("s1").state == "working"
    return eng, reg, wall


def _tail(ended=False, written_at=200.0, size=10):
    return TranscriptTail(stamp=(int(written_at * 1e9), size), written_at=written_at, ended=ended)


def test_only_a_deferred_turns_transcripts_are_read(clock):
    eng, reg, _ = _claude_engine(clock)
    assert eng.subagent_transcripts() == {TRANSCRIPT}
    eng.apply_event("s1", hook("working"))               # a new turn: nothing deferred any more
    assert eng.subagent_transcripts() == set()


def test_a_child_whose_transcript_ends_interrupted_releases_the_deferred_done(clock):
    eng, reg, _ = _claude_engine(clock)
    assert eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True)}) == ["s1"]
    assert reg.get("s1").state == "done"
    assert eng.subagent_transcripts() == set()


def test_a_quiet_child_past_the_window_releases_it(clock):
    eng, reg, _ = _claude_engine(clock)
    assert eng.release_dead_subagents({TRANSCRIPT: _tail()}) == []     # first seen: the window starts
    clock.now += status.SUBAGENT_QUIET_SECONDS - 1
    assert eng.release_dead_subagents({TRANSCRIPT: _tail()}) == []
    clock.now += 1
    assert eng.release_dead_subagents({TRANSCRIPT: _tail()}) == ["s1"]
    assert reg.get("s1").state == "done"


def test_the_quiet_window_ignores_the_wall_clock(clock):
    # A laptop that slept, or an NTP step, must not make a live child look quiet.
    eng, reg, wall = _claude_engine(clock)
    eng.release_dead_subagents({TRANSCRIPT: _tail()})
    wall.now += 10 * status.SUBAGENT_QUIET_SECONDS
    assert eng.release_dead_subagents({TRANSCRIPT: _tail()}) == []


def test_a_child_still_being_written_keeps_the_row_working(clock):
    eng, reg, _ = _claude_engine(clock)
    for size in range(1, 5):
        assert eng.release_dead_subagents({TRANSCRIPT: _tail(size=size)}) == []
        clock.now += status.SUBAGENT_QUIET_SECONDS - 1
    assert reg.get("s1").state == "working"


def test_a_missing_transcript_keeps_it_working(clock):
    eng, reg, _ = _claude_engine(clock)
    assert eng.release_dead_subagents({}) == []
    clock.now += 10 * status.SUBAGENT_QUIET_SECONDS
    assert eng.release_dead_subagents({}) == []
    assert reg.get("s1").state == "working"


def test_a_late_real_subagent_stop_after_the_backstop_is_harmless(clock):
    eng, reg, _ = _claude_engine(clock)
    eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True)})
    eng.mark_seen("t1")
    assert eng.apply_event("s1", hook("subagentStop", "c1")) == []
    assert reg.get("s1").state == "idle"


def test_a_resent_subagent_start_re_adds_the_child(clock):
    # A stalled child resumed later fires SubagentStart again under the same agent_id.
    eng, reg, wall = _claude_engine(clock)
    eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True)})
    wall.now = 300.0
    eng.apply_event("s1", hook("working"))
    eng.apply_event("s1", hook("subagentStart", "c1", subagent_transcript=TRANSCRIPT))
    eng.apply_event("s1", hook("done"))
    assert reg.get("s1").state == "working"
    # Its transcript still ends in the interruption from before the resume: that verdict is stale.
    assert eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True, written_at=200.0)}) == []
    assert eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True, written_at=301.0, size=20)}) == ["s1"]


def test_a_dead_child_waits_for_its_live_siblings(clock):
    eng, reg, _ = _claude_engine(clock)
    other = "/p/sess/subagents/agent-c2.jsonl"
    eng.apply_event("s1", hook("subagentStart", "c2", subagent_transcript=other))
    assert eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True), other: _tail()}) == []
    assert eng.subagent_transcripts() == {other}
    assert eng.apply_event("s1", hook("subagentStop", "c2")) == ["s1"]


def test_a_child_without_a_transcript_is_never_released(clock):
    # Codex and PI children, and a Claude hook without transcript_path: nothing to read.
    eng, reg, _ = _claude_engine(clock)
    eng.apply_event("s1", hook("subagentStart", "c2"))
    eng.release_dead_subagents({TRANSCRIPT: _tail(ended=True)})
    assert reg.get("s1").state == "working"


def test_a_stop_that_no_longer_lists_a_child_drops_it(clock):
    # Claude woke the parent to say the child failed; that turn's Stop lists no such task.
    eng, reg, _ = _claude_engine(clock)
    eng.apply_event("s1", hook("working"))
    assert eng.apply_event("s1", hook("done", running_subagents=frozenset())) == ["s1"]
    assert reg.get("s1").state == "done"
    assert eng.apply_event("s1", hook("subagentStop", "c1")) == []


def test_a_stop_that_drops_the_last_child_lands_the_deferred_done(clock):
    # No UserPromptSubmit came between: the earlier deferred done is the one that lands.
    eng, reg, _ = _claude_engine(clock)
    assert eng.apply_event("s1", hook("done", running_subagents=frozenset({"b1"}))) == ["s1"]
    assert reg.get("s1").state == "done"


def test_a_stop_that_lists_the_child_keeps_the_turn_working(clock):
    eng, reg, _ = _claude_engine(clock)
    eng.apply_event("s1", hook("working"))
    assert eng.apply_event("s1", hook("done", running_subagents=frozenset({"c1"}))) == []
    assert reg.get("s1").state == "working"
    assert eng.subagent_transcripts() == {TRANSCRIPT}


def test_a_stop_drops_only_the_children_it_does_not_list(clock):
    eng, reg, _ = _claude_engine(clock)
    eng.apply_event("s1", hook("working"))
    eng.apply_event("s1", hook("subagentStart", "c2", subagent_transcript="/p/sess/subagents/agent-c2.jsonl"))
    eng.apply_event("s1", hook("done", running_subagents=frozenset({"c2"})))
    assert reg.get("s1").state == "working"
    assert eng.subagent_transcripts() == {"/p/sess/subagents/agent-c2.jsonl"}
    assert eng.apply_event("s1", hook("subagentStop", "c2")) == ["s1"]


def test_a_stop_without_a_list_proves_nothing(clock):
    eng, reg, _ = _claude_engine(clock)
    eng.apply_event("s1", hook("working"))
    eng.apply_event("s1", hook("done", running_subagents=None))
    assert reg.get("s1").state == "working"


def test_a_stop_after_needs_input_ends_the_turn_as_without_children(clock):
    eng, reg, _ = _claude_engine(clock)
    eng.apply_event("s1", hook("needsInput"))
    eng.apply_event("s1", hook("done", running_subagents=frozenset()))
    assert reg.get("s1").state == "done", "a Stop says what the turn is doing now, as without children"
