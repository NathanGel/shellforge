# daemon/tests/test_fake_iterm.py
import asyncio

import pytest

from shellforged.models import Frame
from tests.fake_iterm import FakeIterm


async def test_fake_window_and_tab_lifecycle():
    it = FakeIterm()
    wid, _ = await it.create_window("/w", "t", {"aiterm_task": "t1"}, Frame(0, 0, 10, 10))
    seen = []
    it.on_new_session(lambda sid: _record(seen, sid))
    sid = await it.user_opens_tab(wid)
    assert seen == [sid]
    snap = await it.snapshot()
    assert [s.tab_index for s in snap] == [0, 1] and snap[1].cwd == "/Users/me" and snap[1].user_vars == {}
    await it.set_session_tags(sid, {"aiterm_task": "t1"})
    assert (await it.snapshot())[1].user_vars == {"aiterm_task": "t1"}


async def test_creating_a_window_or_tab_announces_the_session_before_the_call_returns():
    it = FakeIterm()
    seen: list[str] = []
    it.on_new_session(lambda sid: _record(seen, sid))
    wid, first = await it.create_window("/w", "t", {}, Frame(0, 0, 10, 10))
    assert seen == [first]
    second = await it.create_tab(wid, {})
    assert seen == [first, second]


async def test_a_notification_is_its_own_task_not_part_of_the_call_that_caused_it():
    # The library dispatches each notification separately: a handler that is slow, or fails, must
    # neither hold up nor fail the create that announced it.
    it = FakeIterm()
    release = asyncio.Event()

    async def slow(_sid: str) -> None:
        await release.wait()
        raise RuntimeError("a handler's own failure")

    it.on_new_session(slow)
    wid, _ = await it.create_window("/w", "t", {}, Frame(0, 0, 10, 10))
    assert it._notifications
    release.set()
    with pytest.raises(RuntimeError):
        await it.settle()
    assert wid in it.windows


async def test_notify_on_create_off_announces_nothing():
    it = FakeIterm(notify_on_create=False)
    seen: list[str] = []
    it.on_new_session(lambda sid: _record(seen, sid))
    it.on_session_closed(lambda sid: _record(seen, sid))
    wid, _ = await it.create_window("/w", "t", {}, Frame(0, 0, 10, 10))
    await it.create_tab(wid, {})
    await it.close_window(wid)
    assert seen == []


async def test_closing_a_window_announces_every_session_in_it():
    it = FakeIterm()
    wid, first = await it.create_window("/w", "t", {}, Frame(0, 0, 10, 10))
    second = await it.create_tab(wid, {})
    closed: list[str] = []
    it.on_session_closed(lambda sid: _record(closed, sid))
    await it.close_window(wid)
    assert closed == [first, second]
    assert not it.sessions and not it.windows


async def test_closing_a_tab_renumbers_the_tabs_after_it():
    it = FakeIterm()
    wid, first = await it.create_window("/w", "t", {}, Frame(0, 0, 10, 10))
    second, third = await it.create_tab(wid, {}), await it.create_tab(wid, {})
    await it.user_closes_session(first)
    assert [(s.session_id, s.tab_index) for s in await it.snapshot()] == [(second, 0), (third, 1)]
    fourth = await it.create_tab(wid, {})
    assert it.sessions[fourth].tab_index == 2


async def test_panes_share_a_tab_index_and_closing_one_renumbers_nothing():
    it = FakeIterm()
    wid, first = await it.create_window("/w", "t", {}, Frame(0, 0, 10, 10))
    second = await it.create_tab(wid, {})
    pane = await it.add_pane(wid, tab_index=0)
    assert [it.sessions[s].tab_index for s in (first, second, pane)] == [0, 1, 0]
    await it.user_closes_session(pane)
    assert [it.sessions[s].tab_index for s in (first, second)] == [0, 1]
    await it.user_closes_session(first)
    assert it.sessions[second].tab_index == 0


async def _record(seen, sid):
    seen.append(sid)
