"""Sessions as the Shellforge app reports them. Shellforge owns its tabs in-process, so the daemon
does not ask iTerm2 for them: the app sends the list (`sessions.update`) and this port hands the
last one to the registry on each tick, as the iTerm2 bridge's snapshot did."""
from __future__ import annotations

import asyncio
import contextlib
from collections.abc import Awaitable, Callable
from typing import Any

from . import protocol
from .models import PROJECT_TAG, TASK_TAG, RawSession
from .rpc_server import RpcError


class AppOwnsWindows(RuntimeError):
    """Windows and tabs are the app's to make; the daemon only tracks what it is told."""


def parse_sessions(params: Any) -> list[RawSession]:
    """The `sessions.update` params as RawSessions, or RpcError('bad_params') naming the first fault."""
    if not isinstance(params, dict) or not isinstance(params.get("sessions"), list):
        raise RpcError(protocol.BAD_PARAMS, "sessions.update needs {sessions: [...]}")
    parsed: list[RawSession] = []
    for i, entry in enumerate(params["sessions"]):
        if not isinstance(entry, dict):
            raise RpcError(protocol.BAD_PARAMS, f"sessions[{i}] must be an object")

        def need(key: str, kind: type, optional: bool = False, entry: dict[str, Any] = entry, i: int = i) -> Any:
            value = entry.get(key)
            if value is None and optional:
                return None
            # A bool is an int to isinstance; only a real int counts as one here.
            if not isinstance(value, kind) or (isinstance(value, bool) and kind is not bool):
                raise RpcError(protocol.BAD_PARAMS, f"sessions[{i}].{key} is missing or not a {kind.__name__}")
            return value

        tags = {tag: value for tag, value in ((TASK_TAG, need("taskId", str, True)), (PROJECT_TAG, need("projectId", str, True)))
                if value is not None}
        parsed.append(RawSession(session_id=need("sessionId", str), window_id=need("windowId", str),
                                 tab_index=need("tabIndex", int), command_line=need("commandLine", str, True),
                                 job_pid=need("jobPid", int, True), title=need("title", str), cwd=need("cwd", str),
                                 user_vars=tags, active=need("active", bool)))
    return parsed


class AppSessions:
    """An `ItermPort` whose sessions are the last list the app sent. It makes no windows or tabs."""

    def __init__(self) -> None:
        self._sessions: list[RawSession] = []
        #: When the last list arrived, on the event loop's clock; -inf before the first.
        self.updated_at = float("-inf")
        self._arrived = asyncio.Event()

    def replace(self, sessions: list[RawSession]) -> None:
        self._sessions = list(sessions)
        self.updated_at = asyncio.get_running_loop().time()
        self._arrived.set()
        self._arrived = asyncio.Event()

    async def next_update(self, timeout: float) -> None:
        """Waits for the app's next list, or `timeout` seconds."""
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(self._arrived.wait(), timeout)

    async def connect(self) -> str | None:
        return "Shellforge"

    def is_connected(self) -> bool:
        return True

    async def close(self) -> None:
        return None

    async def snapshot(self) -> list[RawSession]:
        return list(self._sessions)

    async def session_info(self, session_id: str) -> RawSession | None:
        return next((s for s in self._sessions if s.session_id == session_id), None)

    async def _refuse(self, *_: Any, **__: Any) -> Any:
        raise AppOwnsWindows("Shellforge makes its own windows and tabs")

    create_window = create_tab = activate_window = set_frame = close_window = _refuse
    send_text = set_session_tags = set_session_titles = set_shellforge_background = _refuse

    def on_new_session(self, cb: Callable[[str], Awaitable[None]]) -> None:
        return None

    def on_session_closed(self, cb: Callable[[str], Awaitable[None]]) -> None:
        return None

    def on_window_activated(self, cb: Callable[[str], Awaitable[None]]) -> None:
        return None

    def on_disconnect(self, cb: Callable[[], Awaitable[None]]) -> None:
        return None
