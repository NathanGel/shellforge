# daemon/tests/integration/test_live_iterm.py
"""Runs only with SHELLFORGED_LIVE=1 and a running iTerm2. Opens and closes one window."""
import asyncio
import os
import pytest
from shellforged.iterm_bridge import ItermBridge
from shellforged.models import Frame

pytestmark = pytest.mark.skipif(os.environ.get("SHELLFORGED_LIVE") != "1", reason="needs live iTerm2")


async def _wait_until(predicate, timeout=5.0, interval=0.2):
    """Polls `predicate` (an async callable) until it returns a truthy value,
    returning that value. Raises AssertionError if it never does within `timeout`."""
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while True:
        result = await predicate()
        if result:
            return result
        if loop.time() >= deadline:
            raise AssertionError(f"condition not met within {timeout}s")
        await asyncio.sleep(interval)


async def test_window_roundtrip(tmp_path):
    bridge = ItermBridge()
    version = await bridge.connect()
    assert version
    opened = []
    bridge.on_new_session(lambda sid: _append(opened, sid))
    wid, first_sid = await bridge.create_window(str(tmp_path), "live-test", {"shellforge_task": "live"}, Frame(324, 36, 1104, 852))
    try:
        assert first_sid

        async def _first_session_ready():
            snap = [s for s in await bridge.snapshot() if s.window_id == wid]
            if snap and snap[0].cwd == str(tmp_path) and snap[0].user_vars == {"shellforge_task": "live"}:
                return snap
            return None

        snap = await _wait_until(_first_session_ready)
        assert snap and snap[0].cwd == str(tmp_path) and snap[0].user_vars == {"shellforge_task": "live"}
        # The session has no `shellforge_project`: the batched read must answer an unset name too, or
        # every tick falls back to six requests per tab.
        assert bridge._batched_reads, "iTerm2 would not read a session's variables in one request"

        sid = await bridge.create_tab(wid, {"shellforge_task": "live"})

        async def _second_session_ready():
            snap = [s for s in await bridge.snapshot() if s.window_id == wid]
            if len(snap) == 2 and snap[1].cwd == str(tmp_path) and sid in opened:
                return snap
            return None

        snap = await _wait_until(_second_session_ready)
        assert len(snap) == 2 and snap[1].cwd == str(tmp_path) and sid in opened
    finally:
        await bridge.close_window(wid)


async def _append(lst, sid):
    lst.append(sid)
