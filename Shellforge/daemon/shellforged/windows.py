"""The windows and tabs AiTerm opens in iTerm2, and the user's tabs that join them."""
from __future__ import annotations
import asyncio
import logging
import shlex
from collections import Counter
from collections.abc import Awaitable, Callable
from typing import Any

from . import protocol
from .iterm_bridge import ItermPort, ItermUnavailable
from .models import PROJECT_TAG, TASK_TAG
from .rpc_params import frame_param, guard, optional_param, param, require_iterm
from .rpc_server import RpcError
from .sessions import SessionRegistry

log = logging.getLogger(__name__)


class WindowManager:
    """Creates task and terminal windows and their tabs, tags a tab the user opens in one and
    moves it to where its window works, and keeps the tab titles and the background the app asks
    for. `tick` refreshes the registry from iTerm2 after each change."""

    def __init__(self, iterm: ItermPort, registry: SessionRegistry, tick: Callable[[], Awaitable[None]]):
        self.iterm, self.registry, self.tick = iterm, registry, tick
        self._creation_lock = asyncio.Lock()
        # Sessions the daemon created and has not yet seen iTerm2 announce, and how many tab.creates
        # are still opening a tab in each window: neither is a user's tab to tag and redirect.
        self._self_created: set[str] = set()
        self._creating_in: Counter[str] = Counter()
        # iTerm2 session id -> the tab title last applied to it, so an unchanged one is not re-sent.
        self._applied_titles: dict[str, str] = {}
        # The sessions whose titles iTerm2 is applying now, less any forgotten meanwhile: a move
        # seen during the request left the title on the tab the session was leaving.
        self._titles_in_flight: set[str] = set()
        self.match_iterm_background = False
        # Requests are answered concurrently, and each of these two sets a state the next one
        # replaces: held in turn, in the order they came, so the last one sent is the one that stays.
        # A new window or tab reads the background under its lock too: a toggle holding it has
        # already listed the sessions it paints, so one made meanwhile must wait for its setting.
        self._titles_lock = asyncio.Lock()
        self._background_lock = asyncio.Lock()

    def forget_session(self, session_id: str) -> None:
        """A closed session's title and creation mark."""
        self.forget_title(session_id)
        self._self_created.discard(session_id)

    def forget_title(self, session_id: str) -> None:
        """A session that moved keeps its id but not its tab's title, so it is applied again."""
        self._applied_titles.pop(session_id, None)
        self._titles_in_flight.discard(session_id)

    def forget_titles(self) -> None:
        """After a reconnect: it may be a restarted iTerm2, which has none of the titles applied before."""
        self._applied_titles.clear()
        self._titles_in_flight.clear()

    async def _create(self, p: dict[str, Any], tags: dict[str, str], title: str) -> dict[str, Any]:
        frame, cwd, cmd = frame_param(p), param(p, "cwd", str), optional_param(p, "agentCommand", str)
        require_iterm(self.iterm)
        wid, sid = await guard(self.iterm.create_window(cwd, title, tags, frame))
        await self._set_up_created(sid, cmd)
        return {"windowId": wid}

    async def create_task(self, p: Any) -> dict[str, Any]:
        task_id, title = param(p, "taskId", str), optional_param(p, "title", str)
        frame_param(p)  # rejected before a retry could return an existing window for it
        async with self._creation_lock:
            require_iterm(self.iterm)
            await guard(self.tick())
            existing = next((s for s in self.registry.all() if s.task_id == task_id), None)
            if existing:
                return {"windowId": existing.window_id}
            return await self._create(p, {TASK_TAG: task_id}, title or task_id)

    async def create_terminal(self, p: Any) -> dict[str, Any]:
        project_id, title = param(p, "projectId", str), optional_param(p, "title", str)
        return await self._create(p, {PROJECT_TAG: project_id}, title or "terminal")

    async def create_tab(self, p: Any) -> dict[str, Any]:
        wid, cmd = param(p, "windowId", str), optional_param(p, "agentCommand", str)
        # A caller that knows where the tab belongs says so; otherwise it inherits, as Cmd+T does.
        cwd = optional_param(p, "cwd", str)
        require_iterm(self.iterm)
        tags = self._window_tags(wid)
        # The iTerm2 new-session notification for this tab's session can fire
        # during create_tab's await, before we learn its session id, so gate
        # on the (already-known) window id instead.
        self._creating_in[wid] += 1
        try:
            sid = await guard(self.iterm.create_tab(wid, tags, cwd or self._anchor_cwd(wid)))
        finally:
            # Counted, not a set: another tab.create into this window may still be under way.
            self._creating_in[wid] -= 1
            if not self._creating_in[wid]:
                del self._creating_in[wid]
        await self._set_up_created(sid, cmd)
        return {"sessionId": sid}

    async def _set_up_created(self, sid: str, cmd: str | None) -> None:
        """The background, the agent command and the tick for a window or tab iTerm2 has made.
        Each failure is logged, not answered: the window exists, an error would make the app
        retry, and a retry opens a second one -- window.createTerminal has no dedupe at all."""
        self._self_created.add(sid)
        async with self._background_lock:
            if self.match_iterm_background:
                await self._after_create("matching the background", self.iterm.set_aiterm_background([sid], True))
        if cmd:
            # Typed while the shell may still be starting, where a one-key prompt can take the first
            # key: Oh My Zsh's "update? [Y/n]" once ran `laude`. A leading space is the key to lose
            # -- there it answers "remind me later" -- and the shell's lexer skips leading blanks, so
            # the command runs as typed. A prompt that reads a whole line is not helped. Under zsh's
            # HIST_IGNORE_SPACE (Oh My Zsh sets it; bash's is HISTCONTROL=ignorespace) the command
            # also stays out of the history, as a redirect's `cd` does, though up-arrow recalls it
            # until the next command.
            await self._after_create("sending the agent command", self.iterm.send_text(sid, " " + cmd + "\n"))
        await self._after_create("tick", self.tick())

    @staticmethod
    async def _after_create(step: str, coro: Awaitable[Any]) -> None:
        try:
            await coro
        except Exception:  # noqa: BLE001 - the window exists either way
            log.exception("%s after creating a window or tab failed", step)

    async def set_match_iterm_background(self, p: Any) -> dict[str, Any]:
        enabled = bool(optional_param(p, "matchItermBackground", bool))
        async with self._background_lock:
            require_iterm(self.iterm)
            # Refresh first: an iTerm2 tab created just before this request belongs to its tagged
            # window even if the regular two-second poll has not observed it yet.
            await guard(self.tick())
            session_ids = [s.session_id for s in self.registry.all() if s.task_id or s.project_id]
            await guard(self.iterm.set_aiterm_background(session_ids, enabled))
            self.match_iterm_background = enabled
        return {}

    def _anchor_cwd(self, window_id: str, exclude: str | None = None) -> str | None:
        """The directory a new tab in this window should inherit.

        The tab that was active when it was opened, and *that tab's agent's* directory when
        it has one — pressing Cmd+T next to a Claude that has moved into a worktree means
        "give me a shell where it is". Falls back to the window's first session, which is
        what spec 2.4 originally did for every tab."""
        sid = self.registry.active_for_window(window_id)
        anchor = self.registry.get(sid) if sid and sid != exclude else None
        if anchor is None:
            anchor = next((s for s in self.registry.all() if s.window_id == window_id and s.session_id != exclude), None)
        if anchor is None:
            return None
        return anchor.agent_cwd or anchor.cwd or None

    def _window_tags(self, window_id: str) -> dict[str, str]:
        """The AiTerm tags a window is known by: `aiterm_task` for a task
        window, `aiterm_project` for one opened by window.createTerminal. Empty
        means the window is not ours."""
        tags: dict[str, str] = {}
        if task := self.registry.task_for_window(window_id):
            tags[TASK_TAG] = task
        if project := self.registry.project_for_window(window_id):
            tags[PROJECT_TAG] = project
        return tags

    async def set_titles(self, p: Any) -> dict[str, Any]:
        """Apply branch titles only to sessions belonging to an AiTerm-managed window.

        The app resolves git branches because it already owns the same cache used by the sidebar.
        A session can disappear between that resolution and this request, so stale ids are skipped
        instead of failing the rest of the batch.
        """
        items = optional_param(p, "titles", list) or []
        async with self._titles_lock:
            return await self._set_titles(items)

    async def _set_titles(self, items: list[Any]) -> dict[str, Any]:
        require_iterm(self.iterm)
        wanted: dict[str, str] = {}
        for item in items:
            if not isinstance(item, dict):
                continue
            session_id, title = item.get("sessionId"), item.get("title")
            if not isinstance(session_id, str) or not isinstance(title, str) or not title:
                continue
            session = self.registry.get(session_id)
            if session is None or not (session.task_id or session.project_id):
                continue
            # Each title costs three iTerm2 calls; one already on its tab is not applied again.
            if self._applied_titles.get(session_id) != title:
                wanted[session_id] = title
        if not wanted:
            return {"changed": 0}
        # One request at a time holds `_titles_lock`, so one set serves.
        self._titles_in_flight = set(wanted)
        try:
            applied = await self.iterm.set_session_titles(wanted)
        except ItermUnavailable as exc:
            raise RpcError(protocol.ITERM_UNAVAILABLE, str(exc)) from exc
        finally:
            in_flight, self._titles_in_flight = self._titles_in_flight, set()
        self._applied_titles.update({session_id: wanted[session_id] for session_id in applied if session_id in in_flight})
        return {"changed": len(applied)}

    async def on_new_session(self, session_id: str) -> None:
        try:
            # Sessions the daemon itself just created (window.createTask/
            # createTerminal, tab.create) already got their agent command (if
            # any) sent directly to their known session id in _create/
            # create_tab. Tagging and cd-redirecting here as well would
            # race that command (spec 2.4's redirect is only for *user*-
            # opened tabs in a tagged window), so skip it for those.
            if session_id in self._self_created:
                self._self_created.discard(session_id)
                await self.tick()
                return
            new = await self.iterm.session_info(session_id)
            if new is None:
                # Not in iTerm2's answer yet, or closed already: nothing to tag, but whatever
                # else changed still reaches the registry.
                await self.tick()
                return
            if new.window_id in self._creating_in:
                # A daemon-issued tab.create is still in flight for this
                # window; its own caller already sent (or will send) the
                # agent command directly, so skip the tag+redirect to avoid
                # racing it.
                await self.tick()
                return
            # Spec 2.4 applies to every window AiTerm owns, whether it is a
            # task window (`aiterm_task`) or a terminal window
            # (`aiterm_project`): Cmd+T inherits neither the tag nor the cwd.
            tags = {k: v for k, v in self._window_tags(new.window_id).items() if not new.user_vars.get(k)}
            if tags:
                cwd = self._anchor_cwd(new.window_id, exclude=session_id)
                await self.iterm.set_session_tags(session_id, tags)
                async with self._background_lock:
                    if self.match_iterm_background:
                        await self.iterm.set_aiterm_background([session_id], True)
                if cwd:
                    await self.iterm.send_text(session_id, f" cd {shlex.quote(cwd)} && clear\n")
            await self.tick()
        except Exception:  # noqa: BLE001 - must not escape into the iTerm2 library's dispatch
            log.exception("on_new_session failed for %s", session_id)
