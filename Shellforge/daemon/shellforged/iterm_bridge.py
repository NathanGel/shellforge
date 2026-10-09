# daemon/shellforged/iterm_bridge.py
"""Adapter over the official iterm2 library. Only this module imports iterm2."""
from __future__ import annotations
import asyncio
import contextlib
import functools
import json
import logging
import os
import plistlib
import subprocess
import threading
from collections.abc import Awaitable, Callable, Coroutine
from typing import Any, ParamSpec, Protocol, TypeVar

import iterm2

from .models import PROJECT_TAG, TASK_TAG, TITLE_TAG, Frame, RawSession
from .offload import run_detached

log = logging.getLogger(__name__)
VARIABLES = ("commandLine", "jobPid", "autoName", "path", f"user.{TASK_TAG}", f"user.{PROJECT_TAG}")
# How long one bridge call may wait on iTerm2. The library resolves a request only when its reply
# arrives, and pings nothing, so an iTerm2 that hangs would hold the caller -- and a tick holds
# the service's tick lock -- for good.
ITERM_CALL_SECONDS = 10.0
P = ParamSpec("P")
T = TypeVar("T")


class ItermUnavailable(Exception):
    pass


class _SessionGone(iterm2.rpc.RPCException):
    """iTerm2 answered SESSION_NOT_FOUND: the session closed after the hierarchy listed it. The
    only read failure that means a tab is gone rather than that reading it failed."""


# Statuses with which iTerm2 may refuse a read of several names at once, where one name at a time
# is still allowed.
_UNBATCHABLE = frozenset(iterm2.api_pb2.VariableResponse.Status.Value(name) for name in ("MULTI_GET_DISALLOWED", "INVALID_NAME"))


def _variable_values(response) -> list[Any]:
    """The decoded values of a variable response, the way `Session.async_get_variable` decodes one."""
    status = response.variable_response.status
    if status != iterm2.api_pb2.VariableResponse.Status.Value("OK"):
        name = iterm2.api_pb2.VariableResponse.Status.Name(status)
        raise (_SessionGone if name == "SESSION_NOT_FOUND" else iterm2.rpc.RPCException)(name)
    return [json.loads(value) for value in response.variable_response.values]


class ItermAuthFailed(ItermUnavailable):
    """iTerm2 is running but would not let the daemon in: the cookie request was refused, or the
    cookie presented was rejected. Retrying at the normal rate cannot fix it -- a person has to --
    so the service backs off and tells the app, instead of treating it as iTerm2 still starting."""


def request_cookie(runner_class: type | None = None) -> None:
    """Puts an API cookie in the environment for `iterm2.Connection`, the way
    `iterm2.auth.authenticate` does, but keeps the reason when iTerm2 refuses. The library swallows
    its `AuthenticationException`, and with it osascript's error, which is the only record of why.

    Built from the library's own pieces rather than a patch to them: `request_cookie_and_key`
    takes the runner class, so a factory that remembers its last runner is enough to read the
    error back afterwards."""
    if iterm2.auth.applescript_auth_disabled() or os.environ.get("ITERM2_COOKIE"):
        return
    # NSAppleScript belongs on the main thread; off it, the osascript runner does the same job.
    appkit = runner_class is None and iterm2.auth.gAppKitAvailable and threading.current_thread() is threading.main_thread()
    base = runner_class or (iterm2.auth.AppKitApplescriptRunner if appkit else iterm2.auth.CommandLineApplescriptRunner)
    runners: list = []

    def runner(script: str):
        runners.append(base(script))
        return runners[-1]

    background = iterm2.auth.LSBackgroundContextManager() if appkit else contextlib.nullcontext()
    try:
        with background:
            reply = iterm2.auth.request_cookie_and_key(False, None, runner)
    except iterm2.auth.AuthenticationException as exc:
        if str(exc) == "iTerm2 not running":
            raise ItermUnavailable(str(exc)) from exc
        raise ItermAuthFailed(_applescript_error(runners[-1]) or str(exc)) from exc
    except Exception as exc:  # noqa: BLE001 - the library's own error parsing raises on stderr it cannot match
        raise ItermAuthFailed((_applescript_error(runners[-1]) if runners else None) or f"cookie request failed: {exc}") from exc
    cookie, _, key = reply.partition(" ")
    if not cookie or not key:
        # Never echo the reply: half of a cookie is still a credential.
        raise ItermAuthFailed("iTerm2 answered the cookie request with something other than a cookie and key")
    os.environ["ITERM2_COOKIE"], os.environ["ITERM2_KEY"] = cookie, key


def _applescript_error(runner) -> str | None:
    """`execution error: Not authorized to send Apple events to iTerm2. (-1743)`, or osascript's raw
    stderr when the library's parser cannot split it into a message and a code."""
    try:
        reason, code = runner.get_error_reason(), runner.get_error()
    except Exception:  # noqa: BLE001 - the library's regexes return None on unexpected output
        reason = code = None
    if reason:
        return f"{reason} ({code})"
    return (getattr(runner, "_error", "") or "").strip() or None


ITERM_BUNDLE_ID = "com.googlecode.iterm2"
# Where iTerm2 is installed, short of asking Spotlight: its own download and Homebrew use the first.
_ITERM_BUNDLES = ("/Applications/iTerm.app", "~/Applications/iTerm.app")
# Found once per process. Only the location is kept: an update replaces the bundle in place, so its
# version is read again on every connect.
_located_bundle: str | None = None


def _locate_iterm() -> str | None:
    """iTerm2's bundle, where it is usually installed, else wherever Spotlight has it. Nothing here
    may start an AppleEvent client: macOS counts every process Shellforge starts as Shellforge, and an
    osascript -- even a Standard Additions lookup -- checked in with a Dock icon of its own on every
    connect. `mdfind` only queries the Spotlight index."""
    global _located_bundle
    if _located_bundle is not None and os.path.isdir(_located_bundle):
        return _located_bundle
    _located_bundle = next((path for path in map(os.path.expanduser, _ITERM_BUNDLES) if os.path.isdir(path)), None)
    if _located_bundle is None:
        try:
            out = subprocess.run(["mdfind", f"kMDItemCFBundleIdentifier == '{ITERM_BUNDLE_ID}'"],
                                 capture_output=True, text=True, timeout=5, check=True).stdout
        except (OSError, subprocess.SubprocessError):
            return None
        _located_bundle = next((line.strip() for line in out.splitlines() if line.strip()), None)
    return _located_bundle


def installed_version() -> str | None:
    """iTerm2's marketing version, e.g. `3.7.2`, from its bundle. The API has no app-scope variable
    for it: asking for `version` answers None."""
    bundle = _locate_iterm()
    if bundle is None:
        return None
    try:
        with open(os.path.join(bundle, "Contents", "Info.plist"), "rb") as f:
            version = plistlib.load(f).get("CFBundleShortVersionString")
    except (OSError, plistlib.InvalidFileException):
        return None
    return str(version) if version else None


async def _call(coro: Awaitable[T]) -> T:
    try:
        async with asyncio.timeout(ITERM_CALL_SECONDS):
            return await coro
    except TimeoutError as exc:
        raise ItermUnavailable(f"iTerm2 did not answer within {ITERM_CALL_SECONDS:g}s") from exc


def _bounded(method: Callable[P, Awaitable[T]]) -> Callable[P, Coroutine[Any, Any, T]]:
    """A port method under `_call`'s deadline, however many requests it makes."""
    @functools.wraps(method)
    async def bounded(*args: P.args, **kwargs: P.kwargs) -> T:
        return await _call(method(*args, **kwargs))
    return bounded


def _fail_pending_requests(conn: iterm2.Connection) -> None:
    """Fails the requests still waiting on a closed connection. The library parks each one in
    `Connection.__receivers` until a reply matches it, and its reader stops when the socket dies
    without failing them, so each would otherwise wait out `ITERM_CALL_SECONDS`. That list is
    private: verified against iterm2 2.23 (pinned), and left alone if it has moved."""
    with contextlib.suppress(AttributeError, TypeError, ValueError):
        receivers = conn._Connection__receivers  # type: ignore[attr-defined]
        for _match, future in receivers:
            if not future.done():
                future.set_exception(ItermUnavailable("iTerm2 closed the connection"))
        receivers.clear()


def _drop_notification_handlers(bridge: object) -> None:
    """Removes every notification handler bound to `bridge` or to an iterm2 App, locally.

    The library keeps its handlers in process-wide lists that outlive the connection they were
    subscribed on: each connect added the bridge's three again and a new App's five, so a window
    focus was reported once per connection so far, and a dead App's handler, refreshing over its
    closed socket, raised and cut short the rest of its list. `async_unsubscribe` would ask iTerm2
    over that dead socket; iTerm2 forgets a closed connection's subscriptions by itself. Matched by
    owner rather than by the subscribe tokens, which miss what a failed setup leaves: the library
    registers a handler before its request and keeps it if the request raises, and an App whose
    construction failed is never returned at all. `_get_handlers` is private: verified against
    iterm2 2.23 (pinned)."""
    def ours(handler: object) -> bool:
        owner = getattr(handler, "__self__", None)
        return owner is bridge or isinstance(owner, iterm2.app.App)

    with contextlib.suppress(AttributeError):
        handlers = iterm2.notifications._get_handlers()
        for key, registered in list(handlers.items()):
            # A new list, not an edit in place: a dispatch may be iterating the old one.
            if kept := [handler for handler in registered if not ours(handler)]:
                handlers[key] = kept
            else:
                del handlers[key]


def _drop_app_refresh_handlers(app: iterm2.App) -> None:
    """Removes the App's own handlers that refresh the hierarchy, so only the bridge refreshes it,
    under `_refresh_lock`: the App refreshes itself on every new and terminated session, and when
    focus moves to a tab or session it does not know yet. `App.async_refresh` returns at once, the
    tree untouched, while another is in flight, so a Cmd+T whose focus change is dispatched before
    its new-session notification would hand `session_info` the tree from before the tab, and the tab
    would never be tagged. Each also cost three requests. What keeps the cached hierarchy `_found`
    reads current is then the bridge's own refreshes, each under the lock: the `session_info` and
    tick a new session prompts, the tick a terminated one prompts, the service's poll, and `_found`'s
    own refresh on a miss. The layout-change handler stays, as it costs no request: it edits the tree
    from the notification itself. The focus the App tracks between refreshes goes stale, and nothing
    here reads it: `_placed` reads the focus a refresh has just fetched. `_get_handlers` and
    `_async_focus_change` are private: verified against iterm2 2.23 (pinned), and nothing is removed
    if either has moved."""
    with contextlib.suppress(AttributeError):
        refreshing = {app.async_refresh, app._async_focus_change}
        handlers = iterm2.notifications._get_handlers()
        for key, registered in list(handlers.items()):
            # A new list, not an edit in place: a dispatch may be iterating the old one.
            if kept := [handler for handler in registered if handler not in refreshing]:
                handlers[key] = kept
            else:
                del handlers[key]


async def _get_app(conn: iterm2.Connection) -> iterm2.App:
    app = await iterm2.async_get_app(conn)
    if app is None:
        raise ItermUnavailable("iTerm2 returned no app")
    return app


def _iterm_frame(frame: Frame) -> iterm2.Frame:
    # Typed as int, but iTerm2 receives the frame as JSON: a fractional point is kept, not truncated.
    return iterm2.Frame(iterm2.Point(frame.x, frame.y), iterm2.Size(frame.w, frame.h))  # type: ignore[arg-type]


async def _close(conn: iterm2.Connection) -> None:
    with contextlib.suppress(Exception):
        if conn.websocket is not None:
            await conn.websocket.close()


def use_cookie(cookie: str, key: str) -> None:
    """A cookie and key the app fetched from iTerm2, for the next `iterm2.Connection`. With one in
    the environment, `request_cookie` asks iTerm2 nothing itself, so no osascript runs."""
    os.environ["ITERM2_COOKIE"], os.environ["ITERM2_KEY"] = cookie, key


def _forget_cookie() -> None:
    os.environ.pop("ITERM2_COOKIE", None)
    os.environ.pop("ITERM2_KEY", None)


def _is_auth_rejection(exc: BaseException) -> bool:
    """HTTP 401 on the websocket upgrade. websockets 17 raises `InvalidStatus`, carrying a response;
    the legacy `InvalidStatusCode` carried the code directly."""
    response = getattr(exc, "response", None)
    return getattr(response, "status_code", getattr(exc, "status_code", None)) == 401


class ItermPort(Protocol):
    async def connect(self) -> str | None: ...
    def is_connected(self) -> bool: ...
    async def close(self) -> None: ...
    async def create_window(self, cwd: str, title: str, tags: dict[str, str], frame: Frame) -> tuple[str, str]: ...
    async def create_tab(self, window_id: str, tags: dict[str, str], cwd: str | None = None) -> str: ...
    async def activate_window(self, window_id: str) -> None: ...
    async def set_frame(self, window_id: str, frame: Frame) -> None: ...
    async def close_window(self, window_id: str) -> None: ...
    async def send_text(self, session_id: str, text: str) -> None: ...
    async def set_session_tags(self, session_id: str, tags: dict[str, str]) -> None: ...
    async def set_session_titles(self, titles: dict[str, str]) -> list[str]: ...
    async def set_shellforge_background(self, session_ids: list[str], enabled: bool) -> None: ...
    async def snapshot(self) -> list[RawSession]: ...
    async def session_info(self, session_id: str) -> RawSession | None: ...
    def on_new_session(self, cb: Callable[[str], Awaitable[None]]) -> None: ...
    def on_session_closed(self, cb: Callable[[str], Awaitable[None]]) -> None: ...
    def on_window_activated(self, cb: Callable[[str], Awaitable[None]]) -> None: ...
    def on_disconnect(self, cb: Callable[[], Awaitable[None]]) -> None: ...


# A session where the hierarchy has it: its window, its tab's index, and whether it is that window's
# current session.
_Placement = tuple[iterm2.Session, str, int, bool]


class ItermBridge:
    def __init__(self) -> None:
        self._conn: iterm2.Connection | None = None
        self._new_cbs: list[Callable[[str], Awaitable[None]]] = []
        self._closed_cbs: list[Callable[[str], Awaitable[None]]] = []
        self._activated_cbs: list[Callable[[str], Awaitable[None]]] = []
        self._disc_cbs: list[Callable[[], Awaitable[None]]] = []
        self._watch_task: asyncio.Task | None = None
        self._refresh_lock = asyncio.Lock()
        # The hierarchy as `_app` last fetched it, so a command that needs one window or session by
        # id looks there first. It is as fresh as the bridge's last refresh: a new or terminated
        # session prompts one, the service's poll makes one every two seconds, and `_found` makes
        # one when it misses (see `_drop_app_refresh_handlers`).
        self._tree: iterm2.App | None = None
        # Whether iTerm2 takes a session's variables in one request; off for good after a refusal.
        self._batched_reads = True
        # The original profile is retained only for a live session. The Interface toggle changes
        # sessions, not a user-owned iTerm2 profile; holding the full pre-change profile is what
        # lets turning it off restore the terminal's own colours.
        self._background_restore_profiles: dict[str, iterm2.profile.Profile] = {}

    # -- connection -------------------------------------------------------
    async def connect(self) -> str | None:
        # Asked for here, not by the library, so a refusal comes back with its reason. With a
        # cookie already in the environment the library then makes no AppleScript request itself.
        # osascript can take seconds, or wait on a permission dialog: keep it off the event loop.
        await run_detached(request_cookie)
        try:
            conn = await iterm2.Connection.async_create()
        except Exception as exc:  # the library raises several types here
            if _is_auth_rejection(exc):
                # iterm2 2.23 only drops a rejected cookie on the legacy `InvalidStatusCode`, which
                # websockets 17 no longer raises. Left in place, it would be presented forever.
                _forget_cookie()
                raise ItermAuthFailed(f"iTerm2 rejected the API cookie ({exc})") from exc
            raise ItermUnavailable(str(exc)) from exc
        # Spent: iTerm2 cookies are single-use, and one left in the environment would be presented
        # on the next connect, refused with a 401, and reported as a refusal.
        _forget_cookie()
        self._forget_app()
        # Published before subscribing: a notification can arrive during setup (a Cmd+T), and its
        # handler needs the connection. A failed setup takes it back, so the bridge is disconnected.
        self._conn = conn
        try:
            await _call(self._subscribe(conn))
        except Exception as exc:  # noqa: BLE001 - a half-open connection is no connection
            if self._conn is conn:
                self._conn = None
            self._forget_app()
            await _close(conn)
            raise ItermUnavailable(f"iTerm2 connection setup failed: {exc}") from exc
        # `async_create()` already runs the library's own reader task, and a second
        # `_async_dispatch_forever` would race it for `recv()` (verified live), so disconnection is
        # detected via `websocket.wait_closed()` instead. The watcher captures `conn` so an old
        # socket closing cannot clear a newer connection, and is strongly referenced so it cannot
        # be garbage-collected mid-await.
        if self._watch_task is not None:
            self._watch_task.cancel()
        self._watch_task = asyncio.get_running_loop().create_task(self._watch(conn))
        return await run_detached(installed_version)

    def _forget_app(self) -> None:
        self._tree = None
        # The library's App singleton is bound to the connection that built it, and only
        # `Connection.run()`'s disconnect callbacks reset it -- which this daemon never uses.
        iterm2.app.invalidate_app()
        _drop_notification_handlers(self)

    async def _subscribe(self, conn: iterm2.Connection) -> None:
        await iterm2.notifications.async_subscribe_to_new_session_notification(conn, self._on_new)
        await iterm2.notifications.async_subscribe_to_terminate_session_notification(conn, self._on_closed)
        await iterm2.notifications.async_subscribe_to_focus_change_notification(conn, self._on_focus)
        # Under the lock `_app` takes: a notification handler asking for the app meanwhile would
        # otherwise build a second one.
        async with self._refresh_lock:
            _drop_app_refresh_handlers(await _get_app(conn))

    def is_connected(self) -> bool:
        return self._conn is not None

    async def close(self) -> None:
        """Stops watching the connection, then closes it: on shutdown the socket closing is no
        disconnect, and the reconnect loop one would start could launch iTerm2."""
        if (task := self._watch_task) is not None:
            self._watch_task = None
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        if (conn := self._conn) is not None:
            self._conn = None
            self._forget_app()
            await _close(conn)

    async def _watch(self, conn: iterm2.Connection) -> None:
        try:
            # A connection without a websocket is as good as a closed one.
            if conn.websocket is not None:
                await conn.websocket.wait_closed()
        except Exception:  # noqa: BLE001 - treat any failure here as a disconnect too
            pass
        _fail_pending_requests(conn)
        if self._conn is conn:
            self._conn = None
            self._forget_app()
            for cb in self._disc_cbs:
                await cb()

    async def _on_new(self, _conn, notif) -> None:
        for cb in self._new_cbs:
            await cb(notif.session_id)

    async def _on_closed(self, _conn, notif) -> None:
        self._background_restore_profiles.pop(notif.session_id, None)
        for cb in self._closed_cbs:
            await cb(notif.session_id)

    async def _on_focus(self, _conn, notif) -> None:
        # iTerm2 emits several focus changes (application, tab and pane as well as window).
        # A window event means it became key, or remains the current terminal while another iTerm2
        # panel has focus. Both should keep the matching sidebar row selected; a resigned-key event
        # deliberately does not clear it because the sidebar remains useful while another app is
        # frontmost.
        if not notif.HasField("window"):
            return
        resigned = iterm2.api_pb2.FocusChangedNotification.Window.TERMINAL_WINDOW_RESIGNED_KEY
        if notif.window.window_status == resigned:
            return
        for cb in self._activated_cbs:
            await cb(notif.window.window_id)

    def on_new_session(self, cb): self._new_cbs.append(cb)
    def on_session_closed(self, cb): self._closed_cbs.append(cb)
    def on_window_activated(self, cb): self._activated_cbs.append(cb)
    def on_disconnect(self, cb): self._disc_cbs.append(cb)

    # -- helpers ----------------------------------------------------------
    def _require(self) -> iterm2.Connection:
        if self._conn is None:
            raise ItermUnavailable("not connected")
        return self._conn

    async def _app(self) -> iterm2.App:
        # Every call refreshes the whole hierarchy over the socket (three requests): a batch fetches
        # it once, and a command that needs one object by id asks `_found` instead. One at
        # a time: `App.async_refresh` returns at once, the tree untouched, while another is in
        # flight, so a new-session handler overlapping a tick would read a tree without its session.
        async with self._refresh_lock:
            self._tree = await _get_app(self._require())
            return self._tree

    async def _found(self, find: Callable[[iterm2.App], T | None]) -> T | None:
        """What `find` gets from the hierarchy as last fetched, and only when it finds nothing there
        the hierarchy as it is now: the window or tab it wants may be one iTerm2 has not announced yet."""
        self._require()
        if (tree := self._tree) is not None and (found := find(tree)) is not None:
            return found
        return find(await self._app())

    async def _window(self, window_id: str, fresh: bool = False) -> iterm2.Window:
        """With `fresh`, the window as the hierarchy has it now rather than as last fetched."""
        if fresh:
            w = (await self._app()).get_window_by_id(window_id)
        else:
            w = await self._found(lambda app: app.get_window_by_id(window_id))
        if w is None:
            raise KeyError(window_id)
        return w

    async def _session(self, session_id: str, app: iterm2.App | None = None) -> iterm2.Session:
        """With `app`, the session in that hierarchy: a batch has fetched it already."""
        s = app.get_session_by_id(session_id) if app is not None else await self._found(lambda tree: tree.get_session_by_id(session_id))
        if s is None:
            raise KeyError(session_id)
        return s

    @staticmethod
    async def _tag(session: iterm2.Session, tags: dict[str, str]) -> None:
        for k, v in tags.items():
            await session.async_set_variable(f"user.{k}", v)

    # -- commands ---------------------------------------------------------
    # Making a window or tab and setting it up are bounded separately. Once iTerm2 has made it, its
    # ids are returned whatever the setup meets: an error would make the app retry, and a retry
    # opens a second one.
    async def create_window(self, cwd: str, title: str, tags: dict[str, str], frame: Frame) -> tuple[str, str]:
        win, session = await _call(self._new_window(cwd, title))
        try:
            await _call(self._set_up_window(win, session, tags, frame))
        except Exception:  # noqa: BLE001 - the window exists either way
            log.exception("iTerm2 made window %s but setting it up failed", win.window_id)
        return win.window_id, session.session_id

    async def _new_window(self, cwd: str, title: str) -> tuple[iterm2.Window, iterm2.Session]:
        prof = iterm2.LocalWriteOnlyProfile()
        prof.set_initial_directory_mode(iterm2.InitialWorkingDirectory.INITIAL_WORKING_DIRECTORY_CUSTOM)
        prof.set_custom_directory(cwd)
        prof.set_name(f"Shellforge · {title}")
        return await self._make(None, prof)

    async def _set_up_window(self, win: iterm2.Window, session: iterm2.Session, tags: dict[str, str], frame: Frame) -> None:
        await self._tag(session, tags)
        await win.async_set_frame(_iterm_frame(frame))
        await win.async_activate()

    async def create_tab(self, window_id: str, tags: dict[str, str], cwd: str | None = None) -> str:
        session = await _call(self._new_tab(window_id, cwd))
        try:
            await _call(self._tag(session, tags))
        except Exception:  # noqa: BLE001 - the tab exists either way
            log.exception("iTerm2 made tab %s but tagging it failed", session.session_id)
        return session.session_id

    async def _new_tab(self, window_id: str, cwd: str | None) -> iterm2.Session:
        # With no anchor known yet, the window's first tab gives the directory, so it is read from the
        # hierarchy as it is now: the cached one can be a tick old, its first tab closed or dragged away since.
        win = await self._window(window_id, fresh=cwd is None)
        if cwd is None and (first := win.tabs[0].current_session if win.tabs else None):
            cwd = await first.async_get_variable("path")
        prof = iterm2.LocalWriteOnlyProfile()
        prof.set_initial_directory_mode(iterm2.InitialWorkingDirectory.INITIAL_WORKING_DIRECTORY_CUSTOM)
        prof.set_custom_directory(cwd or os.path.expanduser("~"))
        return (await self._make(window_id, prof))[1]

    async def _make(self, window_id: str | None, prof: iterm2.LocalWriteOnlyProfile) -> tuple[iterm2.Window, iterm2.Session]:
        """A new tab in `window_id`, or a new window when None, and its session. The request the
        library's `Window.async_create` and `async_create_tab` make, but the new session is found
        through `_app`: theirs refresh outside `_refresh_lock`, and one that overlaps a tick's
        returns the tree from before the window or tab existed, which they report as none made."""
        answer = await iterm2.rpc.async_create_tab(self._require(), window=window_id, profile_customizations=prof.values)
        reply = answer.create_tab_response
        if reply.status != iterm2.api_pb2.CreateTabResponse.Status.Value("OK"):
            refused = iterm2.window.CreateWindowException if window_id is None else iterm2.window.CreateTabException
            raise refused(iterm2.api_pb2.CreateTabResponse.Status.Name(reply.status))
        app = await self._app()
        win, session = app.get_window_by_id(reply.window_id), app.get_session_by_id(reply.session_id)
        if win is None or session is None:
            # Its shell ended at once, or iTerm2 closed it already: there is nothing to set up.
            raise ItermUnavailable(f"iTerm2 created a {'window' if window_id is None else 'tab'} that closed at once")
        return win, session

    @_bounded
    async def activate_window(self, window_id: str) -> None:
        await (await self._window(window_id)).async_activate()

    @_bounded
    async def set_frame(self, window_id: str, frame: Frame) -> None:
        await (await self._window(window_id)).async_set_frame(_iterm_frame(frame))

    @_bounded
    async def close_window(self, window_id: str) -> None:
        await (await self._window(window_id)).async_close(force=True)

    @_bounded
    async def send_text(self, session_id: str, text: str) -> None:
        await (await self._session(session_id)).async_send_text(text)

    @_bounded
    async def set_session_tags(self, session_id: str, tags: dict[str, str]) -> None:
        await self._tag(await self._session(session_id), tags)

    @_bounded
    async def set_session_titles(self, titles: dict[str, str]) -> list[str]:
        """Give tabs a literal title without disturbing the session's process title, and say which
        sessions got one; a session closed in the meantime is skipped.

        Shellforge reads ``autoName`` to infer Codex activity, so changing the session name would
        erase a useful signal. A tab override is independent, and iTerm2 also uses the active
        tab's title as the window title when the window has no separate override. Put the value in
        a variable first because ``async_set_title`` accepts an interpolated string.
        """
        app = await self._app()
        applied: list[str] = []
        for session_id, title in titles.items():
            try:
                tab = (await self._session(session_id, app)).tab
            except KeyError:
                continue
            if tab is None:
                continue
            await tab.async_set_variable(f"user.{TITLE_TAG}", title)
            await tab.async_set_title(f"\\(user.{TITLE_TAG})")
            applied.append(session_id)
        return applied

    @_bounded
    async def set_shellforge_background(self, session_ids: list[str], enabled: bool) -> None:
        """Match or restore the background for the supplied Shellforge sessions.

        Session-local profile changes are deliberately used here. Updating an iTerm2 profile
        would also recolour terminals Shellforge does not own, and would persist after the preference
        was switched back off.
        """
        # Looked up in the cached hierarchy; the first session it lacks fetches a fresh one, which
        # the rest, found or not, are then looked up in: a tab closed meanwhile is not looked for
        # again by each.
        app, fresh = self._tree, False
        for session_id in session_ids:
            try:
                if (session := app.get_session_by_id(session_id) if app is not None else None) is None and not fresh:
                    app, fresh = await self._app(), True
                    session = app.get_session_by_id(session_id)
                if session is None:
                    raise KeyError(session_id)
                if enabled:
                    if session_id not in self._background_restore_profiles:
                        self._background_restore_profiles[session_id] = await session.async_get_profile()
                    change = iterm2.LocalWriteOnlyProfile()
                    color = iterm2.Color(30, 30, 30)
                    # Populate every iTerm2 profile slot so the requested #1E1E1E background
                    # stays fixed regardless of iTerm2's own appearance settings.
                    change.set_background_color(color)
                    change.set_background_color_light(color)
                    change.set_background_color_dark(color)
                    await session.async_set_profile_properties(change)
                elif original := self._background_restore_profiles.pop(session_id, None):
                    await session.async_set_profile(original)
            except KeyError:
                # A tab can be closed between the registry snapshot and this request. It no
                # longer needs a profile update, and stale restore data should not accumulate.
                self._background_restore_profiles.pop(session_id, None)

    async def _read_variables(self, session: iterm2.Session) -> list[Any]:
        """Every one of `VARIABLES` for a session, in one request: `Session.async_get_variable`
        asks for a single name, and a tick would make six requests per tab. Should iTerm2 refuse
        several names at once, or answer them with fewer values than names -- which leaves no way
        to tell which value is whose -- they are read one at a time from then on, as that method
        does. Raises `_SessionGone` for a session that has closed, RPCException for any other
        refusal."""
        if self._batched_reads:
            response = await iterm2.rpc.async_variable(session.connection, session.session_id, [], list(VARIABLES))
            answer = response.variable_response
            if answer.status in _UNBATCHABLE:
                why = iterm2.api_pb2.VariableResponse.Status.Name(answer.status)
            elif answer.status == iterm2.api_pb2.VariableResponse.Status.Value("OK") and len(answer.values) != len(VARIABLES):
                why = f"{len(answer.values)} values for {len(VARIABLES)} names"
            else:
                return _variable_values(response)
            log.info("iTerm2 cannot read variables in one request (%s); reading one name at a time", why)
            self._batched_reads = False
        responses = await asyncio.gather(*(iterm2.rpc.async_variable(session.connection, session.session_id, [], [name])
                                           for name in VARIABLES))
        return [_variable_values(response)[0] for response in responses]

    @staticmethod
    def _placed(app: iterm2.App) -> list[_Placement]:
        placed: list[_Placement] = []
        for win in app.terminal_windows:
            current = win.current_tab.current_session if win.current_tab else None
            current_id = current.session_id if current else None
            for tab_index, tab in enumerate(win.tabs):
                placed.extend((s, win.window_id, tab_index, s.session_id == current_id) for s in tab.sessions)
        return placed

    @staticmethod
    def _raw_session(placement: _Placement, values: list[Any]) -> RawSession:
        s, window_id, tab_index, active = placement
        cmd, pid, title, path, task, project = values
        user_vars = {k: v for k, v in ((TASK_TAG, task), (PROJECT_TAG, project)) if v}
        return RawSession(s.session_id, window_id, tab_index, cmd, int(pid) if pid else None, title or "", path or "", user_vars,
                          active=active)

    @_bounded
    async def session_info(self, session_id: str) -> RawSession | None:
        """One session as `snapshot` would report it, for a new-session notification, which needs
        no other. None when iTerm2 does not have it: not listed yet, or closed already."""
        placement = next((p for p in self._placed(await self._app()) if p[0].session_id == session_id), None)
        if placement is None:
            return None
        try:
            return self._raw_session(placement, await self._read_variables(placement[0]))
        except _SessionGone:
            return None

    @_bounded
    async def snapshot(self) -> list[RawSession]:
        placed = self._placed(await self._app())
        # Every session's request at once, rather than one round trip after another.
        results = await asyncio.gather(*(self._read_variables(s) for s, *_ in placed), return_exceptions=True)
        # A session closed between the hierarchy and its reads is left out, and seen as closed.
        # Anything else -- another refusal, the connection lost -- fails the snapshot, and so does
        # one in which no session could be read, which would report every tab closed.
        failed = [r for r in results if isinstance(r, BaseException)]
        if fatal := next((e for e in failed if not isinstance(e, _SessionGone)), None):
            raise fatal
        if failed and len(failed) == len(placed):
            raise failed[0]
        return [self._raw_session(placement, values) for placement, values in zip(placed, results, strict=True)
                if not isinstance(values, BaseException)]
