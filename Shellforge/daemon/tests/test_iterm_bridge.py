# daemon/tests/test_iterm_bridge.py
"""Unit tests for ItermBridge against the real `iterm2` module's classes with
their I/O-touching entry points monkeypatched, rather than a live iTerm2."""
from __future__ import annotations
import asyncio
import contextlib
import json
import plistlib
import subprocess
from collections.abc import Awaitable, Set as AbstractSet
from typing import TypeVar

import iterm2
import pytest
import websockets
from websockets.datastructures import Headers
from websockets.http11 import Response

from shellforged import iterm_bridge
from shellforged.iterm_bridge import ItermAuthFailed, ItermBridge, ItermUnavailable, VARIABLES, request_cookie
from shellforged.models import Frame

T = TypeVar("T")


class _FakeSocket:
    def __init__(self):
        self._closed = asyncio.Event()

    async def wait_closed(self):
        await self._closed.wait()

    async def close(self):
        self._closed.set()

    @property
    def closed(self) -> bool:
        return self._closed.is_set()


class _FakeConn:
    def __init__(self):
        self.websocket = _FakeSocket()


def _bundle(tmp_path, info: dict) -> str:
    contents = tmp_path / "iTerm.app" / "Contents"
    contents.mkdir(parents=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    return str(tmp_path / "iTerm.app")


def _patch_connection(monkeypatch, tmp_path) -> list[_FakeConn]:
    conns: list[_FakeConn] = []
    # The real cookie request runs osascript, and the bundle lookup can run mdfind.
    monkeypatch.setattr(iterm_bridge, "request_cookie", lambda: None)
    bundle = _bundle(tmp_path, {"CFBundleShortVersionString": "3.7.2"})
    monkeypatch.setattr(iterm_bridge, "_locate_iterm", lambda: bundle)

    async def fake_create():
        conn = _FakeConn()
        conns.append(conn)
        return conn

    async def fake_subscribe(_conn, _cb):
        return None

    monkeypatch.setattr(iterm2.Connection, "async_create", staticmethod(fake_create))
    for name in ("new_session", "terminate_session", "focus_change"):
        monkeypatch.setattr(iterm2.notifications, f"async_subscribe_to_{name}_notification", fake_subscribe)
    return conns


@pytest.fixture
def patched_connect(monkeypatch, tmp_path):
    conns = _patch_connection(monkeypatch, tmp_path)

    async def fake_get_app(_conn, **_kw):
        class FakeApp:
            async def async_get_variable(self, _name):
                return None  # iTerm2 has no app-scope `version` variable
        return FakeApp()

    monkeypatch.setattr(iterm2, "async_get_app", fake_get_app)
    return conns


@pytest.fixture
def real_app_singleton(monkeypatch, tmp_path):
    """The library's own `async_get_app`, with only `App.async_construct` stubbed: the singleton
    it keeps is bound to the connection that built it, and refreshing it talks over that
    connection -- which fails once that socket is gone."""
    conns = _patch_connection(monkeypatch, tmp_path)

    class BoundApp:
        def __init__(self, connection):
            self.connection = connection

        async def async_refresh(self):
            if self.connection.websocket.closed:
                raise ConnectionError("refresh over a closed connection")

        async def async_get_variable(self, _name):
            return None

    async def construct(connection):
        return BoundApp(connection)

    monkeypatch.setattr(iterm2.app.App, "async_construct", staticmethod(construct))
    monkeypatch.setattr(iterm2.app.App, "instance", None)
    return conns


async def test_connect_reports_the_version_from_iterms_bundle(patched_connect):
    assert await ItermBridge().connect() == "3.7.2"


async def test_connect_reports_no_version_when_iterms_bundle_cannot_be_found(patched_connect, monkeypatch):
    monkeypatch.setattr(iterm_bridge, "_locate_iterm", lambda: None)
    assert await ItermBridge().connect() is None


def test_a_bundle_without_a_version_reports_none(tmp_path, monkeypatch):
    bundle = _bundle(tmp_path, {"CFBundleIdentifier": "com.googlecode.iterm2"})
    monkeypatch.setattr(iterm_bridge, "_locate_iterm", lambda: bundle)
    assert iterm_bridge.installed_version() is None


def test_an_unreadable_bundle_reports_none(tmp_path, monkeypatch):
    monkeypatch.setattr(iterm_bridge, "_locate_iterm", lambda: str(tmp_path / "Missing.app"))
    assert iterm_bridge.installed_version() is None


@pytest.fixture
def bundle_lookup(monkeypatch, tmp_path):
    """The real `_locate_iterm` over a fake filesystem and process runner: `bundles` stands in for
    /Applications, and `spotlight` is what `mdfind` prints. Every command run is recorded."""
    class Lookup:
        def __init__(self):
            self.bundles: list[str] = []
            self.spotlight = ""
            self.commands: list[list[str]] = []

    lookup = Lookup()
    monkeypatch.setattr(iterm_bridge, "_located_bundle", None)
    monkeypatch.setattr(iterm_bridge, "_ITERM_BUNDLES", lookup.bundles)

    def run(argv, **_kw):
        lookup.commands.append(argv)
        if argv[0] != "mdfind":
            raise AssertionError(f"the version lookup ran {argv[0]}")
        return subprocess.CompletedProcess(argv, 0, lookup.spotlight, "")

    monkeypatch.setattr(iterm_bridge.subprocess, "run", run)
    return lookup


def test_iterm_in_applications_is_found_without_running_anything(bundle_lookup, tmp_path):
    bundle = _bundle(tmp_path, {"CFBundleShortVersionString": "3.7.2"})
    bundle_lookup.bundles += [str(tmp_path / "Nowhere.app"), bundle]
    assert iterm_bridge.installed_version() == "3.7.2"
    assert bundle_lookup.commands == []


def test_iterm_elsewhere_is_found_through_spotlight_not_osascript(bundle_lookup, tmp_path):
    bundle = _bundle(tmp_path, {"CFBundleShortVersionString": "3.7.3"})
    bundle_lookup.spotlight = f"{bundle}\n/Volumes/Backup/iTerm.app\n"
    assert iterm_bridge.installed_version() == "3.7.3"
    assert bundle_lookup.commands == [["mdfind", "kMDItemCFBundleIdentifier == 'com.googlecode.iterm2'"]]


def test_the_bundle_is_located_once_per_process(bundle_lookup, tmp_path):
    bundle_lookup.spotlight = _bundle(tmp_path, {"CFBundleShortVersionString": "3.7.3"})
    iterm_bridge.installed_version()
    iterm_bridge.installed_version()
    assert len(bundle_lookup.commands) == 1


def test_no_iterm_anywhere_reports_no_version(bundle_lookup):
    assert iterm_bridge.installed_version() is None


async def test_watch_task_is_kept_alive_and_cancelled_on_reconnect(patched_connect):
    bridge = ItermBridge()
    await bridge.connect()
    first_watch = bridge._watch_task
    assert first_watch is not None and not first_watch.done()

    await bridge.connect()
    second_watch = bridge._watch_task
    assert second_watch is not None and second_watch is not first_watch

    await asyncio.sleep(0)  # let the cancellation propagate through _watch
    assert first_watch.cancelled() or first_watch.done()


async def test_closing_stops_watching_before_it_closes_the_socket(patched_connect):
    bridge = ItermBridge()
    disconnects: list[int] = []

    async def disconnected():
        disconnects.append(1)

    bridge.on_disconnect(disconnected)
    await bridge.connect()
    watch = bridge._watch_task
    await bridge.close()
    await asyncio.sleep(0)
    assert watch is not None and watch.cancelled()
    assert patched_connect[0].websocket.closed and not bridge.is_connected()
    assert disconnects == [], "a close on shutdown is not a disconnect to reconnect from"


async def test_reconnect_after_the_socket_closes_binds_the_app_to_the_new_connection(real_app_singleton):
    conns = real_app_singleton
    bridge = ItermBridge()
    await bridge.connect()
    await conns[0].websocket.close()
    for _ in range(3):
        await asyncio.sleep(0)  # let _watch observe the close
    assert not bridge.is_connected()

    assert await bridge.connect() == "3.7.2"
    assert (await bridge._app()).connection is conns[1]


async def test_a_second_connect_does_not_reuse_the_first_connections_app(real_app_singleton):
    conns = real_app_singleton
    bridge = ItermBridge()
    await bridge.connect()
    await bridge.connect()
    assert (await bridge._app()).connection is conns[1]


async def test_a_refresh_during_setup_waits_for_the_app_setup_builds(real_app_singleton, monkeypatch):
    """A new-session handler can ask for the app while setup is still building it; two refreshes
    at once would each build one, and the library keeps whichever finishes last."""
    built: list[object] = []
    gate = asyncio.Event()
    construct = iterm2.app.App.async_construct

    async def slow_construct(connection):
        built.append(connection)
        await gate.wait()
        return await construct(connection)

    monkeypatch.setattr(iterm2.app.App, "async_construct", staticmethod(slow_construct))
    bridge = ItermBridge()
    connecting = asyncio.create_task(bridge.connect())
    while not built:
        await asyncio.sleep(0)
    handler = asyncio.create_task(bridge._app())
    for _ in range(3):
        await asyncio.sleep(0)
    gate.set()
    await asyncio.gather(connecting, handler)
    assert len(built) == 1


async def test_a_notification_during_setup_finds_the_connection(patched_connect, monkeypatch):
    """iTerm2 can deliver a new-session notification (a Cmd+T) while the version fetch is still in
    flight; its handler asks the bridge for the connection, which must already be there."""
    bridge = ItermBridge()
    seen: list[bool] = []
    original = iterm2.notifications.async_subscribe_to_focus_change_notification

    async def subscribe(conn, cb):
        seen.append(bridge.is_connected() and bridge._require() is conn)
        return await original(conn, cb)

    monkeypatch.setattr(iterm2.notifications, "async_subscribe_to_focus_change_notification", subscribe)
    await bridge.connect()
    assert seen == [True]


async def test_a_failed_setup_leaves_the_bridge_disconnected_and_closes_the_socket(patched_connect, monkeypatch):
    async def refused(_conn, _cb):
        raise RuntimeError("subscription refused")

    monkeypatch.setattr(iterm2.notifications, "async_subscribe_to_focus_change_notification", refused)
    bridge = ItermBridge()
    with pytest.raises(ItermUnavailable):
        await bridge.connect()
    assert not bridge.is_connected()
    assert patched_connect[0].websocket.closed


class _CountingApp:
    """Stands in for `iterm2.async_get_app`, which refreshes the whole hierarchy on every call."""
    def __init__(self, sessions):
        self.sessions, self.fetches = sessions, 0

    async def get(self, _conn):
        self.fetches += 1
        return self

    def get_session_by_id(self, session_id):
        return self.sessions.get(session_id)


class _TitledTab:
    def __init__(self):
        self.variables, self.formats = [], []

    async def async_set_variable(self, name, value):
        self.variables.append((name, value))

    async def async_set_title(self, value):
        self.formats.append(value)


class _TitledSession:
    def __init__(self):
        self.tab = _TitledTab()


async def test_a_batch_of_titles_fetches_the_app_once(monkeypatch):
    app = _CountingApp({f"s{i}": _TitledSession() for i in range(3)})
    monkeypatch.setattr(iterm2, "async_get_app", app.get)
    bridge = ItermBridge()
    bridge._conn = object()

    applied = await bridge.set_session_titles({"s0": "a", "s1": "b", "gone": "c", "s2": "d"})

    assert applied == ["s0", "s1", "s2"]
    assert app.fetches == 1
    assert app.sessions["s1"].tab.variables == [("user.shellforge_title", "b")]


class _Handle:
    """A window or session that records what it was asked."""
    def __init__(self):
        self.calls: list[tuple[str, object]] = []

    async def async_activate(self):
        self.calls.append(("activate", None))

    async def async_set_frame(self, frame):
        self.calls.append(("frame", frame))

    async def async_close(self, force=False):
        self.calls.append(("close", force))

    async def async_send_text(self, text):
        self.calls.append(("text", text))

    async def async_set_variable(self, name, value):
        self.calls.append(("variable", (name, value)))


class _Tree(_CountingApp):
    """A hierarchy that changes as iTerm2's does: `appearing` is what the next fetch finds."""
    def __init__(self, windows=(), sessions=()):
        super().__init__({name: _Handle() for name in sessions})
        self.windows = {name: _Handle() for name in windows}
        self.appearing: dict[str, _Handle] = {}

    async def get(self, _conn):
        self.fetches += 1
        for name, handle in self.appearing.items():
            (self.windows if name.startswith("w") else self.sessions)[name] = handle
        self.appearing = {}
        return self

    def get_window_by_id(self, window_id):
        return self.windows.get(window_id)


async def _tree_bridge(monkeypatch, tree: _Tree) -> ItermBridge:
    """A bridge that has fetched `tree` once, the way its connection setup does."""
    monkeypatch.setattr(iterm2, "async_get_app", tree.get)
    bridge = ItermBridge()
    bridge._conn = object()  # type: ignore[assignment]
    await bridge._app()
    assert tree.fetches == 1
    return bridge


async def test_commands_on_a_known_window_or_session_do_not_fetch_the_hierarchy_again(monkeypatch):
    """Each fetch is three round trips: re-tiling K windows paid 3K of them before its own K."""
    tree = _Tree(windows=["w1", "w2"], sessions=["s1"])
    bridge = await _tree_bridge(monkeypatch, tree)

    await bridge.activate_window("w1")
    await bridge.set_frame("w1", Frame(1, 2, 3, 4))
    await bridge.set_frame("w2", Frame(1, 2, 3, 4))
    await bridge.send_text("s1", "ls\n")
    await bridge.set_session_tags("s1", {"shellforge_task": "t"})
    await bridge.set_shellforge_background(["s1"], False)
    await bridge.close_window("w2")

    assert tree.fetches == 1
    assert [call for call, _ in tree.windows["w1"].calls] == ["activate", "frame"]
    assert tree.windows["w2"].calls[-1] == ("close", True)
    assert tree.sessions["s1"].calls == [("text", "ls\n"), ("variable", ("user.shellforge_task", "t"))]


async def test_a_window_or_session_the_cached_hierarchy_lacks_is_looked_for_again_once(monkeypatch):
    """Cmd+T and a new window are announced after the command that needs them can already arrive."""
    tree = _Tree(windows=["w1"])
    bridge = await _tree_bridge(monkeypatch, tree)
    tree.appearing = {"w2": _Handle(), "s9": _Handle()}

    await bridge.activate_window("w2")
    await bridge.send_text("s9", "pwd\n")

    assert tree.fetches == 2, "one refresh for the miss, none once the hierarchy has both"
    assert tree.windows["w2"].calls == [("activate", None)]
    assert tree.sessions["s9"].calls == [("text", "pwd\n")]


class _FirstTab:
    """A tab whose current session is in `path`."""
    def __init__(self, path):
        self.current_session, self.path = self, path

    async def async_get_variable(self, _name):
        return self.path


class _WindowOf(_Handle):
    def __init__(self, first_tab_path):
        super().__init__()
        self.tabs = [_FirstTab(first_tab_path)]


async def test_a_tab_without_an_anchor_opens_where_the_windows_first_tab_is_now(monkeypatch):
    """The cached hierarchy can be a tick old: its first tab may have closed, or been dragged away, since."""
    tree = _Tree(sessions=["s9"])
    tree.sessions["s9"].session_id = "s9"
    tree.windows["w1"] = _WindowOf("/closed-since")
    bridge = await _tree_bridge(monkeypatch, tree)
    tree.appearing = {"w1": _WindowOf("/first-now")}
    made: list[dict] = []

    async def create_tab(_conn, window=None, profile_customizations=None, **_kw):
        made.append(profile_customizations)
        reply = iterm2.api_pb2.ServerOriginatedMessage()
        reply.create_tab_response.status = iterm2.api_pb2.CreateTabResponse.Status.Value("OK")
        reply.create_tab_response.window_id, reply.create_tab_response.session_id = window, "s9"
        return reply

    monkeypatch.setattr(iterm2.rpc, "async_create_tab", create_tab)

    assert await bridge.create_tab("w1", {}) == "s9"
    assert made[0]["Working Directory"] == json.dumps("/first-now")


async def test_a_window_nowhere_in_iterm_is_not_found_after_one_refresh(monkeypatch):
    tree = _Tree(windows=["w1"])
    bridge = await _tree_bridge(monkeypatch, tree)

    with pytest.raises(KeyError):
        await bridge.activate_window("gone")

    assert tree.fetches == 2


async def test_a_background_for_several_missing_sessions_refreshes_once(monkeypatch):
    tree = _Tree(sessions=["s1"])
    bridge = await _tree_bridge(monkeypatch, tree)

    await bridge.set_shellforge_background(["gone1", "s1", "gone2", "gone3"], False)

    assert tree.fetches == 2


async def test_a_snapshot_or_session_info_still_fetches_the_hierarchy_every_time(monkeypatch):
    tree = _Tree()
    bridge = await _tree_bridge(monkeypatch, tree)
    tree.terminal_windows = []

    await bridge.snapshot()
    await bridge.snapshot()
    await bridge.session_info("s1")

    assert tree.fetches == 4


async def test_a_new_connection_does_not_reuse_the_old_hierarchy(monkeypatch):
    tree = _Tree(windows=["w1"])
    bridge = await _tree_bridge(monkeypatch, tree)
    bridge._forget_app()

    await bridge.activate_window("w1")

    assert tree.fetches == 2


async def test_shellforge_background_is_session_scoped_and_restorable(monkeypatch):
    bridge = ItermBridge()
    bridge._conn = object()

    class FakeSession:
        def __init__(self):
            self.original_profile = object()
            self.changes = []
            self.restored = None

        async def async_get_profile(self):
            return self.original_profile

        async def async_set_profile_properties(self, change):
            self.changes.append(change.values)

        async def async_set_profile(self, profile):
            self.restored = profile

    session = FakeSession()
    app = _CountingApp({"s1": session, "s2": FakeSession()})
    monkeypatch.setattr(iterm2, "async_get_app", app.get)
    await bridge.set_shellforge_background(["s1", "s2", "gone"], True)
    assert app.fetches == 1
    color = json.loads(session.changes[0]["Background Color"])
    assert color["Red Component"] == color["Green Component"] == color["Blue Component"] == 30 / 255
    assert "Background Color (Light)" in session.changes[0]
    assert "Background Color (Dark)" in session.changes[0]

    await bridge.set_shellforge_background(["s1"], False)
    assert session.restored is session.original_profile


async def test_a_closed_sessions_restore_profile_is_dropped():
    bridge = ItermBridge()
    bridge._background_restore_profiles["s1"] = object()

    class Closed:
        session_id = "s1"

    await bridge._on_closed(None, Closed())
    assert bridge._background_restore_profiles == {}


async def test_session_title_is_a_literal_tab_override_not_a_session_name(monkeypatch):
    app = _CountingApp({"s1": _TitledSession()})
    monkeypatch.setattr(iterm2, "async_get_app", app.get)
    bridge = ItermBridge()
    bridge._conn = object()

    await bridge.set_session_titles({"s1": "feat/title-(safe)"})

    tab = app.sessions["s1"].tab
    assert tab.variables == [("user.shellforge_title", "feat/title-(safe)")]
    assert tab.formats == [r"\(user.shellforge_title)"]


async def test_focus_notification_reports_a_window_that_becomes_current():
    bridge = ItermBridge()
    activated: list[str] = []

    async def record(window_id: str) -> None:
        activated.append(window_id)

    bridge.on_window_activated(record)
    notification = iterm2.api_pb2.FocusChangedNotification()
    notification.window.window_id = "w1"
    notification.window.window_status = notification.window.TERMINAL_WINDOW_BECAME_KEY

    await bridge._on_focus(None, notification)

    assert activated == ["w1"]


async def test_focus_notification_ignores_a_window_that_resigned_key_status():
    bridge = ItermBridge()
    activated: list[str] = []

    async def record(window_id: str) -> None:
        activated.append(window_id)

    bridge.on_window_activated(record)
    notification = iterm2.api_pb2.FocusChangedNotification()
    notification.window.window_id = "w1"
    notification.window.window_status = notification.window.TERMINAL_WINDOW_RESIGNED_KEY

    await bridge._on_focus(None, notification)

    assert activated == []


class _Osascript(iterm2.auth.CommandLineApplescriptRunner):
    """The library's own osascript runner, parsing a scripted result instead of spawning one.
    `replies` maps a substring of the AppleScript to (returncode, stdout, stderr)."""
    replies: dict[str, tuple[int, str, str]] = {}
    scripts: list[str] = []

    def execute(self):
        script = self._script.decode()
        type(self).scripts.append(script)
        key = next(k for k in type(self).replies if k in script)
        self._returncode, self._output, self._error = type(self).replies[key]


@pytest.fixture
def osascript(monkeypatch):
    monkeypatch.delenv("ITERM2_COOKIE", raising=False)
    monkeypatch.delenv("ITERM2_KEY", raising=False)
    monkeypatch.setattr(iterm2.auth, "applescript_auth_disabled", lambda: False)
    _Osascript.scripts = []
    _Osascript.replies = {"is running": (0, "yes", "")}
    return _Osascript


def test_a_refused_cookie_request_raises_auth_failed_with_the_osascript_error(osascript):
    osascript.replies["request cookie"] = (
        1, "", "0:61: execution error: Not authorized to send Apple events to iTerm2. (-1743)")

    with pytest.raises(ItermAuthFailed) as err:
        request_cookie(runner_class=osascript)

    assert str(err.value) == "execution error: Not authorized to send Apple events to iTerm2. (-1743)"
    assert "ITERM2_COOKIE" not in iterm2.auth.os.environ


def test_an_unparseable_osascript_error_is_reported_verbatim(osascript):
    osascript.replies["request cookie"] = (1, "", "osascript: something odd happened")

    with pytest.raises(ItermAuthFailed) as err:
        request_cookie(runner_class=osascript)

    assert str(err.value) == "osascript: something odd happened"


def test_a_cookie_request_while_iterm_is_not_running_is_plain_unavailability(osascript):
    osascript.replies["is running"] = (0, "no", "")

    with pytest.raises(ItermUnavailable) as err:
        request_cookie(runner_class=osascript)

    assert not isinstance(err.value, ItermAuthFailed)
    assert not any("request cookie" in s for s in osascript.scripts)


def test_a_granted_cookie_request_exports_the_cookie_for_the_library(osascript, monkeypatch):
    osascript.replies["request cookie"] = (0, "c00kie k3y", "")

    request_cookie(runner_class=osascript)

    assert (iterm2.auth.os.environ["ITERM2_COOKIE"], iterm2.auth.os.environ["ITERM2_KEY"]) == ("c00kie", "k3y")


def test_an_existing_cookie_is_used_without_asking_again(osascript, monkeypatch):
    monkeypatch.setenv("ITERM2_COOKIE", "given")

    request_cookie(runner_class=osascript)

    assert osascript.scripts == []


async def test_a_401_is_an_auth_failure_and_forgets_the_rejected_cookie(monkeypatch):
    monkeypatch.setattr(iterm_bridge, "request_cookie", lambda: None)
    monkeypatch.setenv("ITERM2_COOKIE", "stale")
    monkeypatch.setenv("ITERM2_KEY", "stale")

    async def rejected():
        raise websockets.exceptions.InvalidStatus(Response(401, "Unauthorized", Headers()))

    monkeypatch.setattr(iterm2.Connection, "async_create", staticmethod(rejected))

    with pytest.raises(ItermAuthFailed) as err:
        await ItermBridge().connect()

    assert "401" in str(err.value)
    # iterm2 2.23 only re-requests a cookie on the legacy InvalidStatusCode, which websockets 17
    # no longer raises, so a stale cookie left behind would be presented again forever.
    assert "ITERM2_COOKIE" not in iterm2.auth.os.environ and "ITERM2_KEY" not in iterm2.auth.os.environ


async def test_a_refused_connection_is_plain_unavailability(monkeypatch):
    monkeypatch.setattr(iterm_bridge, "request_cookie", lambda: None)

    async def refused():
        raise ConnectionRefusedError(61, "Connection refused")

    monkeypatch.setattr(iterm2.Connection, "async_create", staticmethod(refused))

    with pytest.raises(ItermUnavailable) as err:
        await ItermBridge().connect()

    assert not isinstance(err.value, ItermAuthFailed)


async def test_the_cookie_request_runs_off_the_event_loop(patched_connect, monkeypatch):
    # osascript can take seconds (or wait on a permission dialog); the loop must keep serving.
    import threading
    threads: list[threading.Thread] = []
    monkeypatch.setattr(iterm_bridge, "request_cookie", lambda: threads.append(threading.current_thread()))

    await ItermBridge().connect()

    assert threads and threads[0] is not threading.current_thread()


async def test_connect_asks_for_a_cookie_before_opening_the_socket(patched_connect, monkeypatch):
    order: list[str] = []
    monkeypatch.setattr(iterm_bridge, "request_cookie", lambda: order.append("cookie"))
    create = iterm2.Connection.async_create

    async def recording_create():
        order.append("socket")
        return await create()

    monkeypatch.setattr(iterm2.Connection, "async_create", staticmethod(recording_create))

    await ItermBridge().connect()

    assert order == ["cookie", "socket"]


class _DyingSocket:
    """A websocket iTerm2 never answers on, and which dies on `die()` the way it does when iTerm2
    quits: `recv()` raises in the library's reader, and `wait_closed()` returns."""
    def __init__(self):
        self.sent: list[bytes] = []
        self._dead = asyncio.Event()

    async def send(self, data):
        self.sent.append(data)

    async def recv(self):
        await self._dead.wait()
        raise websockets.exceptions.ConnectionClosedError(None, None)

    async def wait_closed(self):
        await self._dead.wait()

    async def close(self):
        self._dead.set()

    def die(self):
        self._dead.set()


def _dying_connection() -> tuple[iterm2.Connection, _DyingSocket, asyncio.Future]:
    """A real `iterm2.Connection` over a `_DyingSocket`, with the library's own reader running, as
    `Connection.async_create()` leaves it (without its cookie request)."""
    conn, socket = iterm2.Connection(), _DyingSocket()
    conn.websocket = socket
    reader = asyncio.ensure_future(conn._async_dispatch_forever(conn, asyncio.get_running_loop()))
    return conn, socket, reader


async def test_iterm_quitting_mid_snapshot_fails_the_tick_and_frees_its_lock(make_service, monkeypatch, capsys):
    monkeypatch.setattr(iterm2.app.App, "instance", None)
    conn, socket, reader = _dying_connection()
    bridge = ItermBridge()
    bridge._conn = conn
    bridge._watch_task = asyncio.get_running_loop().create_task(bridge._watch(conn))
    svc = make_service(iterm=bridge)

    tick = asyncio.create_task(svc.tick())
    for _ in range(50):
        if socket.sent:
            break
        await asyncio.sleep(0)
    assert socket.sent, "the snapshot asked iTerm2 for its sessions"
    socket.die()

    # The library resolves a call only with its reply; a reply that never comes must not leave the
    # tick -- and with it every later tick -- waiting on the lock forever.
    with pytest.raises(ItermUnavailable):
        await asyncio.wait_for(tick, 2)
    assert not svc._tick_lock.locked()
    assert not bridge.is_connected()
    with contextlib.suppress(websockets.exceptions.ConnectionClosed):
        await reader  # the library's reader ends on the dead socket, printing why
    capsys.readouterr()


async def test_a_call_iterm_never_answers_times_out(monkeypatch):
    monkeypatch.setattr(iterm2.app.App, "instance", None)
    monkeypatch.setattr(iterm_bridge, "ITERM_CALL_SECONDS", 0.05)
    conn, socket, reader = _dying_connection()
    bridge = ItermBridge()
    bridge._conn = conn

    with pytest.raises(ItermUnavailable, match="did not answer"):
        await asyncio.wait_for(bridge.snapshot(), 2)
    reader.cancel()


@pytest.fixture
def real_registration(monkeypatch, tmp_path):
    """The library's own subscriptions and App, over `_FakeConn`s, with only the RPCs faked: each
    answers OK over a live connection and raises over a closed one, as it would against iTerm2.
    The library's handler lists are process-wide, so each test starts from empty ones."""
    subscribe = {name: getattr(iterm2.notifications, f"async_subscribe_to_{name}_notification")
                 for name in ("new_session", "terminate_session", "focus_change")}
    conns = _patch_connection(monkeypatch, tmp_path)
    for name, real in subscribe.items():
        monkeypatch.setattr(iterm2.notifications, f"async_subscribe_to_{name}_notification", real)
    monkeypatch.setattr(iterm2.notifications._get_handlers, "handlers", {}, raising=False)
    monkeypatch.setattr(iterm2.app.App, "instance", None)
    for cls in (iterm2.session.Session, iterm2.tab.Tab, iterm2.window.Window):
        monkeypatch.setattr(cls, "delegate", getattr(cls, "delegate", None), raising=False)
    requests: list[object] = []

    async def rpc(connection, *_args, **_kw):
        if connection.websocket.closed:
            raise websockets.exceptions.ConnectionClosedError(None, None)
        requests.append(connection)
        return iterm2.api_pb2.ServerOriginatedMessage()

    for name in ("async_notification_request", "async_list_sessions", "async_get_focus_info", "async_get_broadcast_domains"):
        monkeypatch.setattr(iterm2.rpc, name, rpc)
    return conns, requests


async def _reconnected(conns) -> ItermBridge:
    bridge = ItermBridge()
    await bridge.connect()
    await conns[0].websocket.close()
    for _ in range(3):
        await asyncio.sleep(0)  # let _watch observe the close
    assert not bridge.is_connected()
    await bridge.connect()
    return bridge


async def test_a_reconnect_leaves_one_handler_per_notification(real_registration):
    conns, requests = real_registration
    bridge = await _reconnected(conns)
    handlers = iterm2.notifications._get_handlers()

    assert handlers[(None, iterm2.api_pb2.NOTIFY_ON_NEW_SESSION)] == [bridge._on_new]
    assert handlers[(None, iterm2.api_pb2.NOTIFY_ON_TERMINATE_SESSION)] == [bridge._on_closed]
    assert handlers[(None, iterm2.api_pb2.NOTIFY_ON_FOCUS_CHANGE)] == [bridge._on_focus]
    # The live App keeps the handler that updates its tree from the notification itself.
    assert [h.__self__ for h in handlers[(None, iterm2.api_pb2.NOTIFY_ON_LAYOUT_CHANGE)]] == [iterm2.app.App.instance]


async def test_after_a_reconnect_a_notification_reaches_the_bridge_once_and_the_live_app(real_registration):
    conns, requests = real_registration
    bridge = await _reconnected(conns)
    activated: list[str] = []
    opened: list[str] = []

    async def record_activated(window_id):
        activated.append(window_id)

    async def record_opened(session_id):
        opened.append(session_id)

    bridge.on_window_activated(record_activated)
    bridge.on_new_session(record_opened)

    focus = iterm2.api_pb2.ServerOriginatedMessage()
    focus.notification.focus_changed_notification.window.window_id = "w1"
    await iterm2.notifications._async_dispatch_helper(conns[1], focus)
    assert activated == ["w1"]

    new = iterm2.api_pb2.ServerOriginatedMessage()
    new.notification.new_session_notification.session_id = "s9"
    await iterm2.notifications._async_dispatch_helper(conns[1], new)
    assert opened == ["s9"]

    requests.clear()
    layout = iterm2.api_pb2.ServerOriginatedMessage()
    layout.notification.layout_changed_notification.list_sessions_response.SetInParent()
    # A dead App's handler would ask over its closed socket and abort the rest of the list.
    await iterm2.notifications._async_dispatch_helper(conns[1], layout)
    assert requests and all(conn is conns[1] for conn in requests), "the live App asked over the live connection"


@pytest.mark.parametrize("notification,field,value", [
    ("new_session_notification", "session_id", "s9"),
    ("terminate_session_notification", "session_id", "s9"),
    # A Cmd+T's focus change can be dispatched before its new-session notification.
    ("focus_changed_notification", "selected_tab", "tab-not-listed-yet"),
    ("focus_changed_notification", "session", "session-not-listed-yet"),
])
async def test_only_the_bridge_refreshes_the_hierarchy_when_iterm2_announces_a_change(real_registration, notification, field, value):
    """`App.async_refresh` returns at once while another is in flight: a refresh the App started
    itself, outside `_refresh_lock`, would hand the bridge's own the tree from before the change."""
    conns, requests = real_registration
    await ItermBridge().connect()
    requests.clear()
    message = iterm2.api_pb2.ServerOriginatedMessage()
    setattr(getattr(message.notification, notification), field, value)

    await iterm2.notifications._async_dispatch_helper(conns[0], message)

    assert requests == []


async def test_a_failed_setup_leaves_no_handler_behind(real_registration, monkeypatch):
    conns, requests = real_registration

    async def refused(*_args, **_kw):
        raise ConnectionError("iTerm2 went away during setup")

    monkeypatch.setattr(iterm2.rpc, "async_get_focus_info", refused)
    with pytest.raises(ItermUnavailable):
        await ItermBridge().connect()
    assert not any(iterm2.notifications._get_handlers().values())


async def test_a_cookie_is_forgotten_once_a_connection_has_spent_it(patched_connect, monkeypatch):
    # Cookies are single-use: presented again on the next connect it would be refused with a 401,
    # reported as a refusal, and back the retries off, for an iTerm2 that had merely restarted.
    monkeypatch.setenv("ITERM2_COOKIE", "c00kie")
    monkeypatch.setenv("ITERM2_KEY", "k3y")

    await ItermBridge().connect()

    assert "ITERM2_COOKIE" not in iterm2.auth.os.environ and "ITERM2_KEY" not in iterm2.auth.os.environ


async def test_a_refresh_overlapping_another_still_fetches_the_hierarchy(monkeypatch):
    """`App.async_refresh` returns at once, the tree untouched, while another refresh is in flight:
    a new-session handler overlapping a tick's snapshot would read a tree without its session."""
    listed = 0
    gate = asyncio.Event()

    async def list_sessions(_conn):
        nonlocal listed
        listed += 1
        await gate.wait()
        return iterm2.api_pb2.ServerOriginatedMessage()

    async def no_focus(_conn):
        return iterm2.api_pb2.ServerOriginatedMessage()

    monkeypatch.setattr(iterm2.rpc, "async_list_sessions", list_sessions)
    monkeypatch.setattr(iterm2.rpc, "async_get_focus_info", no_focus)
    conn = object()
    monkeypatch.setattr(iterm2.app.App, "instance", iterm2.app.App(conn, [], []))
    bridge = ItermBridge()
    bridge._conn = conn

    first = asyncio.create_task(bridge._app())
    await asyncio.sleep(0)
    second = asyncio.create_task(bridge._app())
    for _ in range(3):
        await asyncio.sleep(0)
    assert not second.done(), "the second refresh waits for the first instead of returning its stale tree"
    gate.set()
    await asyncio.gather(first, second)
    assert listed == 2


def _variables_bridge(monkeypatch, windows: dict[str, list[list[str]]], closed: AbstractSet[str] = frozenset(),
                      error: Exception | None = None, refused: dict[str, str] | None = None,
                      multi_get_refusal: str | None = None, unset_omitted: bool = False) -> tuple[ItermBridge, list[tuple[str, list[str]]]]:
    """A bridge over real `iterm2.Session`s, laid out as {window: [[session, ...] per tab]}, with
    only the variable RPC faked. A session in `closed` answers SESSION_NOT_FOUND, as one closed
    mid-snapshot does; one in `refused` answers the status named there; `multi_get_refusal`, when
    set, is the status every request for more than one name gets; `unset_omitted` leaves a name
    with no value out of an OK answer for several; `error` is raised by every read.
    Each request is recorded, and the most requests in flight at once is kept as
    `bridge.max_in_flight`."""
    requests: list[tuple[str, list[str]]] = []
    in_flight = [0, 0]  # now, most
    status_of = {sid: "SESSION_NOT_FOUND" for sid in closed} | (refused or {})

    async def variable(_conn, session_id=None, sets=None, gets=None, **_kw):
        requests.append((session_id, list(gets)))
        in_flight[0] += 1
        in_flight[1] = max(in_flight)
        await asyncio.sleep(0)  # yield, so reads that are concurrent overlap
        in_flight[0] -= 1
        if error is not None:
            raise error
        reply = iterm2.api_pb2.ServerOriginatedMessage()
        status = status_of.get(session_id, "OK")
        if status == "OK" and multi_get_refusal and len(gets) > 1:
            status = multi_get_refusal
        reply.variable_response.status = iterm2.api_pb2.VariableResponse.Status.Value(status)
        if status == "OK":
            values = {"commandLine": "-zsh", "jobPid": 123, "autoName": session_id, "path": "/x",
                      "user.shellforge_task": "t1", "user.shellforge_project": None}
            answered = [name for name in gets if not (unset_omitted and len(gets) > 1 and values[name] is None)]
            reply.variable_response.values.extend(json.dumps(values[name]) for name in answered)
        return reply

    monkeypatch.setattr(iterm2.rpc, "async_variable", variable)

    class Tab:
        def __init__(self, ids):
            self.sessions = [iterm2.session.Session(None, None, iterm2.api_pb2.SessionSummary(unique_identifier=i)) for i in ids]
            self.current_session = self.sessions[0]

    class Window:
        def __init__(self, wid, tabs):
            self.window_id, self.tabs = wid, [Tab(ids) for ids in tabs]
            self.current_tab = self.tabs[0]

    class App:
        terminal_windows = [Window(wid, tabs) for wid, tabs in windows.items()]

    bridge = ItermBridge()
    bridge._conn = object()  # type: ignore[assignment]  # never read: the variable RPC is faked

    async def app():
        return App()

    bridge._app = app  # type: ignore[method-assign]
    bridge.max_in_flight = lambda: in_flight[1]  # type: ignore[attr-defined]
    return bridge, requests


async def test_snapshot_reads_each_sessions_variables_in_one_request_all_at_once(monkeypatch):
    bridge, requests = _variables_bridge(monkeypatch, {"w1": [["s1", "s2"], ["s3"]]})
    out = await bridge.snapshot()

    assert [s.session_id for s in out] == ["s1", "s2", "s3"]
    assert [s.tab_index for s in out] == [0, 0, 1]
    assert [s.active for s in out] == [True, False, False], "the window's current session is marked active"
    assert requests == [(sid, list(VARIABLES)) for sid in ("s1", "s2", "s3")], "one request per session"
    assert bridge.max_in_flight() == 3, "every session's read is in flight at once"


async def test_a_session_closed_mid_snapshot_is_left_out_not_fatal(monkeypatch):
    bridge, _ = _variables_bridge(monkeypatch, {"w1": [["s1"], ["s2"], ["s3"]]}, closed={"s2"})
    out = await bridge.snapshot()
    assert [s.session_id for s in out] == ["s1", "s3"]
    assert out[0].user_vars == {"shellforge_task": "t1"} and out[0].job_pid == 123 and out[0].title == "s1"


async def test_a_snapshot_that_can_read_no_session_fails_rather_than_reporting_none(monkeypatch):
    # Every tab would read as closed, and the registry would broadcast them all as gone.
    bridge, _ = _variables_bridge(monkeypatch, {"w1": [["s1"], ["s2"]]}, closed={"s1", "s2"})
    with pytest.raises(iterm2.rpc.RPCException):
        await bridge.snapshot()


async def test_a_lost_connection_mid_snapshot_is_not_a_closed_session(monkeypatch):
    bridge, _ = _variables_bridge(monkeypatch, {"w1": [["s1"], ["s2"]]}, error=ItermUnavailable("iTerm2 closed the connection"))
    with pytest.raises(ItermUnavailable):
        await bridge.snapshot()


async def test_session_info_reads_one_session_where_it_is(monkeypatch):
    bridge, requests = _variables_bridge(monkeypatch, {"w1": [["s1"]], "w2": [["s2", "s3"], ["s4"]]}, closed={"s4"})

    info = await bridge.session_info("s3")

    assert (info.session_id, info.window_id, info.tab_index, info.active) == ("s3", "w2", 0, False)
    assert info.user_vars == {"shellforge_task": "t1"} and info.title == "s3"
    assert requests == [("s3", list(VARIABLES))], "only that session is read"
    assert await bridge.session_info("gone") is None
    assert await bridge.session_info("s4") is None, "closed between the hierarchy and its read"


@pytest.mark.parametrize("refusal", ["MULTI_GET_DISALLOWED", "INVALID_NAME"])
async def test_an_iterm_that_refuses_a_batched_read_is_read_a_name_at_a_time(monkeypatch, refusal):
    bridge, requests = _variables_bridge(monkeypatch, {"w1": [["s1"], ["s2"]]}, multi_get_refusal=refusal)

    out = await bridge.snapshot()
    assert [s.session_id for s in out] == ["s1", "s2"]
    assert out[0].user_vars == {"shellforge_task": "t1"} and out[0].job_pid == 123 and out[0].title == "s1"

    requests.clear()
    assert (await bridge.session_info("s2")).title == "s2"
    assert requests == [("s2", [name]) for name in VARIABLES], "the refusal is remembered: no batched attempt"


async def test_a_batched_answer_short_of_a_value_is_read_a_name_at_a_time(monkeypatch):
    """An OK answer with fewer values than names asked cannot be matched to them: every snapshot
    would fail, and the sidebar would freeze."""
    bridge, requests = _variables_bridge(monkeypatch, {"w1": [["s1"], ["s2"]]}, unset_omitted=True)

    out = await bridge.snapshot()
    assert [s.session_id for s in out] == ["s1", "s2"]
    assert out[0].user_vars == {"shellforge_task": "t1"} and out[0].job_pid == 123 and out[0].title == "s1"
    assert not bridge._batched_reads

    requests.clear()
    await bridge.session_info("s2")
    assert requests == [("s2", [name]) for name in VARIABLES], "remembered, as a refusal is"


async def test_only_a_session_iterm_no_longer_has_is_left_out(monkeypatch):
    # Any other refusal is a failed read of a live session, which must not be reported closed.
    bridge, _ = _variables_bridge(monkeypatch, {"w1": [["s1"], ["s2"]]}, refused={"s2": "MISSING_SCOPE"})
    with pytest.raises(iterm2.rpc.RPCException, match="MISSING_SCOPE"):
        await bridge.snapshot()
    with pytest.raises(iterm2.rpc.RPCException, match="MISSING_SCOPE"):
        await bridge.session_info("s2")


class _CreatingApp:
    """iTerm2 making windows and tabs, behind the library's App singleton: `live` is iTerm2's
    hierarchy, `tree` what the last refresh read of it. As `App.async_refresh` does, a refresh
    while another is in flight returns at once, the tree untouched; one waits on `gate` while it
    is clear. `on_create` runs as iTerm2 makes each window or tab."""

    class Session:
        def __init__(self, session_id, hangs=False, fails=False):
            self.session_id, self.hangs, self.fails, self.variables = session_id, hangs, fails, {}

        async def async_set_variable(self, name, value):
            if self.hangs:
                await asyncio.Event().wait()  # iTerm2 stops answering
            if self.fails:
                raise iterm2.rpc.RPCException("SESSION_NOT_FOUND")
            self.variables[name] = value

        async def async_get_variable(self, _name):
            return "/first"

    class Tab:
        def __init__(self, session):
            self.current_session, self.sessions = session, [session]

    class Window:
        def __init__(self, app, window_id):
            self.app, self.window_id, self.tabs, self.frames, self.activated = app, window_id, [], [], False

        @property
        def current_tab(self):
            return self.tabs[-1] if self.tabs else None

        async def async_set_frame(self, frame):
            self.frames.append(frame)

        async def async_activate(self):
            self.activated = True

        async def async_create_tab(self, profile_customizations=None):
            # The library's own: the request, then the delegate's refresh to find the new tab.
            reply = await iterm2.rpc.async_create_tab(None, window=self.window_id, profile_customizations=profile_customizations)
            return await self.app.window_delegate_get_tab_with_session_id(reply.create_tab_response.session_id)

    def __init__(self, session_options=None):
        self.live: dict[str, _CreatingApp.Window] = {}
        # Each window's tabs as the last refresh read them.
        self.tree: dict[str, tuple[_CreatingApp.Window, list[_CreatingApp.Tab]]] = {}
        self.gate = asyncio.Event()
        self.gate.set()
        self.on_create = None
        self.session_options = session_options or {}
        self.created: list[tuple[str | None, dict]] = []
        self._refreshing = False
        self._ids = iter(range(1, 100))

    async def async_refresh(self):
        if self._refreshing:
            return
        self._refreshing = True
        try:
            await self.gate.wait()
            self.tree = {window_id: (window, list(window.tabs)) for window_id, window in self.live.items()}
        finally:
            self._refreshing = False

    async def get(self, _conn):
        await self.async_refresh()
        return self

    def get_window_by_id(self, window_id):
        return self.tree[window_id][0] if window_id in self.tree else None

    def _find(self, session_id):
        return next(((w, tab) for w, tabs in self.tree.values() for tab in tabs if tab.current_session.session_id == session_id),
                    (None, None))

    def get_session_by_id(self, session_id):
        _window, tab = self._find(session_id)
        return tab.current_session if tab else None

    # The library's `Window.delegate`, which is the App.
    async def window_delegate_get_window_with_session_id(self, session_id):
        await self.async_refresh()
        return self._find(session_id)[0]

    async def window_delegate_get_tab_with_session_id(self, session_id):
        await self.async_refresh()
        return self._find(session_id)[1]

    def add_window(self, window_id):
        self.live[window_id] = _CreatingApp.Window(self, window_id)
        return self.live[window_id]

    async def create_tab_rpc(self, _conn, profile=None, window=None, index=None, command=None, profile_customizations=None,
                             select=True):
        self.created.append((window, profile_customizations))
        win = self.live[window] if window else self.add_window(f"w{next(self._ids)}")
        session_id = f"s{next(self._ids)}"
        win.tabs.append(_CreatingApp.Tab(_CreatingApp.Session(session_id, **self.session_options)))
        if self.on_create:
            await self.on_create()
        reply = iterm2.api_pb2.ServerOriginatedMessage()
        reply.create_tab_response.status = iterm2.api_pb2.CreateTabResponse.Status.Value("OK")
        reply.create_tab_response.window_id, reply.create_tab_response.session_id = win.window_id, session_id
        return reply


@pytest.fixture
def creating_app(monkeypatch):
    def make(**session_options) -> tuple[ItermBridge, _CreatingApp]:
        app = _CreatingApp(session_options)
        monkeypatch.setattr(iterm2, "async_get_app", app.get)
        monkeypatch.setattr(iterm2.rpc, "async_create_tab", app.create_tab_rpc)
        monkeypatch.setattr(iterm2.Window, "delegate", app, raising=False)
        bridge = ItermBridge()
        bridge._conn = object()  # type: ignore[assignment]  # never read: every request is faked
        return bridge, app
    return make


def _a_tick_refreshes_meanwhile(bridge: ItermBridge, app: _CreatingApp) -> list[asyncio.Task]:
    """Makes a tick's refresh start while iTerm2 makes the window or tab, and hold until `gate`."""
    ticks: list[asyncio.Task] = []

    async def refresh_starts():
        app.gate.clear()
        ticks.append(asyncio.create_task(bridge._app()))
        await asyncio.sleep(0)  # the tick is refreshing now

    app.on_create = refresh_starts
    return ticks


async def _once_the_tick_ends(app: _CreatingApp, ticks: list[asyncio.Task], creating: Awaitable[T]) -> T:
    task = asyncio.ensure_future(creating)
    for _ in range(5):
        await asyncio.sleep(0)
    app.gate.set()
    result = await asyncio.wait_for(task, 2)
    await asyncio.gather(*ticks)
    return result


async def test_a_window_made_while_a_refresh_is_in_flight_is_still_found(creating_app):
    """The refresh that finds the new window must not be the one that returns at once while a
    tick's is in flight: its stale tree lacks the window, and an error would make the app retry
    and open a second one, untagged, so no dedupe finds it."""
    bridge, app = creating_app()
    ticks = _a_tick_refreshes_meanwhile(bridge, app)
    frame = iterm_bridge.Frame(0, 0, 10, 10)

    assert await _once_the_tick_ends(app, ticks, bridge.create_window("/wt", "x", {"shellforge_task": "t1"}, frame)) == ("w1", "s2")
    assert len(app.created) == 1
    window = app.live["w1"]
    assert window.current_tab.current_session.variables == {"user.shellforge_task": "t1"}
    assert window.frames and window.activated


async def test_a_tab_made_while_a_refresh_is_in_flight_is_still_found(creating_app):
    bridge, app = creating_app()
    app.add_window("w0").tabs.append(_CreatingApp.Tab(_CreatingApp.Session("s0")))
    ticks = _a_tick_refreshes_meanwhile(bridge, app)

    assert await _once_the_tick_ends(app, ticks, bridge.create_tab("w0", {"shellforge_task": "t1"})) == "s1"
    assert [window for window, _profile in app.created] == ["w0"]
    assert app.created[0][1]["Working Directory"] == json.dumps("/first"), "no anchor given: the window's first tab's directory"
    assert app.live["w0"].current_tab.current_session.variables == {"user.shellforge_task": "t1"}


async def test_a_window_is_returned_even_if_setting_it_up_times_out(creating_app, monkeypatch):
    """Once iTerm2 has made the window, an error would make the app retry and open a second one."""
    monkeypatch.setattr(iterm_bridge, "ITERM_CALL_SECONDS", 0.05)
    bridge, _app = creating_app(hangs=True)
    frame = iterm_bridge.Frame(0, 0, 10, 10)
    assert await asyncio.wait_for(bridge.create_window("/wt", "x", {"shellforge_task": "t1"}, frame), 2) == ("w1", "s2")


async def test_a_tab_is_returned_even_if_tagging_it_fails(creating_app):
    bridge, app = creating_app(fails=True)
    app.add_window("w0")
    assert await bridge.create_tab("w0", {"shellforge_task": "t1"}, cwd="/wt") == "s1"
