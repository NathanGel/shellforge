from __future__ import annotations

from dataclasses import dataclass, field

from .models import PROJECT_TAG, TASK_TAG, AgentKind, RawSession, SessionInfo, State, TokenTally, classify_agent


@dataclass(slots=True)
class SnapshotDiff:
    """Session ids by what a snapshot did to them. `replaced` are sessions still open whose
    foreground process id changed: another conversation, whatever the agent."""
    opened: list[str] = field(default_factory=list)
    changed: list[str] = field(default_factory=list)
    closed: list[str] = field(default_factory=list)
    replaced: list[str] = field(default_factory=list)


class SessionRegistry:
    def __init__(self) -> None:
        self._sessions: dict[str, SessionInfo] = {}
        self._window_task: dict[str, str] = {}
        self._window_project: dict[str, str] = {}
        self._window_active: dict[str, str] = {}

    # -- snapshot -------------------------------------------------------
    def apply_snapshot(self, raw: list[RawSession]) -> SnapshotDiff:
        diff = SnapshotDiff()
        for r in raw:  # learn tags first so untagged siblings can inherit
            if t := r.user_vars.get(TASK_TAG):
                self._window_task[r.window_id] = t
            if p := r.user_vars.get(PROJECT_TAG):
                self._window_project[r.window_id] = p
            if r.active:
                self._window_active[r.window_id] = r.session_id
        seen: set[str] = set()
        for r in raw:
            seen.add(r.session_id)
            info = self._to_info(r)
            old = self._sessions.get(r.session_id)
            if old is None:
                self._sessions[r.session_id] = info
                diff.opened.append(r.session_id)
                continue
            if info.job_pid != old.job_pid:
                diff.replaced.append(r.session_id)
            # The state is the status engine's to settle (an exited agent's `done` stays unseen).
            info.state = old.state
            # Everything else the agent reported belongs to its conversation, not the iTerm tab.
            # A tab reused for another agent or another process must not keep the old one's model
            # or context, nor send Cmd+T into the worktree an exited Claude had entered.
            if info.agent == old.agent and info.job_pid == old.job_pid:
                info.model, info.reasoning, info.agent_cwd = old.model, old.reasoning, old.agent_cwd
                info.context_percent, info.tokens, info.transcript = old.context_percent, old.tokens, old.transcript
            if info != old:
                self._sessions[r.session_id] = info
                diff.changed.append(r.session_id)
            else:
                old.title = info.title  # not part of the comparison, but the status engine reads it
        for sid in list(self._sessions):
            if sid not in seen:
                del self._sessions[sid]
                diff.closed.append(sid)
        live_windows = {r.window_id for r in raw}
        for wid in set(self._window_task) | set(self._window_project) | set(self._window_active):
            if wid not in live_windows:
                self._window_task.pop(wid, None)
                self._window_project.pop(wid, None)
                self._window_active.pop(wid, None)
        return diff

    def _to_info(self, r: RawSession) -> SessionInfo:
        return SessionInfo(
            session_id=r.session_id, window_id=r.window_id, tab_index=r.tab_index,
            task_id=r.user_vars.get(TASK_TAG) or self._window_task.get(r.window_id),
            project_id=r.user_vars.get(PROJECT_TAG) or self._window_project.get(r.window_id),
            agent=classify_agent(r.command_line), model=None, state="idle",
            title=r.title or "", cwd=r.cwd or "", job_pid=r.job_pid,
            # Read back from the map rather than from `r`, so a snapshot in which iTerm2
            # marks nothing current leaves the last known answer standing instead of
            # un-marking every tab (and broadcasting the churn).
            active=self._window_active.get(r.window_id) == r.session_id,
        )

    # -- mutation owned by the status engine -----------------------------
    def set_state(self, session_id: str, state: State) -> bool:
        s = self._sessions.get(session_id)
        if s is None or s.state == state:
            return False
        s.state = state
        return True

    def set_agent_cwd(self, session_id: str, cwd: str | None) -> bool:
        s = self._sessions.get(session_id)
        if s is None or not cwd or s.agent_cwd == cwd:
            return False
        s.agent_cwd = cwd
        return True

    def set_context(self, session_id: str, percent: int | None) -> bool:
        s = self._sessions.get(session_id)
        if s is None or s.context_percent == percent:
            return False
        s.context_percent = percent
        return True

    def set_tokens(self, session_id: str, tokens: TokenTally | None) -> bool:
        s = self._sessions.get(session_id)
        if s is None or s.tokens == tokens:
            return False
        s.tokens = tokens
        return True

    def set_transcript(self, session_id: str, transcript: str) -> bool:
        s = self._sessions.get(session_id)
        if s is None or s.transcript == transcript:
            return False
        s.transcript = transcript
        return True

    def set_model(self, session_id: str, model: str | None) -> bool:
        s = self._sessions.get(session_id)
        if s is None or s.model == model:
            return False
        s.model = model
        return True

    def set_reasoning(self, session_id: str, reasoning: str | None) -> bool:
        s = self._sessions.get(session_id)
        if s is None or s.reasoning == reasoning:
            return False
        s.reasoning = reasoning
        return True

    # -- lookups ---------------------------------------------------------
    def get(self, session_id: str) -> SessionInfo | None:
        return self._sessions.get(session_id)

    def all(self) -> list[SessionInfo]:
        return sorted(self._sessions.values(), key=lambda s: (s.window_id, s.tab_index))

    def for_task(self, task_id: str) -> list[SessionInfo]:
        return [s for s in self.all() if s.task_id == task_id]

    def by_job_pid(self, pid: int) -> SessionInfo | None:
        return next((s for s in self._sessions.values() if s.job_pid == pid), None)

    def by_cwd_and_agent(self, cwd: str, agent: AgentKind) -> list[SessionInfo]:
        # Either directory counts: an agent that chdirs (Claude entering a worktree, Codex
        # told to work elsewhere) no longer shares the shell's cwd, which is all iTerm2
        # reports, and its own directory is what its hook posts carry.
        return [s for s in self.all() if s.agent == agent and cwd in (s.cwd, s.agent_cwd)]

    def task_for_window(self, window_id: str) -> str | None:
        return self._window_task.get(window_id)

    def project_for_window(self, window_id: str) -> str | None:
        return self._window_project.get(window_id)

    def active_for_window(self, window_id: str) -> str | None:
        """The session that was current in this window as of the last snapshot.

        Deliberately not refreshed when the new-session notification fires: a tab the user
        just opened with Cmd+T is already current by then, and what Cmd+T has to inherit is
        the tab it was pressed from."""
        return self._window_active.get(window_id)

    def most_recent(self, sessions: list[SessionInfo]) -> SessionInfo | None:
        """Of `sessions` (any subset of ours), return the one first seen most
        recently. `_sessions` is a dict keyed by session_id that preserves
        insertion order, i.e. first-seen order, since Python 3.7."""
        if not sessions:
            return None
        order = list(self._sessions)
        return max(sessions, key=lambda s: order.index(s.session_id))
