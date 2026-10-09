"""The daemon's connection to iTerm2: made at startup, remade after every loss, backed off while
iTerm2 refuses it, and -- under --cookies-from-app -- paid for with a cookie the app fetches."""
from __future__ import annotations
import asyncio
import itertools
import logging
from collections.abc import Awaitable, Callable
from typing import Any

from . import protocol
from .iterm_bridge import ItermAuthFailed, ItermPort, ItermUnavailable, use_cookie
from .rpc_params import optional_param, param

log = logging.getLogger(__name__)
RECONNECT_SECONDS = 3.0
# A refused cookie waits on a person -- an Automation grant, iTerm2's Python API setting -- so the
# retry interval doubles from RECONNECT_SECONDS up to this, rather than asking every few seconds.
AUTH_BACKOFF_CAP_SECONDS = 60.0
# How long an attached app may leave a cookie request unanswered before it is asked again. Long
# enough for someone to answer macOS's "AiTerm wants to control iTerm2" prompt the first time.
COOKIE_WAIT_SECONDS = 120.0
# How often that wait looks for an attached app: time with none attached does not count.
COOKIE_CHECK_SECONDS = 1.0

Broadcast = Callable[[str, Any], Awaitable[None]]


async def _launch_iterm() -> None:
    try:
        await asyncio.create_subprocess_exec("open", "-a", "iTerm", stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
    except Exception:  # noqa: BLE001 - a missing/failing `open` must never break the reconnect loop
        log.exception("failed to launch iTerm2 via 'open -a iTerm'")


class ItermSupervisor:
    """Owns the iTerm2 connection's lifecycle and announces it: `iterm.connected`,
    `iterm.disconnected`, `iterm.auth_failed` and `iterm.cookieRequested` all come from here.
    `client_count` says how many apps are attached, which a cookie wait needs to know."""

    def __init__(self, iterm: ItermPort, broadcast: Broadcast, client_count: Callable[[], int],
                 launch_iterm: Callable[[], Awaitable[None]] | None = None, reconnect_seconds: float = RECONNECT_SECONDS,
                 auth_backoff_cap_seconds: float = AUTH_BACKOFF_CAP_SECONDS,
                 reconnect_sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
                 cookies_from_app: bool = False, cookie_wait_seconds: float = COOKIE_WAIT_SECONDS,
                 apply_cookie: Callable[[str, str], None] = use_cookie):
        self.iterm, self.broadcast, self.client_count = iterm, broadcast, client_count
        self.launch_iterm = launch_iterm or _launch_iterm
        self.reconnect_seconds = reconnect_seconds
        self.auth_backoff_cap_seconds = auth_backoff_cap_seconds
        self.reconnect_sleep = reconnect_sleep
        # Called on every successful connect, before `iterm.connected` goes out.
        self.on_connected: Callable[[], None] | None = None
        self.version: str | None = None
        # Why iTerm2 last refused the daemon, for as long as it keeps refusing; and how many times
        # in a row, which sets the backoff.
        self.auth_error: str | None = None
        self._auth_failures = 0
        # The app asks iTerm2 for each connection's cookie, so no osascript runs under AiTerm: macOS
        # counts every process AiTerm starts as AiTerm, and gave each osascript a Dock icon of its
        # own. The request outstanding, if any, is (id, the future the app's answer resolves).
        self.cookies_from_app = cookies_from_app
        if cookie_wait_seconds <= 0:
            # No wait at all would re-request without pause, forever.
            raise ValueError(f"cookie_wait_seconds must be positive, not {cookie_wait_seconds}")
        self.cookie_wait_seconds = cookie_wait_seconds
        self.apply_cookie = apply_cookie
        self._cookie_request: tuple[int, asyncio.Future[dict[str, Any]]] | None = None
        self._cookie_ids = itertools.count(1)
        self._reconnect_task: asyncio.Task[None] | None = None
        self._stopped = False

    # -- lifecycle ---------------------------------------------------------
    async def start(self) -> None:
        self.iterm.on_disconnect(self._on_disconnect)
        # Waiting on the app for a cookie must not hold up startup: the app only attaches once the
        # daemon is serving, so the first attempt runs in the reconnect loop.
        if self.cookies_from_app or not await self._try_connect():
            self._start_reconnect_loop()

    async def stop(self) -> None:
        """Ends the connection for good: no reconnect loop, and no watch on the connection whose
        closing would start one."""
        self._stopped = True
        task = self._reconnect_task
        if task is not None and task is not asyncio.current_task():
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        await self.iterm.close()

    def snapshot_fields(self) -> dict[str, Any]:
        """The connection's part of `workspace.snapshot`. Read without an await, so it belongs to
        the same instant as the rest of the snapshot."""
        connected = self.iterm.is_connected()
        return {"connected": connected, "itermVersion": self.version if connected else None,
                # The first refusal happens at startup, before the app has attached to hear it.
                "itermAuthError": self.auth_error,
                # A cookie request made before the app attached, which it would otherwise never hear.
                "itermCookieRequest": self._cookie_request[0] if self._cookie_request else None}

    # -- RPC ---------------------------------------------------------------
    async def status(self, _p: Any) -> dict[str, Any]:
        return {"connected": self.iterm.is_connected(), "version": self.version if self.iterm.is_connected() else None,
                "authError": self.auth_error}

    async def provide_cookie(self, p: Any) -> dict[str, Any]:
        """The app's answer to `iterm.cookieRequested`. An answer to a request that has already
        timed out or been answered is not accepted, so a late cookie cannot land on a newer one."""
        request_id = param(p, "requestId", int)
        if optional_param(p, "notRunning", bool):
            reply: dict[str, Any] = {"notRunning": True}
        elif (error := optional_param(p, "error", str)) is not None:
            reply = {"error": error}
        else:
            reply = {"cookie": param(p, "cookie", str), "key": param(p, "key", str)}
        pending = self._cookie_request
        if pending is None or pending[0] != request_id or pending[1].done():
            return {"accepted": False}
        pending[1].set_result(reply)
        return {"accepted": True}

    # -- connecting ----------------------------------------------------------
    def _start_reconnect_loop(self) -> None:
        if self._reconnect_task is not None:
            self._reconnect_task.cancel()
        self._reconnect_task = asyncio.get_running_loop().create_task(self._reconnect_loop())

    async def _try_connect(self) -> bool:
        try:
            await self._cookie_from_app()
            self.version = await self.iterm.connect()
        except ItermAuthFailed as exc:
            await self._auth_failed(str(exc))
            return False
        except ItermUnavailable as exc:
            log.info("iTerm2 unavailable: %s", exc)
            self._auth_failures = 0
            if self.auth_error is not None:
                # No longer refused, merely absent: withdraw the warning, back to "Reconnecting…".
                self.auth_error = None
                await self.broadcast(protocol.ITERM_DISCONNECTED, {})
            return False
        self._auth_failures, self.auth_error = 0, None
        if self.on_connected:
            self.on_connected()
        await self.broadcast(protocol.ITERM_CONNECTED, {"version": self.version})
        return True

    async def _auth_failed(self, reason: str) -> None:
        """Logged and broadcast once per streak, and again only if the reason changes: every retry
        runs osascript twice, and a line per retry would bury the one that says why."""
        self._auth_failures += 1
        if reason == self.auth_error:
            return
        self.auth_error = reason
        log.warning("iTerm2 refused the API connection: %s", reason)
        await self.broadcast(protocol.ITERM_AUTH_FAILED, {"reason": reason})

    async def _cookie_from_app(self) -> None:
        """Asks the app for a fresh cookie before each connection: iTerm2 cookies are single-use.
        The app answers with a cookie, with "not running", or with why iTerm2 refused, which raise
        what the osascript request would have. The daemon never asks iTerm2 itself instead: its
        osascript is what --cookies-from-app exists to keep from ghosting the Dock. A request an
        attached app leaves unanswered is made again, under a new id."""
        if not self.cookies_from_app:
            return
        while (reply := await self._request_cookie()) is None:
            log.warning("the app did not answer the iTerm2 cookie request; asking again")
        if reply.get("notRunning"):
            raise ItermUnavailable("iTerm2 not running")
        if error := reply.get("error"):
            raise ItermAuthFailed(error)
        self.apply_cookie(reply["cookie"], reply["key"])

    async def _request_cookie(self) -> dict[str, Any] | None:
        """One cookie request: the app's answer, or None once apps have been attached for
        `cookie_wait_seconds` without giving one. Time with no app attached does not count: the
        daemon starts before the app attaches, and a restarting app takes a while to come back."""
        answer: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        request = (next(self._cookie_ids), answer)
        self._cookie_request = request
        try:
            # The snapshot carries the request too, for an app that attaches after this broadcast.
            await self.broadcast(protocol.ITERM_COOKIE_REQUESTED, {"requestId": request[0]})
            step, waited = min(COOKIE_CHECK_SECONDS, self.cookie_wait_seconds), 0.0
            while waited < self.cookie_wait_seconds:
                attached = self.client_count() > 0
                if (await asyncio.wait({answer}, timeout=step))[0]:
                    return answer.result()
                if attached and self.client_count() > 0:
                    waited += step
            return None
        finally:
            # A newer request can hold the slot by now -- one from a reconnect loop that replaced
            # this one's -- and is not this one's to clear.
            if self._cookie_request is request:
                self._cookie_request = None

    def _retry_delay(self) -> float:
        if not self._auth_failures:
            return self.reconnect_seconds
        return min(self.reconnect_seconds * 2.0 ** (self._auth_failures - 1), self.auth_backoff_cap_seconds)

    async def _on_disconnect(self) -> None:
        if self._stopped:
            return
        self.version = None
        await self.broadcast(protocol.ITERM_DISCONNECTED, {})
        # Retried in a task of its own, so this callback returns while iTerm2 stays away: its
        # caller (the bridge's watcher, or a test's disconnect) awaits it.
        self._start_reconnect_loop()

    async def _reconnect_loop(self) -> None:
        # Launch iTerm2 once per loop run (i.e. once per disconnect, or once
        # for the initial startup-connect failure), on the first attempt that
        # finds it absent, then keep retrying at a fixed interval. A refused
        # cookie means iTerm2 is running: it is not launched, and the retries
        # back off (see `_retry_delay`).
        launched = False
        while True:
            try:
                if await self._try_connect():
                    return
                if not launched and not self._auth_failures:
                    launched = True
                    await self.launch_iterm()
            except Exception:  # noqa: BLE001 - nothing may end the loop while iTerm2 is away
                log.exception("reconnect attempt failed")
            await self.reconnect_sleep(self._retry_delay())
