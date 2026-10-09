from __future__ import annotations

import os
from collections.abc import Callable
from dataclasses import dataclass, replace
from typing import Any, NamedTuple

from .models import HARNESSES, ITERM_SESSION_FIELD, AgentKind, TokenTally, Transition, Usage
from .usage import finite_number, parse_claude_rate_limits, whole_count

NEEDS_INPUT_NOTIFICATIONS = {"permission_prompt", "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog"}
SIMPLE_EVENTS: dict[str, Transition] = {"UserPromptSubmit": "working", "Stop": "done", "PermissionRequest": "needsInput"}


def _nonempty_string(value: Any) -> str | None:
    """A payload field as the string it should be, or None. Every value a parser tests against a
    set goes through this first: a list or dict from another process would otherwise raise."""
    return value if isinstance(value, str) and value else None


@dataclass(frozen=True, slots=True)
class HookEvent:
    agent: AgentKind
    kind: Transition | None
    model: str | None
    session_id: str | None
    cwd: str | None
    subagent_id: str | None = None
    iterm_session_id: str | None = None
    reasoning: str | None = None
    context_percent: int | None = None
    # The turn the event belongs to (Grok's `promptId`), and whether the event starts it. A report
    # for another turn is late and is ignored (StatusEngine.apply_event); None applies regardless.
    turn_id: str | None = None
    starts_turn: bool = False
    # Where a Claude SubagentStart's child writes its transcript: what the status engine reads when
    # the child's SubagentStop never comes.
    subagent_transcript: str | None = None
    # The subagents a Claude Stop's `background_tasks` says are still running; None when it cannot say.
    running_subagents: frozenset[str] | None = None
    # The harness's own name for the event (`hook_event_name`): a Codex thread's binding to its tab
    # depends on which event bound it (SessionResolver.bind).
    event_name: str | None = None
    # What the session has spent, subagents included, when the harness says it in its own posts (PI).
    tokens: TokenTally | None = None
    # The Claude conversation's transcript, which its tokens are summed from (claude_tokens).
    transcript: str | None = None


def _subagent(name: str, p: dict[str, Any]) -> tuple[Transition, str] | None:
    child = _nonempty_string(p.get("agent_id"))
    return ("subagentStart" if name == "SubagentStart" else "subagentStop", child) if child else None


def _claude_subagent_transcript(p: dict[str, Any], child: str) -> str | None:
    """The child's transcript. SubagentStart carries only the session's, `<dir>/<session>.jsonl`;
    Claude Code writes the child's beside it, at `<dir>/<session>/subagents/agent-<id>.jsonl`. A path
    the hook gives for the child itself (SubagentStop's `agent_transcript_path`) wins."""
    if (own := _nonempty_string(p.get("agent_transcript_path"))) is not None:
        return own
    session = _nonempty_string(p.get("transcript_path"))
    if session is None or not session.endswith(".jsonl"):
        return None
    return os.path.join(session.removesuffix(".jsonl"), "subagents", f"agent-{child}.jsonl")


# The `background_tasks` types whose children the daemon can match by id: a subagent's task id is its
# agent_id, and shells, monitors and MCP tasks run no agent. A teammate's task id is not the agent_id
# its hooks carry, and a workflow's agents sit behind the workflow's own id.
CLAUDE_MATCHABLE_TASK_TYPES = frozenset({"subagent", "shell", "monitor", "MCP task"})
# The statuses Claude Code lists a task under while it is in flight.
CLAUDE_IN_FLIGHT_TASK_STATUSES = frozenset({"running", "pending"})


def _claude_running_subagents(tasks: Any) -> frozenset[str] | None:
    """The agent ids of the subagents a Stop's `background_tasks` lists as in flight. None when the
    list cannot prove a counted child gone: it is absent (an older Claude Code, or a registry it could
    not reach), malformed, or holds work whose agents it does not name by their agent_id."""
    if not isinstance(tasks, list):
        return None
    running: set[str] = set()
    for task in tasks:
        if not isinstance(task, dict) or task.get("type") not in CLAUDE_MATCHABLE_TASK_TYPES:
            return None
        if task["type"] != "subagent" or _nonempty_string(task.get("status")) not in CLAUDE_IN_FLIGHT_TASK_STATUSES:
            continue
        if (child := _nonempty_string(task.get("id"))) is None:
            return None
        running.add(child)
    return frozenset(running)


def _session_start(p: dict[str, Any]) -> Transition | None:
    """A Claude, Codex or Grok SessionStart begins a new conversation — except after a compaction,
    which each reports as `source: "compact"` in the middle of a turn whose background subagents may
    still be running. That one carries only metadata: resetting the turn there would end it early."""
    return None if p.get("source") == "compact" else "sessionStart"


def parse_claude_hook(p: dict[str, Any]) -> HookEvent | None:
    ev = _parse_claude_hook(p)
    # Every Claude hook names its conversation's transcript, which its token tally is read from.
    return replace(ev, transcript=_transcript(p)) if ev is not None else None


def _parse_claude_hook(p: dict[str, Any]) -> HookEvent | None:
    # Grok also runs ~/.claude/settings.json hooks. Its payload carries `hookEventName`, which Claude
    # never sends; today Grok refuses our http:// hooks, and this keeps a future Grok from counting as Claude.
    if not isinstance(p, dict) or "hookEventName" in p:
        return None
    name = _nonempty_string(p.get("hook_event_name"))
    sid, cwd = _nonempty_string(p.get("session_id")), _nonempty_string(p.get("cwd"))
    if name == "SessionStart":
        return HookEvent("claude", _session_start(p), _nonempty_string(p.get("model")), sid, cwd, event_name=name)
    if name == "PostModelSwitch":
        return HookEvent("claude", None, _nonempty_string(p.get("to_model")), sid, cwd, event_name=name)
    if name in {"SubagentStart", "SubagentStop"}:
        if (child := _subagent(name, p)) is None:
            return None
        transcript = _claude_subagent_transcript(p, child[1]) if name == "SubagentStart" else None
        return HookEvent("claude", child[0], None, sid, cwd, child[1], subagent_transcript=transcript, event_name=name)
    if name == "Stop":
        return HookEvent("claude", "done", None, sid, cwd, running_subagents=_claude_running_subagents(p.get("background_tasks")),
                         event_name=name)
    if name in SIMPLE_EVENTS:
        return HookEvent("claude", SIMPLE_EVENTS[name], None, sid, cwd, event_name=name)
    if name == "Notification":
        nt = _nonempty_string(p.get("notification_type"))
        if nt in NEEDS_INPUT_NOTIFICATIONS:
            return HookEvent("claude", "needsInput", None, sid, cwd, event_name=name)
        if nt == "agent_completed":
            return HookEvent("claude", "done", None, sid, cwd, event_name=name)
    return None


def parse_codex_hook(p: dict[str, Any]) -> HookEvent | None:
    if not isinstance(p, dict):
        return None
    name = _nonempty_string(p.get("hook_event_name"))
    model, sid, cwd = (_nonempty_string(p.get(key)) for key in ("model", "session_id", "cwd"))
    iterm_session_id = _nonempty_string(p.get(ITERM_SESSION_FIELD))
    if name == "SessionStart":
        return HookEvent("codex", _session_start(p), model, sid, cwd, iterm_session_id=iterm_session_id, event_name=name)
    if name in {"SubagentStart", "SubagentStop"}:
        child = _subagent(name, p)
        return HookEvent("codex", child[0], None, sid, cwd, child[1], iterm_session_id, event_name=name) if child else None
    if name in SIMPLE_EVENTS:
        return HookEvent("codex", SIMPLE_EVENTS[name], model, sid, cwd, iterm_session_id=iterm_session_id, event_name=name)
    return None


PI_EVENTS: dict[str, Transition | None] = {
    "session_start": None,  # "sessionStart" for a reason in PI_NEW_CONVERSATION_REASONS
    "agent_start": "working",
    "agent_settled": "done",
    "ui_prompt_start": "promptStart",
    "ui_prompt_end": "promptEnd",
    "model_select": None,
    "thinking_level_select": None,
    # Token reports that are not a turn's start or end: the session's own turn closing, and a
    # subagent's totals moving while the session itself waits.
    "turn_end": None,
    "tokens": None,
    # PI has no subagents of its own; the extension relays pi-subagents' `subagents:*` bus events.
    "subagent_start": "subagentStart",
    "subagent_stop": "subagentStop",
}


# Why PI started a session, when that begins a new conversation. `reload` re-runs the extensions
# inside the running one -- PI's counterpart of Claude's compaction -- so, like a reason this
# daemon does not know or an extension too old to send one, it carries metadata only.
PI_NEW_CONVERSATION_REASONS = frozenset({"startup", "new", "resume", "fork"})


def _clamped_percent(value: Any) -> int | None:
    number = finite_number(value)
    return max(0, min(100, round(number))) if number is not None else None


def _transcript(p: dict[str, Any]) -> str | None:
    """A Claude conversation's transcript as its hooks and status line name it: an absolute `.jsonl`
    path, the one shape whose subagents directory can be found beside it."""
    path = _nonempty_string(p.get("transcript_path"))
    return path if path is not None and os.path.isabs(path) and path.endswith(".jsonl") else None


def _tally(input_tokens: Any, cached: int | None, output_tokens: Any) -> TokenTally | None:
    """A tally from the two totals, or None unless both are counts. The cached share is passed
    already checked: one that is not a count is unknown, not zero."""
    if (spent_in := whole_count(input_tokens)) is None or (spent_out := whole_count(output_tokens)) is None:
        return None
    return TokenTally(spent_in, cached, spent_out)


def _grok_tokens(p: dict[str, Any]) -> TokenTally | None:
    """Grok's session totals. Its usage ledger keeps a subagent's calls on the parent session too
    (a parent's modelCalls are its own plus its child's), so these already hold the whole tree.
    `session_input_tokens` counts the cache; `session_usage` splits it out once a call has been made."""
    cw = p.get("context_window")
    if not isinstance(cw, dict):
        return None
    usage, cached = cw.get("session_usage"), None
    if isinstance(usage, dict):
        read, written = whole_count(usage.get("cache_read_input_tokens")), whole_count(usage.get("cache_creation_input_tokens"))
        if read is not None and written is not None:
            cached = read + written
    return _tally(cw.get("session_input_tokens"), cached, cw.get("session_output_tokens"))


def _pi_tokens(value: Any) -> TokenTally | None:
    """The tally PI's extension sends: the session's own and its subagents' (hooks/pi-aiterm-status.ts)."""
    if not isinstance(value, dict):
        return None
    return _tally(value.get("input"), whole_count(value.get("cached")), value.get("output"))


def parse_pi_hook(p: dict[str, Any]) -> HookEvent | None:
    if not isinstance(p, dict):
        return None
    name = _nonempty_string(p.get("hook_event_name"))
    if name is None or name not in PI_EVENTS:
        return None
    kind = PI_EVENTS[name]
    if name == "session_start" and _nonempty_string(p.get("reason")) in PI_NEW_CONVERSATION_REASONS:
        kind = "sessionStart"
    child = None
    if kind in {"subagentStart", "subagentStop"} and (child := _nonempty_string(p.get("agent_id"))) is None:
        return None
    return HookEvent(
        agent="pi",
        kind=kind,
        model=_nonempty_string(p.get("model")),
        session_id=_nonempty_string(p.get("session_id")),
        cwd=_nonempty_string(p.get("cwd")),
        subagent_id=child,
        iterm_session_id=_nonempty_string(p.get(ITERM_SESSION_FIELD)),
        reasoning=_nonempty_string(p.get("reasoning")),
        context_percent=_clamped_percent(p.get("context_percent")),
        tokens=_pi_tokens(p.get("tokens")),
        event_name=name,
    )


GROK_EVENTS: dict[str, Transition] = {
    "UserPromptSubmit": "working",
    # A tool ran, so a permission prompt it waited on was answered: Grok's resume signal. A tool
    # that failed to dispatch, or an MCP error, reports PostToolUseFailure instead.
    "PostToolUse": "working",
    "PostToolUseFailure": "working",
    "StopFailure": "done",
    "StopCancelled": "done",
}
# The `Notification` types AiTerm reads. `idle_prompt` is Grok's backstop for a turn that reported no
# end -- a rewind, a cancel-and-send, a superseded turn, a stop gate at its continuation limit: it
# fires about a minute after the session settles, on any turn end, so it settles rather than marks.
GROK_NOTIFICATIONS: dict[str, Transition] = {"permission_prompt": "needsInput", "idle_prompt": "settle"}
# `Stop` reasons that end the session rather than a turn.
GROK_SESSION_END_REASONS = frozenset({"channel_closed", "shutdown"})


# What a `backgroundTasks` entry's status says once its task is over. Grok lists in-flight tasks only,
# so a subagent in any other status -- or none -- is still running.
GROK_FINISHED_TASK_STATUSES = frozenset({"completed", "failed", "cancelled"})


def _has_running_subagent(tasks: Any) -> bool:
    """Whether a `Stop`'s `backgroundTasks` holds a subagent still running. Only a subagent holds the
    turn, as a Claude child does: a shell task or a monitor -- a dev server, a watcher -- can run for
    the rest of the session, and whatever wakes the session fires UserPromptSubmit anyway."""
    return isinstance(tasks, list) and any(
        isinstance(task, dict) and task.get("type") == "subagent"
        and _nonempty_string(task.get("status")) not in GROK_FINISHED_TASK_STATUSES
        for task in tasks)


def _notification_type(p: dict[str, Any]) -> str | None:
    # Grok's own camelCase key, or Claude's, which it also sends.
    return _nonempty_string(p.get("notificationType")) or _nonempty_string(p.get("notification_type"))


def parse_grok_hook(p: dict[str, Any]) -> HookEvent | None:
    """Grok Build's command-hook payload: Claude's PascalCase `hook_event_name` beside Grok's own
    camelCase fields. The iTerm session arrives as the X-AiTerm-iTerm-Session header.

    A payload carrying `subagentType` is a nested agent's own event, which is not the session's --
    except a permission prompt: a background child raises its own, and Grok waits on the user for it
    all the same. The main session omits the key, so it is tested by value, not presence.

    `promptId` names the turn an event belongs to, and is absent for session-scoped ones. A child's
    is its own turn's, not the parent's, so its permission prompt carries none."""
    if not isinstance(p, dict):
        return None
    name = _nonempty_string(p.get("hook_event_name"))
    child = bool(p.get("subagentType"))
    if child and not (name == "Notification" and _notification_type(p) == "permission_prompt"):
        return None
    kind: Transition | None
    if name == "SessionStart":
        kind = _session_start(p)
    elif name in GROK_EVENTS:
        kind = GROK_EVENTS[name]
    elif name == "Notification":
        kind = GROK_NOTIFICATIONS.get(_notification_type(p) or "")
        if kind is None:
            return None
    elif name == "Stop":
        if _nonempty_string(p.get("reason")) in GROK_SESSION_END_REASONS or _has_running_subagent(p.get("backgroundTasks")):
            return None
        kind = "done"
    else:
        return None
    return HookEvent(
        agent="grok", kind=kind, model=None,
        session_id=_nonempty_string(p.get("sessionId")) or _nonempty_string(p.get("session_id")),
        cwd=_nonempty_string(p.get("cwd")),
        iterm_session_id=_nonempty_string(p.get(ITERM_SESSION_FIELD)),
        turn_id=None if child else _nonempty_string(p.get("promptId")),
        starts_turn=name == "UserPromptSubmit",
        event_name=name,
    )


def _context_percent(p: dict[str, Any]) -> int | None:
    """`context_window.used_percentage`: how full *this conversation* is. Unlike the rate-limit
    windows it arrives from one session, so the service resolves that session and the status engine
    promotes it to the task's latest value rather than putting it in the vendor's `Usage`. Clamped,
    because the payload is another process's arithmetic and the ring cannot render 140%."""
    cw = p.get("context_window")
    if not isinstance(cw, dict):
        return None
    return _clamped_percent(cw.get("used_percentage"))


class StatusLine(NamedTuple):
    """What one status-line tick tells the daemon: the session it describes, and facts that land in
    different places -- account usage in the `UsageStore`, the model, reasoning and context fill on
    the resolved session's task. Grok sends no rate-limit summary, so its `usage` is None."""
    usage: Usage | None
    session_id: str | None
    cwd: str | None
    iterm_session_id: str | None
    model: str | None
    reasoning: str | None
    context_percent: int | None
    # What the session has spent, when the status line says it (Grok). Claude's does not: its
    # `total_*` counts are the window's fill now, and its spend is summed from `transcript`.
    tokens: TokenTally | None = None
    transcript: str | None = None


def _object_field(p: dict[str, Any], key: str, field: str) -> str | None:
    """`p[key][field]` as a string, as in `model.id` and `effort.level`."""
    value = p.get(key)
    return _nonempty_string(value.get(field)) if isinstance(value, dict) else None


def parse_claude_statusline(p: dict[str, Any], now: int) -> StatusLine:
    return StatusLine(
        parse_claude_rate_limits(p.get("rate_limits"), now),
        _nonempty_string(p.get("session_id")), _nonempty_string(p.get("cwd")),
        _nonempty_string(p.get(ITERM_SESSION_FIELD)),
        _object_field(p, "model", "id"), None, _context_percent(p),
        transcript=_transcript(p),
    )


def parse_grok_statusline(p: dict[str, Any], now: int) -> StatusLine:
    return StatusLine(
        None, _nonempty_string(p.get("session_id")), _nonempty_string(p.get("cwd")),
        _nonempty_string(p.get(ITERM_SESSION_FIELD)),
        _object_field(p, "model", "id"), _object_field(p, "effort", "level"), _context_percent(p),
        tokens=_grok_tokens(p),
    )


HookParser = Callable[[dict[str, Any]], HookEvent | None]
# A status-line parser also takes the time a rate-limit summary is stamped with.
StatusLineParser = Callable[[dict[str, Any], int], StatusLine]
# Each harness's parsers. A route in models.HARNESSES without its parser here fails at import.
_HOOK_PARSER: dict[AgentKind, HookParser] = {
    "claude": parse_claude_hook, "codex": parse_codex_hook, "grok": parse_grok_hook, "pi": parse_pi_hook,
}
_STATUSLINE_PARSER: dict[AgentKind, StatusLineParser] = {"claude": parse_claude_statusline, "grok": parse_grok_statusline}

# The agent hook routes, each with the parser for its agent's payload.
HOOK_PARSERS: dict[str, HookParser] = {h.hook_route: _HOOK_PARSER[h.agent] for h in HARNESSES}
# The status-line shims' routes, each with the agent it reports on and the parser for its payload.
STATUSLINE_PARSERS: dict[str, tuple[AgentKind, StatusLineParser]] = {
    h.statusline_route: (h.agent, _STATUSLINE_PARSER[h.agent]) for h in HARNESSES if h.statusline_route}
