import asyncio
import subprocess
import sys
from pathlib import Path

import pytest

from shellforged.app_sessions import AppSessions
from tests.test_service import call

SESSION = {"sessionId": "GUID-1", "windowId": "w1", "tabIndex": 0, "commandLine": "claude --model opus",
           "jobPid": 4242, "title": "claude", "cwd": "/repo/.worktrees/x", "active": True,
           "taskId": "t1", "projectId": "p1"}


@pytest.fixture
async def app_stack(make_service):
    svc = make_service(iterm=AppSessions())
    await svc.start()
    r, w = await asyncio.open_unix_connection(svc.rpc.path)
    yield svc, r, w
    w.close()


async def test_an_update_is_what_the_daemon_tracks(app_stack):
    svc, r, w = app_stack
    assert (await call(r, w, "sessions.update", {"sessions": [SESSION]}))["result"] == {"ok": True}
    sessions = (await call(r, w, "sessions.list", id_=2))["result"]
    assert [(s["sessionId"], s["taskId"], s["agent"], s["cwd"]) for s in sessions] == \
        [("GUID-1", "t1", "claude", "/repo/.worktrees/x")]


async def test_a_tab_left_out_of_the_next_update_is_forgotten(app_stack):
    svc, r, w = app_stack
    await call(r, w, "sessions.update", {"sessions": [SESSION]})
    await call(r, w, "sessions.update", {"sessions": []}, id_=2)
    assert (await call(r, w, "sessions.list", id_=3))["result"] == []


async def test_a_malformed_update_is_refused_and_the_last_list_kept(app_stack):
    svc, r, w = app_stack
    await call(r, w, "sessions.update", {"sessions": [SESSION]})
    reply = await call(r, w, "sessions.update", {"sessions": [{"sessionId": 7}]}, id_=2)
    assert reply["error"]["code"] == "bad_params"
    assert [s["sessionId"] for s in (await call(r, w, "sessions.list", id_=3))["result"]] == ["GUID-1"]


async def test_a_hook_that_names_its_session_is_placed_on_it(app_stack):
    svc, r, w = app_stack
    await call(r, w, "sessions.update", {"sessions": [{**SESSION, "commandLine": "codex", "jobPid": None}]})
    await svc.hook_router.handle_hook("/hook/codex", {"hook_event_name": "UserPromptSubmit", "session_id": "c1",
                                                "_shellforge_iterm_session_id": "w0t0p0:GUID-1", "cwd": "/repo/.worktrees/x"})
    assert (await call(r, w, "sessions.list", id_=2))["result"][0]["state"] == "working"


async def test_a_hook_before_the_first_update_is_placed_once_the_list_arrives(app_stack):
    svc, r, w = app_stack
    post = asyncio.create_task(svc.hook_router.handle_hook(
        "/hook/codex", {"hook_event_name": "UserPromptSubmit", "session_id": "c1",
                  "_shellforge_iterm_session_id": "w0t0p0:GUID-1", "cwd": "/repo/.worktrees/x"}))
    await asyncio.sleep(0)
    await call(r, w, "sessions.update", {"sessions": [{**SESSION, "commandLine": "codex", "jobPid": None}]})
    await post
    assert (await call(r, w, "sessions.list", id_=2))["result"][0]["state"] == "working"


def test_the_daemon_starts_without_the_iterm2_package(tmp_path):
    daemon = Path(__file__).resolve().parents[1]
    blocker = tmp_path / "iterm2.py"
    blocker.write_text("raise ImportError('iterm2 must not be imported')\n")
    code = ("import sys; sys.argv=['shellforged','run','--help']\n"
            "from shellforged.__main__ import main\n"
            "import shellforged.app_sessions, shellforged.service\n"
            "assert 'iterm2' not in sys.modules\n")
    out = subprocess.run([sys.executable, "-c", code], cwd=daemon, env={"PYTHONPATH": f"{tmp_path}:{daemon}"},
                         capture_output=True, text=True, timeout=60)
    assert out.returncode == 0, out.stderr


async def test_a_list_that_arrives_while_a_second_hook_waits_its_turn_is_not_missed(app_stack):
    """Two new tabs' first hooks, 50 ms apart: the second waits out the router's retick floor, and the
    app's list arrives meanwhile. It must be placed from that list, not after a further 2 s wait."""
    svc, r, w = app_stack
    loop = asyncio.get_running_loop()

    def hook(guid: str) -> dict:
        return {"hook_event_name": "UserPromptSubmit", "session_id": guid, "cwd": "/tmp",
                "_shellforge_iterm_session_id": f"w0t0p0:{guid}"}

    first = asyncio.create_task(svc.hook_router.handle_hook("/hook/codex", hook("A")))
    await asyncio.sleep(0.05)
    started = loop.time()
    second = asyncio.create_task(svc.hook_router.handle_hook("/hook/codex", hook("B")))
    await asyncio.sleep(0.2)
    tabs = [{**SESSION, "sessionId": guid, "commandLine": "codex", "jobPid": None, "taskId": None} for guid in ("A", "B")]
    await call(r, w, "sessions.update", {"sessions": tabs})
    await asyncio.gather(first, second)
    assert loop.time() - started < 1.8
    states = {s["sessionId"]: s["state"] for s in (await call(r, w, "sessions.list", id_=2))["result"]}
    assert states == {"A": "working", "B": "working"}
