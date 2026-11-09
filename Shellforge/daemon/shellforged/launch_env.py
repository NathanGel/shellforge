"""Armed launches: the environment, secrets included, that the app hands the helper for one agent
launch in one tab, until `shellforge-run` in that tab takes it.

An arm is single-use, bound to one iTerm2 session and one agent id, and kept for ARM_TTL_SECONDS at
most. It lives only in this process's memory and is never logged: no method here logs, and no
exception carries a value. The socket it travels over is the helper's own (`RpcServer`), which only
this user can open; the tab is named by the session id `shellforge-run` reads from
`$ITERM_SESSION_ID`, as the hooks name theirs (`X-Shellforge-iTerm-Session`)."""
from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field

#: How long an arm waits for its take. The app arms as it opens the tab, so anything later than
#: this is a command re-run by hand, or from scrollback, and gets nothing.
ARM_TTL_SECONDS = 60.0
#: How long a take waits for its arm: the app may arm a moment after the tab's shell runs the command.
TAKE_WAIT_SECONDS = 10.0

#: Whether the process asking may have the tab's arm: True yes, False no, None not known yet (the
#: tab's terminal isn't known), which waits for the next change within the take's wait.
CallerCheck = Callable[[str], Awaitable[bool | None]]


def _tab(session: str) -> str:
    """The session's id without its pane prefix: `w0t1p0:ABC` and `ABC` are one tab."""
    return session.rpartition(":")[2]


@dataclass(slots=True)
class _Arm:
    agent_id: str
    environment: dict[str, str] = field(repr=False)  # a repr must never show a value
    armed_at: float
    # Drops the arm when its time is up, so a value never outlives it for want of a later call.
    expiry: asyncio.TimerHandle | None


class LaunchEnvironments:
    """The armed launches, by tab. `monotonic` is the clock arms expire on, injected for tests."""

    def __init__(self, monotonic: Callable[[], float]):
        self._now = monotonic
        self._arms: dict[str, _Arm] = {}
        # Set, and replaced, on every arm and every `changed`: each waiting take wakes and looks again.
        self._armed = asyncio.Event()

    def arm(self, session_id: str, agent_id: str, environment: dict[str, str]) -> None:
        """Keeps `environment` for `agent_id`'s next launch in the tab, replacing any arm it had."""
        self._prune()
        tab = _tab(session_id)
        self._drop(tab)
        try:
            expiry: asyncio.TimerHandle | None = asyncio.get_running_loop().call_later(ARM_TTL_SECONDS, self._drop, tab)
        except RuntimeError:  # no loop: the next call's prune drops it instead
            expiry = None
        self._arms[tab] = _Arm(agent_id, dict(environment), self._now(), expiry)
        self.changed()

    def changed(self) -> None:
        """Wakes the waiting takes to look again: an arm, or news of the tabs a check reads."""
        armed, self._armed = self._armed, asyncio.Event()
        armed.set()

    async def take(self, iterm_session: str, agent_id: str, timeout: float = TAKE_WAIT_SECONDS,
                   check: CallerCheck | None = None) -> dict[str, str] | None:
        """The environment armed for `agent_id` in the tab `iterm_session` names, once; waiting up to
        `timeout` seconds for it to be armed. None when none was, when it expired, or when `check`
        refuses the caller, which leaves the arm in place; while `check` doesn't know yet, it waits."""
        tab = _tab(iterm_session)
        if not tab:
            return None
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while True:
            armed = self._armed  # before looking: a change after this wakes the wait below
            self._prune()
            arm = self._arms.get(tab)
            if arm is not None and arm.agent_id == agent_id:
                verdict = True if check is None else await check(tab)
                if verdict is False:
                    return None
                # The check may have waited: only the arm it was asked about is taken.
                if verdict and self._arms.get(tab) is arm and not self._expired(arm):
                    self._drop(tab)
                    return arm.environment
            left = deadline - loop.time()
            if left <= 0:
                return None
            try:
                await asyncio.wait_for(armed.wait(), left)
            except TimeoutError:
                return None

    def armed_sessions(self) -> list[str]:
        """The tabs with a live arm, for tests: never the values."""
        self._prune()
        return sorted(self._arms)

    def _expired(self, arm: _Arm) -> bool:
        return self._now() - arm.armed_at >= ARM_TTL_SECONDS

    def _prune(self) -> None:
        for tab in [tab for tab, arm in self._arms.items() if self._expired(arm)]:
            self._drop(tab)

    def _drop(self, tab: str) -> None:
        if (arm := self._arms.pop(tab, None)) is not None and arm.expiry is not None:
            arm.expiry.cancel()
