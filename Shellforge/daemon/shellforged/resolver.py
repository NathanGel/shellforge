"""Which iTerm2 session an agent's post belongs to, and which Codex thread each tab runs."""
from __future__ import annotations

from dataclasses import dataclass

from .claude_sessions import ClaudeSessionFiles
from .models import HARNESS_BY_AGENT, AgentKind
from .sessions import SessionRegistry


@dataclass(slots=True)
class CodexBinding:
    """The Codex thread a tab runs. Unlike a pin, this is authoritative and replaced by every
    resolved Codex hook. A non-None `pending_generation` leaves the process binding open until a
    newer snapshot, because a replacement Codex can post before iTerm2 reports its new pid."""
    thread_id: str
    pid: int | None
    pending_generation: int | None


class SessionResolver:
    def __init__(self, registry: SessionRegistry, claude_files: ClaudeSessionFiles):
        self.registry, self.claude_files = registry, claude_files
        # (agent, the agent's own session id) -> the iTerm2 session it was last resolved to.
        self._pins: dict[tuple[str, str], str] = {}
        self._codex: dict[str, CodexBinding] = {}
        self._generation = 0

    def resolve(self, agent: AgentKind, session_id: str | None, cwd: str | None,
                iterm_session_id: str | None = None) -> str | None:
        """Pid (Claude) or the tab id the hook itself carries (Codex, Grok, PI) first; then the tab this
        conversation was pinned to earlier, while it still runs the same agent; then, as a
        heuristic, the directory. The pin is what survives an agent chdir'ing into a worktree:
        from then on the post's cwd matches no tab's shell directory."""
        if (direct := self.resolve_directly(agent, session_id, iterm_session_id)) is not None:
            return direct
        if session_id and (pinned := self._pins.get((agent, session_id))):
            s = self.registry.get(pinned)
            if s is not None and s.agent == agent:
                return pinned
        return self._by_cwd(cwd, agent)

    def resolve_directly(self, agent: AgentKind, session_id: str | None,
                         iterm_session_id: str | None = None) -> str | None:
        """The tab a post came from, by evidence rather than inference: the agent's own pid (Claude)
        or the tab id the hook carries (Codex, Grok, PI). A pin or a directory match can be stale."""
        if (harness := HARNESS_BY_AGENT.get(agent)) is None:
            return None
        if harness.placement == "pid_file":
            if session_id and (pid := self.claude_files.pid_for_session(session_id)) and (s := self.registry.by_job_pid(pid)):
                return s.session_id
        elif iterm_session_id:
            # $ITERM_SESSION_ID includes a pane prefix (`w1t0p0:<uuid>`), while iTerm2's Python API
            # reports only the suffix as the session id.
            s = self.registry.get(iterm_session_id.rpartition(":")[2])
            if s is not None and s.agent == agent:
                return s.session_id
        return None

    def bind(self, iterm_session_id: str, agent: AgentKind, session_id: str | None, hook_event: str | None = None) -> None:
        """Records what a resolved post says about its tab: the pin, and for Codex the thread."""
        if not session_id:
            return
        self._pins[(agent, session_id)] = iterm_session_id
        if agent != "codex":
            return
        session = self.registry.get(iterm_session_id)
        pid = session.job_pid if session else None
        current = self._codex.get(iterm_session_id)
        if hook_event == "Stop":
            # A final hook cannot authorize this thread to follow a future process id. Binding it
            # to the currently observed process makes replacement invalidate it.
            self._codex[iterm_session_id] = CodexBinding(session_id, pid, None)
        elif current is None or current.thread_id != session_id or hook_event == "SessionStart":
            # A different thread, or an explicit resume of the same thread, may belong to a
            # replacement process whose pid iTerm2 has not reported yet.
            self._codex[iterm_session_id] = CodexBinding(session_id, pid, self._generation)

    def snapshot_applied(self) -> None:
        """Called after every registry snapshot. Validates every Codex binding, including those of
        tabs no longer running Codex, which the tick's Codex branch never reaches."""
        self._generation += 1
        for iterm_session_id in tuple(self._codex):
            self.codex_thread(iterm_session_id)

    def codex_thread(self, iterm_session_id: str) -> str | None:
        binding = self._codex.get(iterm_session_id)
        if binding is None:
            return None
        session = self.registry.get(iterm_session_id)
        if session is None or session.agent != "codex":
            del self._codex[iterm_session_id]
            return None
        if binding.pending_generation is not None:
            if self._generation > binding.pending_generation:
                binding.pid, binding.pending_generation = session.job_pid, None
            return binding.thread_id
        if session.job_pid != binding.pid:
            del self._codex[iterm_session_id]
            return None
        return binding.thread_id

    def forget(self, iterm_session_id: str) -> None:
        self._codex.pop(iterm_session_id, None)
        for key in [key for key, pinned in self._pins.items() if pinned == iterm_session_id]:
            del self._pins[key]

    def _by_cwd(self, cwd: str | None, agent: AgentKind) -> str | None:
        if not cwd:
            return None
        s = self.registry.most_recent(self.registry.by_cwd_and_agent(cwd, agent))
        return s.session_id if s else None
