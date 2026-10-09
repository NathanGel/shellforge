import asyncio

import pytest

from shellforged.connection import ItermSupervisor
from shellforged.rpc_server import RpcError
from tests.conftest import wait_until
from tests.fake_iterm import FakeIterm

REFUSED = "execution error: Not authorized to send Apple events to iTerm2. (-1743)"


class Broadcasts:
    """Stands in for the RPC server's broadcast: every event, in order, for a test to await."""

    def __init__(self):
        self.events: asyncio.Queue[tuple[str, object]] = asyncio.Queue()

    async def __call__(self, name, payload):
        self.events.put_nowait((name, payload))

    async def next(self, name, timeout=2.0):
        """The payload of the next `name` event, skipping any other."""
        async with asyncio.timeout(timeout):
            while True:
                event, payload = await self.events.get()
                if event == name:
                    return payload


class Harness:
    """A supervisor over a FakeIterm, with no sockets: its broadcasts are recorded, its attached
    app count is `clients`, and its reconnect loop records each delay instead of waiting it out."""

    def __init__(self, it, **kw):
        self.it, self.broadcasts, self.clients = it, Broadcasts(), 0
        self.delays: list[float] = []
        self.launches: list[int] = []
        self.cookies: list[tuple[str, str]] = []
        kw.setdefault("reconnect_seconds", 0.01)
        kw.setdefault("apply_cookie", lambda cookie, key: self.cookies.append((cookie, key)))
        self.supervisor = ItermSupervisor(it, self.broadcasts, lambda: self.clients, launch_iterm=self._launch,
                                          reconnect_sleep=self._sleep, **kw)

    async def _sleep(self, seconds):
        self.delays.append(seconds)
        await asyncio.sleep(0.001)

    async def _launch(self):
        self.launches.append(1)


@pytest.fixture
async def harness():
    """Builds harnesses, and stops every one's supervisor after the test."""
    built: list[Harness] = []

    def make(it=None, **kw):
        built.append(Harness(it if it is not None else FakeIterm(), **kw))
        return built[-1]

    yield make
    for h in built:
        await h.supervisor.stop()


def test_a_cookie_wait_that_is_not_positive_is_rejected():
    for seconds in (0, -1):
        with pytest.raises(ValueError, match="cookie_wait_seconds"):
            Harness(FakeIterm(), cookie_wait_seconds=seconds)


async def test_startup_reconnect_launches_iterm_once_and_reports_connected(harness):
    # C1: a disconnected-at-startup daemon must keep retrying (not just try
    # once), launching iTerm2 exactly once per retry run, and must broadcast
    # iterm.connected once iTerm2 becomes reachable.
    h = harness(FakeIterm(connected=False))
    await h.supervisor.start()
    assert await h.supervisor.status(None) == {"connected": False, "version": None, "authError": None}
    await wait_until(lambda: len(h.delays) >= 3)  # several retries, so launching once is a choice

    await h.it.reconnect()
    assert await h.broadcasts.next("iterm.connected") == {"version": "3.7.2"}
    assert h.launches == [1]
    assert await h.supervisor.status(None) == {"connected": True, "version": "3.7.2", "authError": None}


async def test_a_connect_calls_on_connected_before_announcing_it(harness):
    h = harness()
    order = []
    h.supervisor.on_connected = lambda: order.append(h.broadcasts.events.qsize())
    await h.supervisor.start()
    assert order == [0], "on_connected runs before iterm.connected is broadcast"
    assert await h.broadcasts.next("iterm.connected") == {"version": "3.7.2"}


async def test_plain_unavailability_keeps_retrying_at_the_fixed_interval(harness):
    h = harness(FakeIterm(connected=False))
    await h.supervisor.start()
    await wait_until(lambda: len(h.delays) >= 6)
    assert set(h.delays) == {0.01}
    assert h.launches == [1]


async def test_an_unexpected_connect_error_does_not_end_the_reconnect_loop(harness, caplog):
    it = FakeIterm(connected=False)
    real_connect = it.connect
    calls = []

    async def flaky_connect():
        calls.append(1)
        if len(calls) == 2:  # the loop's first attempt, after start()'s own
            raise RuntimeError("library bug")
        return await real_connect()

    it.connect = flaky_connect
    h = harness(it)
    with caplog.at_level("ERROR", logger="shellforged.connection"):
        await h.supervisor.start()
        await wait_until(lambda: len(calls) >= 4)
        await it.reconnect()
        await wait_until(lambda: h.supervisor.version == "3.7.2")
        assert "reconnect attempt failed" in [rec.getMessage() for rec in caplog.records]


async def test_refused_authentication_backs_off_is_reported_and_does_not_relaunch_iterm(harness, caplog):
    it = FakeIterm(connected=False)
    it.auth_error = REFUSED
    h = harness(it, auth_backoff_cap_seconds=0.08)
    with caplog.at_level("INFO", logger="shellforged.connection"):
        await h.supervisor.start()
        await wait_until(lambda: len(h.delays) >= 6)
        # start() and the loop's first pass are two refusals back to back, so the first
        # wait is already doubled; then each doubles until the cap.
        assert h.delays[:6] == [0.02, 0.04, 0.08, 0.08, 0.08, 0.08]
        # iTerm2 answered the "is it running" check, so opening it again only steals focus.
        assert h.launches == []
        # The first failure happened before any client attached; a late client asks.
        assert await h.supervisor.status(None) == {"connected": False, "version": None, "authError": REFUSED}
        refusing = h.supervisor.snapshot_fields()
        assert refusing["itermAuthError"] == REFUSED and refusing["itermVersion"] is None
        # The reason is logged once for the whole streak, not once per retry.
        assert [rec.getMessage() for rec in caplog.records if REFUSED in rec.getMessage()] == [
            f"iTerm2 refused the API connection: {REFUSED}"]
        assert await h.broadcasts.next("iterm.auth_failed") == {"reason": REFUSED}

        it.auth_error = None
        await it.reconnect()
        assert await h.broadcasts.next("iterm.connected") == {"version": "3.7.2"}
        assert (await h.supervisor.status(None))["authError"] is None


async def test_refused_authentication_after_a_disconnect_is_broadcast_and_cleared_when_it_stops(harness):
    it = FakeIterm()
    h = harness(it, auth_backoff_cap_seconds=0.08)
    await h.supervisor.start()
    assert (await h.supervisor.status(None))["connected"]
    it.auth_error = REFUSED
    await it.disconnect()
    assert await h.broadcasts.next("iterm.disconnected") == {}
    assert await h.broadcasts.next("iterm.auth_failed") == {"reason": REFUSED}

    # Now iTerm2 has quit: an ordinary wait, so the warning is withdrawn, the interval
    # resets and iTerm2 is opened.
    await wait_until(lambda: len(h.delays) >= 3)
    it.auth_error = None
    assert await h.broadcasts.next("iterm.disconnected") == {}
    await wait_until(lambda: h.launches == [1])
    mark = len(h.delays)
    await wait_until(lambda: len(h.delays) >= mark + 3)
    assert set(h.delays[mark:]) == {0.01}

    await it.reconnect()
    assert await h.broadcasts.next("iterm.connected") == {"version": "3.7.2"}


# -- cookies from the app ------------------------------------------------------------


async def test_a_cookie_request_made_before_the_app_attached_is_offered_and_its_answer_connects(harness):
    h = harness(cookies_from_app=True)
    await h.supervisor.start()
    await wait_until(lambda: h.supervisor._cookie_request is not None)
    assert h.supervisor.snapshot_fields()["itermCookieRequest"] == 1
    h.clients = 1
    assert await h.supervisor.provide_cookie({"requestId": 1, "cookie": "c00kie", "key": "k3y"}) == {"accepted": True}
    assert await h.broadcasts.next("iterm.connected") == {"version": "3.7.2"}
    assert h.cookies == [("c00kie", "k3y")]
    assert h.supervisor.snapshot_fields()["itermCookieRequest"] is None
    # A second answer to the same request finds nothing waiting for it.
    assert await h.supervisor.provide_cookie({"requestId": 1, "cookie": "again", "key": "k"}) == {"accepted": False}
    assert h.cookies == [("c00kie", "k3y")]


async def test_every_reconnect_asks_the_app_for_a_fresh_cookie(harness):
    it = FakeIterm()
    h = harness(it, cookies_from_app=True)
    h.clients = 1
    await h.supervisor.start()
    assert await h.broadcasts.next("iterm.cookieRequested") == {"requestId": 1}
    await h.supervisor.provide_cookie({"requestId": 1, "cookie": "one", "key": "k"})
    await h.broadcasts.next("iterm.connected")
    await it.disconnect()
    await it.reconnect()
    # iTerm2 cookies are single-use, so the reconnect asks again rather than replaying "one".
    assert await h.broadcasts.next("iterm.cookieRequested") == {"requestId": 2}
    await h.supervisor.provide_cookie({"requestId": 2, "cookie": "two", "key": "k"})
    await h.broadcasts.next("iterm.connected")
    assert h.cookies == [("one", "k"), ("two", "k")]


async def test_the_apps_not_running_answer_opens_iterm_and_its_refusal_is_an_auth_failure(harness):
    h = harness(cookies_from_app=True, auth_backoff_cap_seconds=0.08)
    h.clients = 1
    await h.supervisor.start()
    await wait_until(lambda: h.supervisor._cookie_request is not None)
    await h.supervisor.provide_cookie({"requestId": 1, "notRunning": True})
    await wait_until(lambda: h.launches == [1])
    assert h.supervisor.auth_error is None
    await wait_until(lambda: h.supervisor._cookie_request is not None and h.supervisor._cookie_request[0] == 2)
    await h.supervisor.provide_cookie({"requestId": 2, "error": REFUSED})
    assert await h.broadcasts.next("iterm.auth_failed") == {"reason": REFUSED}
    assert h.cookies == [] and h.supervisor.version is None


async def test_a_cookie_request_waits_for_an_app_to_attach_however_long_that_takes(harness):
    """The wait only runs while an app is attached: the daemon starts before the app attaches, and
    asking iTerm2 itself would run osascript, which is what --cookies-from-app exists to avoid."""
    h = harness(cookies_from_app=True, cookie_wait_seconds=0.05)
    await h.supervisor.start()
    await wait_until(lambda: h.supervisor._cookie_request is not None)
    await asyncio.sleep(0.3)  # six waits' worth with no app attached
    assert h.supervisor._cookie_request[0] == 1 and h.supervisor.version is None
    h.clients = 1
    await h.supervisor.provide_cookie({"requestId": 1, "cookie": "c00kie", "key": "k3y"})
    await h.broadcasts.next("iterm.connected")
    assert h.cookies == [("c00kie", "k3y")]


async def test_an_attached_app_that_does_not_answer_is_asked_again_not_bypassed(harness, caplog):
    h = harness(cookies_from_app=True, cookie_wait_seconds=0.05)
    h.clients = 1
    with caplog.at_level("WARNING", logger="shellforged.connection"):
        await h.supervisor.start()
        await wait_until(lambda: h.supervisor._cookie_request is not None and h.supervisor._cookie_request[0] >= 3)
        assert h.supervisor.version is None and h.cookies == []
        assert "asking again" in caplog.text
        # The first request has expired: only an answer to the one outstanding is taken.
        assert await h.supervisor.provide_cookie({"requestId": 1, "cookie": "old", "key": "k"}) == {"accepted": False}


async def test_an_abandoned_cookie_request_does_not_clear_a_newer_one(harness):
    supervisor = harness(cookies_from_app=True).supervisor
    first = asyncio.create_task(supervisor._cookie_from_app())
    await wait_until(lambda: supervisor._cookie_request is not None)
    second = asyncio.create_task(supervisor._cookie_from_app())
    await wait_until(lambda: supervisor._cookie_request is not None and supervisor._cookie_request[0] == 2)
    first.cancel()
    await asyncio.gather(first, return_exceptions=True)
    assert supervisor._cookie_request is not None and supervisor._cookie_request[0] == 2
    second.cancel()
    await asyncio.gather(second, return_exceptions=True)
    assert supervisor._cookie_request is None


async def test_a_malformed_cookie_answer_is_bad_params(harness):
    supervisor = harness().supervisor
    for answer in ({"requestId": 1, "cookie": "c"}, {"cookie": "c", "key": "k"}):
        with pytest.raises(RpcError) as raised:
            await supervisor.provide_cookie(answer)
        assert raised.value.code == "bad_params"
    # Without --cookies-from-app nothing is ever outstanding.
    assert await supervisor.provide_cookie({"requestId": 1, "cookie": "c", "key": "k"}) == {"accepted": False}


async def test_a_disconnect_after_stop_starts_no_reconnect(harness):
    """On shutdown the connection closes: that is no disconnect to reconnect from, and a reconnect
    loop would launch iTerm2."""
    h = harness()
    await h.supervisor.start()
    await h.supervisor.stop()
    assert h.it.closed and not h.it.is_connected()
    await h.it.disconnect()
    assert h.supervisor._reconnect_task is None and h.launches == []
