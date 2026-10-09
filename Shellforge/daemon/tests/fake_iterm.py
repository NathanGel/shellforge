# daemon/tests/fake_iterm.py
from __future__ import annotations
import asyncio
import itertools
from collections.abc import Awaitable, Callable

from shellforged.iterm_bridge import ItermAuthFailed, ItermPort, ItermUnavailable
from shellforged.models import Frame, RawSession


class FakeIterm:
    """A scripted iTerm2. What the daemon does to it is announced the way the library announces it:
    each notification for a window or tab the daemon created, and for a window it closed, is its own
    task, started while the call that caused it is still awaiting and before that call returns.
    The `user_*` helpers deliver inline instead, so a test can assert on the handler's effect right
    after awaiting them. A tab is a `tab_index` shared by its panes, and closing one renumbers the
    tabs after it, as iTerm2 does."""

    def __init__(self, connected: bool = True, notify_on_create: bool = True):
        self._connected = connected
        # Whether create_window / create_tab / close_window announce themselves. Off for a test that
        # wants the daemon to hear nothing of its own work.
        self.notify_on_create = notify_on_create
        self.closed = False
        # Set to make connect() fail the way a refused cookie request does, iTerm2 running.
        self.auth_error: str | None = None
        self.windows: dict[str, dict] = {}       # window_id -> {"frame": Frame, "sessions": [session_id], "active": bool}
        self.sessions: dict[str, RawSession] = {}
        self.sent: list[tuple[str, str]] = []
        self.titles: dict[str, str] = {}
        self.title_calls = 0
        self.background_requests: list[tuple[list[str], bool]] = []
        # Set to make every snapshot, or every send_text, fail as iTerm2 can mid-call.
        self.snapshot_error: Exception | None = None
        self.send_error: Exception | None = None
        self._ids = itertools.count(1)
        self._new_cbs: list[Callable[[str], Awaitable[None]]] = []
        self._closed_cbs: list[Callable[[str], Awaitable[None]]] = []
        self._activated_cbs: list[Callable[[str], Awaitable[None]]] = []
        self._disc_cbs: list[Callable[[], Awaitable[None]]] = []
        self._notifications: set[asyncio.Future[None]] = set()

    async def connect(self) -> str | None:
        if self.auth_error is not None:
            raise ItermAuthFailed(self.auth_error)
        if not self._connected:
            raise ItermUnavailable("iTerm2 not running")
        return "3.7.2"

    def is_connected(self) -> bool:
        return self._connected

    async def close(self) -> None:
        self.closed, self._connected = True, False

    async def create_window(self, cwd: str, title: str, tags: dict[str, str], frame: Frame) -> tuple[str, str]:
        wid = f"w{next(self._ids)}"
        self.windows[wid] = {"frame": frame, "sessions": [], "active": True, "current": None}
        sid = await self._add_session(wid, cwd, tags, command_line="-zsh", title=title)
        await self._announce_new(sid)
        return wid, sid

    async def create_tab(self, window_id: str, tags: dict[str, str], cwd: str | None = None) -> str:
        if cwd is None:
            cwd = self.sessions[self.windows[window_id]["sessions"][0]].cwd
        sid = await self._add_session(window_id, cwd, tags, command_line="-zsh", title="zsh")
        await self._announce_new(sid)
        return sid

    async def _add_session(self, wid, cwd, tags, command_line, title, tab_index: int | None = None):
        """A new tab, or with `tab_index` a pane in that tab."""
        sid = f"s{next(self._ids)}"
        if tab_index is None:
            tab_index = 1 + max((self.sessions[s].tab_index for s in self.windows[wid]["sessions"]), default=-1)
        self.sessions[sid] = RawSession(sid, wid, tab_index, command_line, 1000 + len(self.sessions), title, cwd, dict(tags))
        self.windows[wid]["sessions"].append(sid)
        self.windows[wid]["current"] = sid  # iTerm2 makes a new tab the current one
        return sid

    async def activate_window(self, window_id: str) -> None:
        for w in self.windows.values():
            w["active"] = False
        self.windows[window_id]["active"] = True

    async def set_frame(self, window_id: str, frame: Frame) -> None:
        self.windows[window_id]["frame"] = frame

    async def close_window(self, window_id: str) -> None:
        closed = self.windows.pop(window_id)["sessions"]
        for sid in closed:
            self.sessions.pop(sid, None)
        for sid in closed:
            await self._announce_closed(sid)

    async def send_text(self, session_id: str, text: str) -> None:
        if self.send_error is not None:
            raise self.send_error
        self.sent.append((session_id, text))

    async def set_session_tags(self, session_id: str, tags: dict[str, str]) -> None:
        self.sessions[session_id].user_vars.update(tags)

    async def set_session_titles(self, titles: dict[str, str]) -> list[str]:
        applied = [sid for sid in titles if sid in self.sessions]
        self.title_calls += len(applied)
        self.titles.update({sid: titles[sid] for sid in applied})
        return applied

    async def set_aiterm_background(self, session_ids: list[str], enabled: bool) -> None:
        self.background_requests.append((list(session_ids), enabled))

    async def snapshot(self) -> list[RawSession]:
        if self.snapshot_error is not None:
            raise self.snapshot_error
        return [self._raw(s) for s in self.sessions.values()]

    async def session_info(self, session_id: str) -> RawSession | None:
        return self._raw(self.sessions[session_id]) if session_id in self.sessions else None

    def _raw(self, s: RawSession) -> RawSession:
        r = RawSession(**vars(s))
        r.active = self.windows.get(r.window_id, {}).get("current") == r.session_id
        return r

    def on_new_session(self, cb: Callable[[str], Awaitable[None]]) -> None:
        self._new_cbs.append(cb)

    def on_session_closed(self, cb: Callable[[str], Awaitable[None]]) -> None:
        self._closed_cbs.append(cb)

    def on_window_activated(self, cb: Callable[[str], Awaitable[None]]) -> None:
        self._activated_cbs.append(cb)

    def on_disconnect(self, cb: Callable[[], Awaitable[None]]) -> None:
        self._disc_cbs.append(cb)

    # -- notifications ---------------------------------------------------
    async def _announce_new(self, session_id: str) -> None:
        if self.notify_on_create:
            await self._dispatch(self._new_cbs, session_id)

    async def _announce_closed(self, session_id: str) -> None:
        if self.notify_on_create:
            await self._dispatch(self._closed_cbs, session_id)

    async def _dispatch(self, callbacks: list[Callable[[str], Awaitable[None]]], session_id: str) -> None:
        """Starts each callback as a task of its own, as the library does, and yields once so they
        have begun by the time the caller carries on."""
        for cb in callbacks:
            task = asyncio.ensure_future(cb(session_id))
            self._notifications.add(task)
            task.add_done_callback(self._notifications.discard)
        await asyncio.sleep(0)

    async def settle(self) -> None:
        """Waits for every notification dispatched so far, and any those start, to finish."""
        while self._notifications:
            await asyncio.gather(*self._notifications)

    # -- test helpers ----------------------------------------------------
    async def user_opens_tab(self, window_id: str, cwd: str = "/Users/me") -> str:
        """Simulates Cmd+T: a Default-profile session in $HOME, untagged."""
        sid = await self._add_session(window_id, cwd, {}, command_line="-zsh", title="zsh")
        for cb in self._new_cbs:
            await cb(sid)
        return sid

    async def add_pane(self, window_id: str, tab_index: int, cwd: str = "/Users/me") -> str:
        """Simulates splitting a tab: a second, untagged session sharing its `tab_index`."""
        sid = await self._add_session(window_id, cwd, {}, command_line="-zsh", title="zsh", tab_index=tab_index)
        for cb in self._new_cbs:
            await cb(sid)
        return sid

    def user_selects_tab(self, session_id: str) -> None:
        """Simulates clicking a tab: it becomes the window's current session."""
        self.windows[self.sessions[session_id].window_id]["current"] = session_id

    async def user_activates_window(self, window_id: str) -> None:
        """Simulates iTerm2 receiving focus, such as after clicking an agent notification."""
        await self.activate_window(window_id)
        for cb in self._activated_cbs:
            await cb(window_id)

    async def user_runs(self, session_id: str, command_line: str, job_pid: int, title: str = ""):
        s = self.sessions[session_id]
        s.command_line, s.job_pid, s.title = command_line, job_pid, title or s.title

    async def user_closes_session(self, session_id: str):
        s = self.sessions.pop(session_id)
        window = self.windows[s.window_id]
        window["sessions"].remove(session_id)
        self._renumber_tabs(s.window_id)
        for cb in self._closed_cbs:
            await cb(session_id)

    def _renumber_tabs(self, window_id: str) -> None:
        """Closing a tab shifts every later one down to close the gap; closing a pane of a tab that
        has others leaves the numbers alone."""
        sessions = [self.sessions[sid] for sid in self.windows[window_id]["sessions"]]
        numbering = {old: new for new, old in enumerate(sorted({s.tab_index for s in sessions}))}
        for s in sessions:
            s.tab_index = numbering[s.tab_index]

    async def disconnect(self):
        self._connected = False
        for cb in self._disc_cbs:
            await cb()

    async def reconnect(self) -> None:
        """Simulates iTerm2 coming back up, for the daemon's own reconnect
        loop (which calls `connect()`, not this) to pick up on its next
        retry."""
        self._connected = True


# Checked by mypy: a FakeIterm that drifts from the port the service is written against fails the
# lint step, rather than letting the service's tests pass against a bridge that no longer exists.
_: ItermPort = FakeIterm()
