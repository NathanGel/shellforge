from __future__ import annotations

import os
import time
from collections.abc import Callable, Collection, Mapping
from dataclasses import dataclass, field

from .claude_subagents import TranscriptTail
from .hook_events import HookEvent
from .models import END_OF_TURN_SURVIVES_CWD_LOSS, SessionInfo, State, TokenTally
from .sessions import SessionRegistry

CLAUDE_FILE_STATUS: dict[str, State | None] = {
    "busy": "working", "thinking": "working", "running": "working",
    "waiting": "needsInput", "idle": None, "shell": None,
}

# How long an agent's cwd must stay missing before the daemon ends its turn for it. Long enough for a
# real `Stop` sent over a cwd-independent transport to land first.
ORPHAN_SETTLE_SECONDS = 10.0

# How long a Claude subagent's transcript may go unwritten, while its parent's turn waits on it, before
# the child counts as dead. Claude's stream watchdog kills a child after 600 s without progress, but
# that leaves an interruption in the transcript, which ends the child at once. Live children have gone
# 28 minutes without a write -- a long generation, a stream retry -- so this only catches one that died
# writing nothing at all.
SUBAGENT_QUIET_SECONDS = 45 * 60.0


def path_is_missing(path: str) -> bool:
    """Whether a session's directory is really gone: removed (ENOENT), or a component of it is no
    longer a directory (ENOTDIR). Any other failure -- EACCES on a TCC-protected folder, EIO, a
    stale or unreachable network mount, a NUL in a path another process sent -- says nothing
    about the directory, so it counts as present rather than force a turn to end."""
    try:
        os.stat(path)
    except (FileNotFoundError, NotADirectoryError):
        return True
    except (OSError, ValueError):
        return False
    return False


@dataclass(slots=True)
class _Child:
    """A running subagent. `transcript` is where a Claude child writes (None for the other
    harnesses), `started_at` the wall clock at its latest SubagentStart. `stamp` is its transcript's
    (mtime, size) as last seen, and `quiet_since` when that stamp was first seen, on the monotonic clock."""
    transcript: str | None
    started_at: float
    stamp: tuple[int, int] | None = None
    quiet_since: float = 0.0


@dataclass(slots=True)
class Turn:
    """What the engine remembers of one session's turn, beside the state the registry holds. Made on
    the first event that needs it, and forgotten whole when the conversation ends (`reset_turn`)."""
    # When a hook last said what the turn is doing. The tick's corroborating signals lag the hooks:
    # a session file written before then speaks for an earlier moment.
    hook_at: float = float("-inf")
    # Whether a Codex title has shown a spinner since the last hook said working. Codex draws it a
    # moment after UserPromptSubmit; its absence before then does not end a turn.
    spun: bool = False
    # The subagents running, by id.
    children: dict[str, _Child] = field(default_factory=dict)
    # A hook, title or session file said the foreground turn ended while a child still runs: the
    # last child to stop finishes the change.
    deferred_done: bool = False
    # The state an open PI prompt interrupted: closing the last prompt puts it back. PI can open a
    # prompt over another, so how many are open is counted.
    before_prompt: State | None = None
    prompts_open: int = 0
    # When the agent's cwd was first found missing, on the monotonic clock. A hook transport that
    # spawns a process in that cwd can deliver nothing more, so settle_orphans ends the turn.
    cwd_missing_since: float | None = None
    # The turn the session is on, for a harness that names its turns (Grok's `promptId`).
    turn_id: str | None = None


def _has_spinner(title: str) -> bool:
    return bool(title) and "⠀" <= title[0] <= "⣿"


class StatusEngine:
    def __init__(self, registry: SessionRegistry, clock: Callable[[], float],
                 monotonic: Callable[[], float] = time.monotonic):
        self.reg = registry
        # `clock` is the wall clock, which a hook's stamp must share with a session file's mtime;
        # `monotonic` times the orphan window, which an NTP step must not shorten.
        self._clock, self._monotonic = clock, monotonic
        self._turns: dict[str, Turn] = {}

    def turn(self, session_id: str) -> Turn | None:
        """What the engine remembers of the session's turn, if anything: a view for inspection, by a
        test or a diagnosis, and not to be changed through. The engine's own methods change it."""
        return self._turns.get(session_id)

    def _turn(self, session_id: str) -> Turn:
        if (turn := self._turns.get(session_id)) is None:
            turn = self._turns[session_id] = Turn()
        return turn

    def apply_event(self, session_id: str, ev: HookEvent) -> list[str]:
        """What a hook says happened to the session's turn (`ev.kind`; its metadata is
        `apply_metadata`'s). `ev.turn_id` is the turn it reports on, when the harness names one (Grok's
        `promptId`), and `ev.starts_turn` marks the hook that begins it: Grok dispatches a cancelled
        turn's report off its command loop, so a report can arrive after the next turn has started.
        `ev.subagent_transcript` is where a starting Claude child writes; `ev.running_subagents`, on a
        Claude Stop, the children still running."""
        if (kind := ev.kind) is None or (s := self.reg.get(session_id)) is None:
            return []
        turn = self._turn(session_id)
        # The hook's transport still reaches the daemon, so the turn is not orphaned: a pending
        # settle is cancelled, and a directory still missing starts a new window.
        turn.cwd_missing_since = None
        if kind == "sessionStart":
            self.reset_turn(session_id)
            return []
        if kind == "subagentStart":
            return self.subagent_started(session_id, ev.subagent_id, ev.subagent_transcript)
        if kind == "subagentStop":
            return self.subagent_stopped(session_id, ev.subagent_id)
        if kind == "promptStart":
            return self._prompt_started(session_id)
        if kind == "promptEnd":
            return self._prompt_ended(session_id)
        if (turn_id := ev.turn_id) is not None:
            if ev.starts_turn:
                turn.turn_id = turn_id
            elif (current := turn.turn_id) != turn_id and (
                    current is not None or (kind == "done" and s.state == "idle")):
                # A report for another turn: an earlier one's, delivered late, or one never seen to
                # start -- on an idle row, an interrupted bash-mode command's, which is no turn.
                return []
        if kind == "settle":
            if s.state not in ("working", "needsInput"):
                return []
            kind = "done"
        turn.hook_at = self._clock()
        released: list[str] = []
        if kind == "done" and (running_subagents := ev.running_subagents) is not None:
            # A child the Stop no longer lists is gone, SubagentStop or not; the last one lands a
            # completion an earlier turn deferred, before this one lands its own.
            for child_id in [c for c in turn.children if c not in running_subagents]:
                released += self.subagent_stopped(session_id, child_id)
        if kind == "done" and turn.children:
            # Not what the turn is doing now: it works on through its children, so an open prompt
            # keeps the state it will restore, and the last child's stop completes it.
            turn.deferred_done = True
            return released
        # A hook that says what the turn is doing now supersedes the state a prompt interrupted.
        turn.before_prompt, turn.prompts_open = None, 0
        if kind == "working":
            # A new turn: a completion the previous turn deferred must not end this one, nor the
            # spinner the previous turn showed.
            turn.deferred_done = turn.spun = False
        return released + ([session_id] if self.reg.set_state(session_id, kind) else [])

    def apply_metadata(self, session_id: str, *, model: str | None = None, reasoning: str | None = None,
                       context: int | None = None, cwd: str | None = None, tokens: TokenTally | None = None,
                       transcript: str | None = None) -> list[str]:
        """What an agent reports beside its state: each value present replaces the session's, and
        an absent one leaves it be. Returns the sessions that changed."""
        s = self.reg.get(session_id)
        if s is None:
            return []
        changed: list[str] = []
        if model and self.reg.set_model(session_id, model):
            changed.append(session_id)
        if reasoning and self.reg.set_reasoning(session_id, reasoning):
            changed.append(session_id)
        if self.reg.set_agent_cwd(session_id, cwd):
            changed.append(session_id)
        if context is not None:
            # Context is presented per provider within a task. Updating sibling tabs for the same
            # agent keeps its last value stable across tab changes without letting a Claude and a
            # Codex conversation overwrite each other.
            own = [other for other in self.reg.for_task(s.task_id) if other.agent == s.agent] if s.task_id else [s]
            changed += [other.session_id for other in own if self.reg.set_context(other.session_id, context)]
        if transcript and self.reg.set_transcript(session_id, transcript) and self.reg.set_tokens(session_id, None):
            # Another transcript is another conversation (a /clear): its count starts from nothing
            # rather than show the last one's until the next read.
            changed.append(session_id)
        if tokens is not None and self.reg.set_tokens(session_id, tokens):
            changed.append(session_id)
        return changed

    def reset_turn(self, session_id: str) -> None:
        """Forgets the subagents and deferred completion of a conversation that has ended: a new
        session started, or another process took over the tab. A child whose SubagentStop was lost
        would otherwise hold the row at working for good."""
        self._turns.pop(session_id, None)

    def _prompt_started(self, session_id: str) -> list[str]:
        s = self.reg.get(session_id)
        if s is None:
            return []
        turn = self._turn(session_id)
        # A prompt opened over another keeps the state the first one interrupted.
        if turn.before_prompt is None:
            turn.before_prompt = s.state
        turn.prompts_open += 1
        return [session_id] if self.reg.set_state(session_id, "needsInput") else []

    def _prompt_ended(self, session_id: str) -> list[str]:
        """Once the last open prompt closes, puts back the state the first interrupted -- which
        is working only if a turn was running. The deferred completion is left alone: a background
        child still owes it. What changed underneath the prompt was written into the remembered
        state (`_behind_input`)."""
        if (turn := self._turns.get(session_id)) is None:
            return []
        turn.prompts_open -= 1
        if turn.prompts_open > 0:
            return []
        before, turn.before_prompt, turn.prompts_open = turn.before_prompt, None, 0
        if before is None:
            return []
        return [session_id] if self.reg.set_state(session_id, before) else []

    @staticmethod
    def _behind_input(turn: Turn, state: State) -> None:
        """A change an input request keeps off the row. Under an open PI prompt it lands in the state
        the prompt will restore, so closing the prompt shows it; PI has no tick to correct it later."""
        if turn.before_prompt is not None:
            turn.before_prompt = state

    def subagent_started(self, session_id: str, subagent_id: str | None, transcript: str | None = None) -> list[str]:
        s = self.reg.get(session_id)
        if s is None or not subagent_id:
            return []
        turn = self._turn(session_id)
        # A resumed child starts again under the same id, and its quiet window with it.
        turn.children[subagent_id] = _Child(transcript, self._clock(), None, self._monotonic())
        # An input request must stay visible; every other state means the
        # task is actively progressing while this child is alive.
        if s.state == "needsInput":
            self._behind_input(turn, "working")
            return []
        return [session_id] if self.reg.set_state(session_id, "working") else []

    def subagent_stopped(self, session_id: str, subagent_id: str | None) -> list[str]:
        s = self.reg.get(session_id)
        if s is None or not subagent_id:
            return []
        turn = self._turns.get(session_id)
        if turn is None or turn.children.pop(subagent_id, None) is None:
            return []
        if turn.children or not turn.deferred_done:
            return []
        turn.deferred_done = False
        if s.state == "needsInput":
            self._behind_input(turn, "done")
            return []
        return [session_id] if self.reg.set_state(session_id, "done") else []

    def subagent_transcripts(self) -> set[str]:
        """The transcripts release_dead_subagents needs: those of the children a deferred done waits
        on. Only a Claude child has one. The caller reads them, off the event loop, and passes them in."""
        return {c.transcript for turn in self._turns.values() if turn.deferred_done
                for c in turn.children.values() if c.transcript}

    def release_dead_subagents(self, tails: Mapping[str, TranscriptTail]) -> list[str]:
        """Drops each child a deferred done waits on whose transcript proves it dead, as its lost
        SubagentStop would have: the transcript ends in an interruption or a SubagentStop, written
        since the child's latest SubagentStart, or it has not changed for SUBAGENT_QUIET_SECONDS.
        A transcript missing from `tails` -- not written yet, or not read -- proves nothing."""
        now, changed = self._monotonic(), []
        for sid, turn in list(self._turns.items()):
            if not turn.deferred_done:
                continue
            for child_id, child in list(turn.children.items()):
                if child.transcript is None or (tail := tails.get(child.transcript)) is None:
                    continue
                if tail.stamp != child.stamp:
                    child.stamp, child.quiet_since = tail.stamp, now
                # A verdict written before a resume speaks for the run that ended, not this one.
                if (tail.ended and tail.written_at > child.started_at) or now - child.quiet_since >= SUBAGENT_QUIET_SECONDS:
                    changed += self.subagent_stopped(sid, child_id)
        return changed

    def apply_claude_file_status(self, session_id: str, status: str, written_at: float) -> list[str]:
        """Corroborates the hooks with Claude's own session file, written at `written_at`. A file no
        newer than the last hook is ignored: Claude rewrites it after the hook fires, and until
        then it still describes the moment before -- `busy` under a fresh permission prompt."""
        s = self.reg.get(session_id)
        turn = self._turns.get(session_id)
        if s is None or (turn is not None and written_at <= turn.hook_at):
            return []
        if status not in CLAUDE_FILE_STATUS:
            # A status this daemon does not know says nothing about the turn -- least of all that
            # it ended.
            return []
        mapped = CLAUDE_FILE_STATUS[status]
        if mapped is not None:
            # `waiting` keeps a hook-derived input request visible. Once the
            # user answers, Claude changes the session file back to one of the
            # active statuses; that is the resume signal which restores the
            # spinner even though no new UserPromptSubmit hook is emitted.
            target = mapped
        elif turn is not None and turn.children:
            if s.state == "needsInput":
                return []
            turn.deferred_done = True
            target = "working"
        else:
            target = "done" if s.state in {"working", "needsInput"} else s.state
        return [session_id] if self.reg.set_state(session_id, target) else []

    def apply_codex_title(self, session_id: str, title: str) -> list[str]:
        s = self.reg.get(session_id)
        if s is None:
            return []
        turn = self._turns.get(session_id)
        if _has_spinner(title):
            # Permission and elicitation answers do not emit UserPromptSubmit.
            # The spinner returning is Codex's reliable resume signal.
            self._turn(session_id).spun = True
            target: State = "working"
        elif s.state != "working" or turn is None or not turn.spun:
            return []
        elif turn.children:
            turn.deferred_done = True
            return []
        else:
            target = "done"
        return [session_id] if self.reg.set_state(session_id, target) else []

    def agent_exited(self, session_id: str) -> list[str]:
        self.reset_turn(session_id)
        return [session_id] if self.reg.set_state(session_id, "idle") else []

    def mark_seen(self, task_id: str) -> list[str]:
        sessions = self.reg.for_task(task_id)
        for s in sessions:
            # A completion seen while a prompt covers it must not come back unseen when it closes.
            if (turn := self._turns.get(s.session_id)) is not None and turn.before_prompt == "done":
                turn.before_prompt = "idle"
        return [s.session_id for s in sessions if s.state == "done" and self.reg.set_state(s.session_id, "idle")]

    @staticmethod
    def _orphan_path(s: SessionInfo) -> str | None:
        """The directory whose loss would orphan the session's turn, or None if nothing would: no
        turn is in flight, or its harness's end of turn survives a removed cwd."""
        if s.agent == "shell" or s.agent in END_OF_TURN_SURVIVES_CWD_LOSS or s.state not in ("working", "needsInput"):
            return None
        return s.agent_cwd or s.cwd or None

    def orphan_paths(self) -> set[str]:
        """The directories settle_orphans needs to know about: the caller checks them, off the event
        loop, and passes the missing ones in."""
        return {path for s in self.reg.all() if (path := self._orphan_path(s))}

    def settle_orphans(self, missing: Collection[str]) -> list[str]:
        """Ends the turn of an agent session whose working directory has been `missing` for
        ORPHAN_SETTLE_SECONDS: an agent that merged and removed its own worktree. Forced past a
        deferred completion, since no subagent hook can arrive either (spec §10b)."""
        now, changed = self._monotonic(), []
        for s in self.reg.all():
            sid, path = s.session_id, self._orphan_path(s)
            if path is None or path not in missing:
                if (turn := self._turns.get(sid)) is not None:
                    turn.cwd_missing_since = None
                continue
            turn = self._turn(sid)
            if turn.cwd_missing_since is None:
                turn.cwd_missing_since = now
            if now - turn.cwd_missing_since < ORPHAN_SETTLE_SECONDS:
                continue
            # The children, the deferred done, the open prompts and the window go; what tells this
            # conversation's reports from an earlier one's stays: the last hook's stamp, the spinner
            # seen, the turn id.
            self._turns[sid] = Turn(hook_at=turn.hook_at, spun=turn.spun, turn_id=turn.turn_id)
            if self.reg.set_state(sid, "done"):
                changed.append(sid)
        return changed
