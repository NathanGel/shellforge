import pytest
from shellforged.models import TokenTally, UsageWindow
from shellforged.hook_events import (
    StatusLine, parse_claude_hook, parse_codex_hook, parse_claude_statusline, parse_grok_hook, parse_grok_statusline,
    parse_pi_hook,
)

BASE = {"session_id": "abc", "cwd": "/repo/.worktrees/x", "transcript_path": "/t.jsonl", "permission_mode": "default"}
PI_BASE = {"session_id": "pi-session", "cwd": "/repo/.worktrees/x",
           "model": "openai-codex/gpt-5.6-sol", "reasoning": "high", "context_percent": 42.6,
           "_aiterm_iterm_session_id": "w0t0p0:pi-tab"}


@pytest.mark.parametrize("payload,kind,model", [
    ({**BASE, "hook_event_name": "SessionStart", "source": "startup", "model": "claude-opus-5"}, "sessionStart", "claude-opus-5"),
    ({**BASE, "hook_event_name": "SessionStart", "source": "clear"}, "sessionStart", None),
    # A compaction reports SessionStart mid-turn: metadata only, not a new conversation.
    ({**BASE, "hook_event_name": "SessionStart", "source": "compact", "model": "claude-opus-5"}, None, "claude-opus-5"),
    ({**BASE, "hook_event_name": "PostModelSwitch", "from_model": "a", "to_model": "claude-fable-5-1"}, None, "claude-fable-5-1"),
    ({**BASE, "hook_event_name": "UserPromptSubmit", "user_prompt": "hi"}, "working", None),
    ({**BASE, "hook_event_name": "Stop", "stop_reason": "end_turn"}, "done", None),
    ({**BASE, "hook_event_name": "PermissionRequest", "tool_name": "Bash"}, "needsInput", None),
    ({**BASE, "hook_event_name": "Notification", "notification_type": "permission_prompt"}, "needsInput", None),
    ({**BASE, "hook_event_name": "Notification", "notification_type": "agent_needs_input"}, "needsInput", None),
    ({**BASE, "hook_event_name": "Notification", "notification_type": "agent_completed"}, "done", None),
])
def test_claude_hook_mapping(payload, kind, model):
    ev = parse_claude_hook(payload)
    assert ev.agent == "claude" and ev.kind == kind and ev.model == model
    assert ev.session_id == "abc" and ev.cwd == "/repo/.worktrees/x"


def test_claude_idle_prompt_and_unknown_events_are_ignored():
    assert parse_claude_hook({**BASE, "hook_event_name": "Notification", "notification_type": "idle_prompt"}) is None
    assert parse_claude_hook({**BASE, "hook_event_name": "PreToolUse"}) is None
    assert parse_claude_hook({}) is None


def test_codex_hook_mapping():
    p = {"cwd": "/w", "hook_event_name": "SessionStart", "model": "gpt-5.6", "permission_mode": "default", "session_id": "th1",
         "source": "startup", "transcript_path": None}
    ev = parse_codex_hook(p)
    assert (ev.agent, ev.kind, ev.model, ev.session_id, ev.cwd) == ("codex", "sessionStart", "gpt-5.6", "th1", "/w")
    assert parse_codex_hook({**p, "hook_event_name": "Stop"}).kind == "done"
    assert parse_codex_hook({**p, "hook_event_name": "PermissionRequest"}).kind == "needsInput"
    assert parse_codex_hook({**p, "hook_event_name": "UserPromptSubmit"}).kind == "working"
    assert parse_codex_hook({**p, "hook_event_name": "PreToolUse"}) is None


@pytest.mark.parametrize("name,kind", [
    ("session_start", None),
    ("agent_start", "working"),
    ("ui_prompt_start", "promptStart"),
    ("ui_prompt_end", "promptEnd"),
    ("agent_settled", "done"),
    ("model_select", None),
    ("thinking_level_select", None),
    ("turn_end", None),
    ("tokens", None),
])
def test_pi_hook_mapping(name, kind):
    event = parse_pi_hook({**PI_BASE, "hook_event_name": name})
    assert event.agent == "pi" and event.kind == kind
    assert event.model == "openai-codex/gpt-5.6-sol"
    assert event.reasoning == "high" and event.context_percent == 43
    assert event.iterm_session_id == "w0t0p0:pi-tab"


@pytest.mark.parametrize("reason,kind", [
    ("startup", "sessionStart"), ("new", "sessionStart"), ("resume", "sessionStart"), ("fork", "sessionStart"),
    # A reload re-runs the extensions inside the running conversation, like Claude's compaction.
    ("reload", None),
    # An extension from before `reason` was forwarded, or a reason PI adds later: metadata only.
    (None, None), ("teleport", None), (["startup"], None),
])
def test_pi_session_start_begins_a_conversation_unless_it_is_a_reload(reason, kind):
    event = parse_pi_hook({**PI_BASE, "hook_event_name": "session_start", "reason": reason})
    assert event.kind == kind and event.model == "openai-codex/gpt-5.6-sol"


@pytest.mark.parametrize("raw,expected", [
    (True, None), ("43", None), (None, None), (-2, 0), (101, 100), (42.5, 42),
    (float("inf"), None), (float("-inf"), None), (float("nan"), None),
])
def test_pi_context_percent_rejects_non_numbers_and_clamps_numbers(raw, expected):
    assert parse_pi_hook({**PI_BASE, "hook_event_name": "session_start", "context_percent": raw}).context_percent == expected


def test_pi_hook_rejects_unknown_events_and_sanitizes_string_metadata():
    assert parse_pi_hook({**PI_BASE, "hook_event_name": "unknown"}) is None
    event = parse_pi_hook({**PI_BASE, "hook_event_name": "session_start",
                           "session_id": 7, "cwd": False, "model": ["bad"], "reasoning": 3})
    assert event.session_id is None and event.cwd is None
    assert event.model is None and event.reasoning is None


@pytest.mark.parametrize("parser,vendor", [(parse_claude_hook, "claude"), (parse_codex_hook, "codex")])
def test_subagent_lifecycle_hooks_identify_the_parent_session_and_child(parser, vendor):
    start = parser({**BASE, "hook_event_name": "SubagentStart", "agent_id": "child-1", "agent_type": "explorer"})
    stop = parser({**BASE, "hook_event_name": "SubagentStop", "agent_id": "child-1", "agent_type": "explorer"})
    assert (start.agent, start.kind, start.session_id, start.subagent_id) == (vendor, "subagentStart", "abc", "child-1")
    assert (stop.agent, stop.kind, stop.session_id, stop.subagent_id) == (vendor, "subagentStop", "abc", "child-1")


@pytest.mark.parametrize("payload,expected", [
    # SubagentStart carries only the session's transcript: the child's sits beside it, in <session>/subagents/.
    ({"transcript_path": "/p/sess.jsonl"}, "/p/sess/subagents/agent-child-1.jsonl"),
    # A path the hook gives for the child itself wins.
    ({"transcript_path": "/p/sess.jsonl", "agent_transcript_path": "/p/sess/subagents/wf/agent-child-1.jsonl"},
     "/p/sess/subagents/wf/agent-child-1.jsonl"),
    ({}, None),
    ({"transcript_path": "/p/sess.txt"}, None),
    ({"transcript_path": ["/p/sess.jsonl"]}, None),
])
def test_a_claude_subagent_start_names_the_childs_transcript(payload, expected):
    start = parse_claude_hook({"session_id": "abc", "cwd": "/x", "hook_event_name": "SubagentStart", "agent_id": "child-1", **payload})
    assert start.subagent_transcript == expected


def test_only_a_claude_subagent_start_names_a_transcript():
    assert parse_codex_hook({**BASE, "hook_event_name": "SubagentStart", "agent_id": "child-1"}).subagent_transcript is None
    assert parse_claude_hook({**BASE, "hook_event_name": "SubagentStop", "agent_id": "child-1"}).subagent_transcript is None


def _task(id_, type_, status="running"):
    return {"id": id_, "type": type_, "status": status, "description": "…"}


@pytest.mark.parametrize("tasks,expected", [
    # Claude Code lists in-flight background work only; a subagent's task id is its agent_id.
    ([], frozenset()),
    ([_task("a1", "subagent"), _task("b1", "shell"), _task("m1", "monitor"), _task("t1", "MCP task")], frozenset({"a1"})),
    ([_task("a1", "subagent", "pending")], frozenset({"a1"})),
    ([_task("a1", "subagent", "completed")], frozenset()),
    # A teammate's task id is not the agent_id its hooks carry, and a workflow's agents sit behind the
    # workflow's own id: with either in flight, no child can be proven gone.
    ([_task("a1", "subagent"), _task("t-9", "teammate")], None),
    ([_task("w1", "workflow")], None),
    ([_task("x1", "something new")], None),
    ([_task(7, "subagent")], None),
    (["a1"], None),
    # An older Claude Code, or a registry it could not reach, sends no list: nothing is known.
    (None, None),
    ("a1", None),
])
def test_a_claude_stop_lists_the_subagents_still_running(tasks, expected):
    payload = {**BASE, "hook_event_name": "Stop"} if tasks is None else {**BASE, "hook_event_name": "Stop", "background_tasks": tasks}
    assert parse_claude_hook(payload).running_subagents == expected


def test_only_a_claude_stop_lists_running_subagents():
    tasks = {"background_tasks": []}
    assert parse_claude_hook({**BASE, "hook_event_name": "SubagentStop", "agent_id": "a1", **tasks}).running_subagents is None
    assert parse_claude_hook({**BASE, "hook_event_name": "UserPromptSubmit", **tasks}).running_subagents is None
    assert parse_codex_hook({**BASE, "hook_event_name": "Stop", **tasks}).running_subagents is None


def test_pi_subagent_lifecycle_identifies_the_parent_session_and_child():
    start = parse_pi_hook({**PI_BASE, "hook_event_name": "subagent_start", "agent_id": "child-1"})
    stop = parse_pi_hook({**PI_BASE, "hook_event_name": "subagent_stop", "agent_id": "child-1"})
    assert (start.agent, start.kind, start.session_id, start.subagent_id) == ("pi", "subagentStart", "pi-session", "child-1")
    assert (stop.agent, stop.kind, stop.session_id, stop.subagent_id) == ("pi", "subagentStop", "pi-session", "child-1")
    assert start.iterm_session_id == "w0t0p0:pi-tab"


@pytest.mark.parametrize("name", ["subagent_start", "subagent_stop"])
def test_pi_subagent_event_without_a_child_id_is_ignored(name):
    assert parse_pi_hook({**PI_BASE, "hook_event_name": name}) is None
    assert parse_pi_hook({**PI_BASE, "hook_event_name": name, "agent_id": 7}) is None


def _usage_and_model(payload, now):
    tick = parse_claude_statusline(payload, now)
    return tick.usage, tick.model


def test_statusline_usage_and_model():
    payload = {"session_id": "abc", "model": {"id": "claude-opus-5", "display_name": "Opus"},
               "rate_limits": {"five_hour": {"used_percentage": 23.4, "resets_at": 1738425600},
                               "seven_day": {"used_percentage": 61, "resets_at": 1738900000}}}
    usage, model = _usage_and_model(payload, now=1700000000)
    assert model == "claude-opus-5"
    assert usage.five_hour.used_percent == 23 and usage.five_hour.resets_at == 1738425600
    assert usage.seven_day.used_percent == 61 and usage.spend is None and usage.updated_at == 1700000000


def test_statusline_without_rate_limits_gives_empty_usage():
    usage, model = _usage_and_model({"model": {"id": "x"}}, now=5)
    assert usage.five_hour is None and usage.seven_day is None and model == "x"


def test_statusline_tolerates_malformed_fields():
    # Non-dict rate_limits (should treat as empty dict, no exception)
    usage, model = _usage_and_model({"rate_limits": "invalid", "model": {"id": "m"}}, now=1)
    assert usage.five_hour is None and usage.seven_day is None and model == "m"

    # Non-numeric used_percentage (should return None for that window)
    payload = {"model": {"id": "m"}, "rate_limits": {"five_hour": {"used_percentage": "not_a_number", "resets_at": 100}}}
    usage, model = _usage_and_model(payload, now=1)
    assert usage.five_hour is None and model == "m"

    # Non-dict model (should return None for model_id)
    usage, model = _usage_and_model({"model": "invalid", "rate_limits": {}}, now=1)
    assert model is None and usage.five_hour is None

    # Boolean used_percentage (must return None, not 1 or 0)
    payload = {"model": {"id": "m"}, "rate_limits": {"five_hour": {"used_percentage": True}}}
    usage, model = _usage_and_model(payload, now=1)
    assert usage.five_hour is None and model == "m"

    # Boolean resets_at (must return None, not 1 or 0)
    payload = {"model": {"id": "m"}, "rate_limits": {"seven_day": {"used_percentage": 50, "resets_at": True}}}
    usage, model = _usage_and_model(payload, now=1)
    assert usage.seven_day is not None and usage.seven_day.resets_at is None and model == "m"


def test_statusline_carries_the_session_it_describes():
    tick = parse_claude_statusline({"session_id": "abc", "cwd": "/wt", "_aiterm_iterm_session_id": "w0t0p0:t"}, now=1)
    assert (tick.session_id, tick.cwd, tick.iterm_session_id, tick.reasoning) == ("abc", "/wt", "w0t0p0:t", None)


@pytest.mark.parametrize("bad", [{"not": "a string"}, ["m"], 7, ""])
def test_statusline_fields_that_are_not_strings_are_none(bad):
    # A dict model would be stored and broadcast, and the app's `model: String?` fails to decode it;
    # a dict session id cannot key a pin.
    tick = parse_claude_statusline({"session_id": bad, "cwd": bad, "model": {"id": bad}}, now=1)
    assert (tick.session_id, tick.cwd, tick.model) == (None, None, None)


def test_hooks_ignore_non_dict_payloads():
    # parse_claude_hook with list payload
    assert parse_claude_hook([]) is None
    assert parse_claude_hook("string") is None
    assert parse_claude_hook(None) is None

    # parse_codex_hook with non-dict payloads
    assert parse_codex_hook([]) is None
    assert parse_codex_hook("x") is None
    assert parse_codex_hook(None) is None


def test_statusline_carries_the_context_window_fill():
    payload = {"session_id": "abc", "model": {"id": "claude-opus-5"},
               "context_window": {"used_percentage": 42.6}}
    assert parse_claude_statusline(payload, now=1).context_percent == 43


@pytest.mark.parametrize("cw", [
    None,                                   # absent entirely
    "invalid",                              # not a dict
    {},                                     # no used_percentage
    {"used_percentage": "78"},              # a string, not a number
    {"used_percentage": True},              # bool is an int subclass; must not read as 1
    {"used_percentage": float("inf")},      # json.loads accepts Infinity; int() would raise
    {"used_percentage": float("nan")},      # json.loads accepts NaN; round() would raise
])
def test_statusline_context_is_none_when_unusable(cw):
    payload = {"model": {"id": "m"}}
    if cw is not None:
        payload["context_window"] = cw
    assert parse_claude_statusline(payload, now=1).context_percent is None


@pytest.mark.parametrize("raw,expected", [(-5, 0), (0, 0), (100, 100), (140, 100)])
def test_statusline_context_is_clamped_to_a_percentage(raw, expected):
    payload = {"context_window": {"used_percentage": raw}}
    assert parse_claude_statusline(payload, now=1).context_percent == expected


@pytest.mark.parametrize("bad", [float("inf"), float("nan"), 10 ** 400], ids=["inf", "nan", "huge"])
def test_statusline_windows_reject_non_finite_numbers(bad):
    payload = {"rate_limits": {"five_hour": {"used_percentage": bad},
                               "seven_day": {"used_percentage": 5, "resets_at": bad}}}
    usage = parse_claude_statusline(payload, now=1).usage
    assert usage.five_hour is None
    assert usage.seven_day == UsageWindow(5, None)


@pytest.mark.parametrize("parser", [parse_claude_hook, parse_codex_hook])
def test_claude_and_codex_hooks_sanitize_string_fields(parser):
    event = parser({"hook_event_name": "SessionStart", "session_id": 7, "cwd": False, "model": ["bad"],
                    "_aiterm_iterm_session_id": {"x": 1}})
    assert event.session_id is None and event.cwd is None and event.model is None
    assert event.iterm_session_id is None
    assert parse_claude_hook({"hook_event_name": "PostModelSwitch", "to_model": 5}).model is None
    assert parser({"hook_event_name": "SubagentStart", "agent_id": ""}) is None


GROK_BASE = {"hookEventName": "stop", "sessionId": "g-1", "cwd": "/repo/.worktrees/x",
             "workspaceRoot": "/repo/.worktrees/x", "timestamp": "2026-09-28T12:00:00Z",
             "permissionMode": "default", "_aiterm_iterm_session_id": "w0t0p0:grok-tab"}


@pytest.mark.parametrize("payload,kind", [
    ({**GROK_BASE, "hook_event_name": "SessionStart", "source": "startup"}, "sessionStart"),
    ({**GROK_BASE, "hook_event_name": "SessionStart", "source": "compact"}, None),
    ({**GROK_BASE, "hook_event_name": "UserPromptSubmit", "promptId": "p1"}, "working"),
    ({**GROK_BASE, "hook_event_name": "PostToolUse", "toolName": "run_terminal_command"}, "working"),
    # A tool that failed to dispatch, or an MCP error: a tool ran all the same.
    ({**GROK_BASE, "hook_event_name": "PostToolUseFailure", "toolName": "linear__save_issue"}, "working"),
    # Grok's backstop for a turn that reported no end: it ends one still in flight, nothing else.
    ({**GROK_BASE, "hook_event_name": "Notification", "notificationType": "idle_prompt"}, "settle"),
    ({**GROK_BASE, "hook_event_name": "Notification", "notificationType": "permission_prompt"}, "needsInput"),
    ({**GROK_BASE, "hook_event_name": "Notification", "notification_type": "permission_prompt"}, "needsInput"),
    ({**GROK_BASE, "hook_event_name": "Stop", "reason": "end_turn", "backgroundTasks": []}, "done"),
    ({**GROK_BASE, "hook_event_name": "Stop"}, "done"),
    ({**GROK_BASE, "hook_event_name": "StopFailure", "error": "rate_limit"}, "done"),
    ({**GROK_BASE, "hook_event_name": "StopCancelled", "reason": "user_interrupt"}, "done"),
])
def test_grok_hook_mapping(payload, kind):
    ev = parse_grok_hook(payload)
    assert ev is not None
    assert (ev.agent, ev.kind, ev.session_id, ev.cwd, ev.iterm_session_id) == (
        "grok", kind, "g-1", "/repo/.worktrees/x", "w0t0p0:grok-tab")


@pytest.mark.parametrize("payload", [
    {**GROK_BASE, "hook_event_name": "Stop", "reason": "channel_closed"},
    {**GROK_BASE, "hook_event_name": "Stop", "reason": "shutdown"},
    # Paused on a background subagent: the turn works on through its child, as Claude's does.
    {**GROK_BASE, "hook_event_name": "Stop", "reason": "end_turn",
     "backgroundTasks": [{"id": "t1", "type": "subagent", "status": "running", "agentType": "general"}]},
    {**GROK_BASE, "hook_event_name": "Stop", "reason": "end_turn",
     "backgroundTasks": [{"id": "t1", "type": "shell", "status": "running", "command": "npm run dev"},
                         {"id": "t2", "type": "subagent"}]},
    # A nested agent's own events are not the session's.
    {**GROK_BASE, "hook_event_name": "StopCancelled", "reason": "max_turns", "subagentType": "explore"},
    {**GROK_BASE, "hook_event_name": "UserPromptSubmit", "subagentType": "explore"},
    {**GROK_BASE, "hook_event_name": "PostToolUse", "subagentType": "explore"},
    {**GROK_BASE, "hook_event_name": "Notification", "notificationType": "idle_prompt", "subagentType": "explore"},
    {**GROK_BASE, "hook_event_name": "Notification", "notificationType": "task_complete"},
    {**GROK_BASE, "hook_event_name": "PreToolUse"},
    {},
    "not a dict",
])
def test_grok_hook_ignored(payload):
    assert parse_grok_hook(payload) is None


@pytest.mark.parametrize("tasks", [
    # A dev server or a watcher never completes, so it would hold every later turn at working.
    [{"id": "t1", "type": "shell", "status": "running", "command": "npm run dev"}],
    [{"id": "t1", "type": "monitor", "status": "running", "description": "tail -f log"}],
    # A child that has finished is not holding the turn.
    [{"id": "t1", "type": "subagent", "status": "completed"}],
    ["not an entry", {"type": ["subagent"]}],
    "not a list",
])
def test_a_grok_stop_over_background_work_that_is_no_subagent_is_done(tasks):
    # Grok's wake turns fire UserPromptSubmit, which puts the row back to working by itself.
    ev = parse_grok_hook({**GROK_BASE, "hook_event_name": "Stop", "reason": "end_turn", "backgroundTasks": tasks})
    assert ev is not None and ev.kind == "done"


def test_grok_events_carry_their_turn():
    start = parse_grok_hook({**GROK_BASE, "hook_event_name": "UserPromptSubmit", "promptId": "p1"})
    tool = parse_grok_hook({**GROK_BASE, "hook_event_name": "PostToolUse", "promptId": "p1"})
    end = parse_grok_hook({**GROK_BASE, "hook_event_name": "StopCancelled", "promptId": "p1"})
    assert (start.turn_id, start.starts_turn) == ("p1", True)
    assert (tool.turn_id, tool.starts_turn) == ("p1", False)
    assert (end.turn_id, end.starts_turn) == ("p1", False)
    # Session-scoped events carry none, and a malformed one is none.
    assert parse_grok_hook({**GROK_BASE, "hook_event_name": "Notification", "notificationType": "idle_prompt"}).turn_id is None
    assert parse_grok_hook({**GROK_BASE, "hook_event_name": "Stop", "promptId": ["p1"]}).turn_id is None


def test_a_childs_permission_prompt_is_not_held_to_the_parents_turn():
    ev = parse_grok_hook({**GROK_BASE, "hook_event_name": "Notification", "notificationType": "permission_prompt",
                          "subagentType": "general", "promptId": "child-turn"})
    assert ev.turn_id is None


@pytest.mark.parametrize("marker", [None, ""])
def test_an_empty_subagent_type_is_the_main_session(marker):
    # Grok omits the key in the main session; an empty one must not silence every event.
    assert parse_grok_hook({**GROK_BASE, "hook_event_name": "UserPromptSubmit", "subagentType": marker}).kind == "working"


def test_a_childs_permission_prompt_still_needs_input():
    # Grok waits on the user for a background subagent's permission prompt as for the session's own.
    ev = parse_grok_hook({**GROK_BASE, "hook_event_name": "Notification", "notificationType": "permission_prompt",
                          "subagentType": "general"})
    assert ev is not None and ev.kind == "needsInput" and ev.session_id == "g-1"


@pytest.mark.parametrize("parser", [parse_claude_hook, parse_codex_hook, parse_grok_hook, parse_pi_hook])
@pytest.mark.parametrize("bad", [["Stop"], {"name": "Stop"}, 7, None])
def test_a_type_confused_event_name_is_ignored_not_raised(parser, bad):
    assert parser({**BASE, "hook_event_name": bad}) is None


@pytest.mark.parametrize("payload", [
    {**GROK_BASE, "hook_event_name": "Stop", "reason": ["shutdown"]},
    {**GROK_BASE, "hook_event_name": "Stop", "reason": {"why": "shutdown"}},
])
def test_grok_stop_with_a_type_confused_reason_is_a_turn_end(payload):
    # Not a session-end reason Grok documents, so it reads as a reason Grok did not name.
    assert parse_grok_hook(payload).kind == "done"


@pytest.mark.parametrize("bad", [["permission_prompt"], {"type": "permission_prompt"}])
def test_a_type_confused_notification_type_is_ignored(bad):
    assert parse_grok_hook({**GROK_BASE, "hook_event_name": "Notification", "notificationType": bad}) is None
    assert parse_grok_hook({**GROK_BASE, "hook_event_name": "Notification", "notification_type": bad}) is None
    assert parse_claude_hook({**BASE, "hook_event_name": "Notification", "notification_type": bad}) is None


def test_claude_route_drops_grok_payloads():
    # Grok loads ~/.claude/settings.json hooks by default. Its payload carries `hookEventName`,
    # a key Claude never sends; were Grok ever to allow loopback HTTP, it must not count as Claude.
    assert parse_claude_hook({**BASE, "hook_event_name": "Stop", "hookEventName": "stop"}) is None


def test_grok_statusline_fields():
    tick = parse_grok_statusline({
        "session_id": "g-1", "cwd": "/wt", "model": {"id": "grok-4.7", "display_name": "Grok 4.7"},
        "effort": {"level": "high"}, "context_window": {"used_percentage": 37, "context_window_size": 500000},
        "_aiterm_iterm_session_id": "w0t0p0:tab-1"}, now=1)
    # Grok sends no rate-limit summary, so a tick is never account usage.
    assert tick == StatusLine(usage=None, session_id="g-1", cwd="/wt", iterm_session_id="w0t0p0:tab-1",
                              model="grok-4.7", reasoning="high", context_percent=37)


def test_grok_statusline_absent_fields_are_none():
    # Grok omits what it cannot source; an absent context is unknown, never zero.
    assert parse_grok_statusline({"session_id": "g-1"}, now=1) == StatusLine(None, "g-1", None, None, None, None, None)
    assert parse_grok_statusline({"context_window": {"used_percentage": 140}}, now=1).context_percent == 100
    assert parse_grok_statusline({"session_id": {"x": 1}, "model": {"id": 4}, "effort": {"level": []}}, now=1) == (
        StatusLine(None, None, None, None, None, None, None))


@pytest.mark.parametrize("parse,payload", [
    (parse_claude_hook, {**BASE, "hook_event_name": "Stop"}),
    (parse_claude_hook, {**BASE, "hook_event_name": "SubagentStart", "agent_id": "c1"}),
    (parse_claude_hook, {**BASE, "hook_event_name": "PostModelSwitch", "to_model": "m"}),
    (parse_codex_hook, {**BASE, "hook_event_name": "SessionStart"}),
    (parse_codex_hook, {**BASE, "hook_event_name": "Stop"}),
    (parse_grok_hook, {"hook_event_name": "UserPromptSubmit", "sessionId": "g", "promptId": "p1"}),
    (parse_pi_hook, {**PI_BASE, "hook_event_name": "agent_start"}),
])
def test_an_event_carries_the_name_its_harness_gave_it(parse, payload):
    # The resolver binds a Codex thread by which event bound it, from the event rather than the raw body.
    ev = parse(payload)
    assert ev is not None and ev.event_name == payload["hook_event_name"]


GROK_TOTALS = {"session_input_tokens": 8_181_637, "session_output_tokens": 41_002,
               "session_usage": {"input_tokens": 90_000, "cache_creation_input_tokens": 1_637,
                                 "cache_read_input_tokens": 8_090_000, "output_tokens": 41_002}}


def test_grok_statusline_carries_the_sessions_totals_with_its_subagents():
    tick = parse_grok_statusline({"session_id": "g", "context_window": GROK_TOTALS}, now=1)
    assert tick.tokens == TokenTally(8_181_637, 8_091_637, 41_002)


def test_grok_totals_before_the_split_have_an_unknown_cached_share():
    cw = {"session_input_tokens": 12, "session_output_tokens": 3}
    assert parse_grok_statusline({"context_window": cw}, now=1).tokens == TokenTally(12, None, 3)


@pytest.mark.parametrize("cw", [None, "x", {}, {"session_input_tokens": "12", "session_output_tokens": 3},
                                {"session_input_tokens": 12}, {"session_input_tokens": -1, "session_output_tokens": 3}])
def test_grok_totals_are_none_when_unusable(cw):
    payload = {} if cw is None else {"context_window": cw}
    assert parse_grok_statusline(payload, now=1).tokens is None


def test_claude_statusline_names_the_conversations_transcript_and_no_totals():
    tick = parse_claude_statusline({"session_id": "c", "transcript_path": "/p/c.jsonl",
                                    "context_window": {"total_input_tokens": 15_500, "total_output_tokens": 1_200}}, now=1)
    # Claude's `total_*` are the window's fill now, not the conversation's spend: never a tally.
    assert tick.transcript == "/p/c.jsonl" and tick.tokens is None


@pytest.mark.parametrize("path", ["relative/c.jsonl", "/p/c.json", "", ["/p/c.jsonl"], None])
def test_a_transcript_must_be_an_absolute_jsonl_path(path):
    assert parse_claude_statusline({"transcript_path": path}, now=1).transcript is None


@pytest.mark.parametrize("name", ["UserPromptSubmit", "Stop", "PermissionRequest", "SessionStart"])
def test_every_claude_hook_names_its_conversations_transcript(name):
    event = parse_claude_hook({"hook_event_name": name, "session_id": "c", "cwd": "/wt", "transcript_path": "/p/c.jsonl"})
    assert event is not None and event.transcript == "/p/c.jsonl"


def test_pi_reports_the_sessions_tally():
    event = parse_pi_hook({**PI_BASE, "hook_event_name": "turn_end", "tokens": {"input": 168, "cached": 135, "output": 13}})
    assert event.kind is None and event.tokens == TokenTally(168, 135, 13)


@pytest.mark.parametrize("tokens", [None, "x", {"input": 1}, {"input": "1", "output": 2}])
def test_pi_tokens_are_none_when_unusable(tokens):
    assert parse_pi_hook({**PI_BASE, "hook_event_name": "tokens", "tokens": tokens}).tokens is None
