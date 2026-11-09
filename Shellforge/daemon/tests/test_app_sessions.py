import asyncio
import subprocess
import sys
from pathlib import Path

import pytest

from shellforged.app_sessions import AppSessions, parse_sessions
from shellforged.rpc_server import RpcError
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


def test_the_agent_id_and_terminal_signals_parse_and_default_to_none():
    got = parse_sessions({"sessions": [{**SESSION, "agentId": "gemini", "outputBytes": 10, "attention": 2}]})[0]
    assert (got.custom_agent, got.output_bytes, got.attention) == ("gemini", 10, 2)
    bare = parse_sessions({"sessions": [SESSION]})[0]
    assert (bare.custom_agent, bare.output_bytes, bare.attention) == (None, None, None)


@pytest.mark.parametrize("extra", [{"outputBytes": -1}, {"outputBytes": True}, {"attention": "3"}, {"attention": -1}, {"agentId": 5}])
def test_a_wrong_agent_id_or_signal_is_bad_params(extra):
    with pytest.raises(RpcError) as raised:
        parse_sessions({"sessions": [{**SESSION, **extra}]})
    assert raised.value.code == "bad_params"


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


async def test_an_untagged_tab_does_not_take_another_tabs_task_from_the_shared_window(app_stack):
    """Shellforge keeps every task's tabs in one window and tags each tab itself. AiTerm's tabs
    inherited their window's task because a window was a task; here that would file a plain tab
    under whichever task was listed last."""
    svc, r, w = app_stack
    tagged = {**SESSION, "sessionId": "A", "taskId": "T1"}
    plain = {**SESSION, "sessionId": "B", "commandLine": "-zsh", "jobPid": None, "taskId": None, "projectId": None}
    await call(r, w, "sessions.update", {"sessions": [tagged, plain]})
    tasks = {s["sessionId"]: s["taskId"] for s in (await call(r, w, "sessions.list", id_=2))["result"]}
    assert tasks == {"A": "T1", "B": None}


class _CountingCodex:
    """Codex's rollouts, counted: how often a tick asked for the account's limits and a thread's files."""

    def __init__(self):
        self.limits = self.threads = 0

    def rate_limits(self):
        self.limits += 1
        return None

    def context_percent(self, thread_id):
        self.threads += 1
        return None

    def tally(self, thread_id):
        return None

    def retain(self, thread_ids):
        pass


@pytest.fixture
def throttled(make_service, monkeypatch):
    """An app-fed service, not started -- no poll loop ticks beside the test -- on a monotonic clock
    the test moves, with every Claude transcript read and Codex read counted."""
    now = [100.0]
    svc = make_service(iterm=AppSessions(), monotonic=lambda: now[0])
    svc.codex_files = codex = _CountingCodex()
    reads = []
    monkeypatch.setattr(svc.claude_tallies, "tally", lambda transcript: reads.append(transcript))
    return svc, now, reads, codex


async def test_a_retitle_alone_reads_the_agents_files_at_most_once_per_poll(throttled):
    """The app sends sessions.update on every tab-title change, and Claude's spinner retitles its tab
    several times a second: each is applied and published at once, but the transcripts and rollouts
    are read no more often than the poll would read them."""
    from shellforged.service import POLL_SECONDS
    svc, now, reads, codex = throttled
    await svc._h_sessions_update({"sessions": [SESSION]})
    svc.registry.set_transcript("GUID-1", "/t/s.jsonl")
    await svc._h_sessions_update({"sessions": [SESSION]})
    assert reads == ["/t/s.jsonl"], "a new transcript is read at once"
    limits = codex.limits
    for i in range(20):
        now[0] += 0.05
        await svc._h_sessions_update({"sessions": [{**SESSION, "title": f"✳ claude {i}"}]})
        assert svc.registry.get("GUID-1").title == f"✳ claude {i}"
    assert reads == ["/t/s.jsonl"] and codex.limits == limits
    now[0] += POLL_SECONDS
    await svc._h_sessions_update({"sessions": [{**SESSION, "title": "✳ claude"}]})
    assert reads == ["/t/s.jsonl"] * 2 and codex.limits == limits + 1


# A new tab, another conversation in the same tab, or another agent leave the old transcript behind:
# only the tab whose cwd moved still has it to read.
@pytest.mark.parametrize("change,transcript_read", [
    ({"sessionId": "GUID-2"}, False),  # a new tab, and the old one closed
    ({"cwd": "/repo/.worktrees/y"}, True),
    ({"jobPid": 4343}, False),
    ({"commandLine": "codex", "jobPid": None}, False),
])
async def test_a_real_change_to_a_tab_reads_its_files_at_once(throttled, change, transcript_read):
    svc, now, reads, codex = throttled
    await svc._h_sessions_update({"sessions": [SESSION]})
    svc.registry.set_transcript("GUID-1", "/t/s.jsonl")
    await svc._h_sessions_update({"sessions": [SESSION]})
    limits, before = codex.limits, len(reads)
    now[0] += 0.05
    await svc._h_sessions_update({"sessions": [{**SESSION, **change}]})
    assert codex.limits == limits + 1
    assert len(reads) == before + transcript_read


async def test_a_poll_or_a_hook_tick_still_reads_the_files_every_time(throttled):
    svc, now, reads, codex = throttled
    await svc._h_sessions_update({"sessions": [SESSION]})
    svc.registry.set_transcript("GUID-1", "/t/s.jsonl")
    await svc.tick()
    await svc.tick()
    assert reads == ["/t/s.jsonl"] * 2


async def test_a_full_tick_asked_for_during_a_throttled_one_is_not_served_by_it(throttled):
    """Callers queued behind a tick share the next; one that wants the files read must not take a
    retitle's tick, which skipped them, as its own."""
    svc, now, reads, codex = throttled
    await svc._h_sessions_update({"sessions": [SESSION]})
    svc.registry.set_transcript("GUID-1", "/t/s.jsonl")
    await svc.tick()
    now[0] += 0.05
    gate = asyncio.Event()
    real_snapshot = svc.iterm.snapshot

    async def held_snapshot():
        await gate.wait()
        return await real_snapshot()

    svc.iterm.snapshot = held_snapshot
    first = asyncio.create_task(svc._h_sessions_update({"sessions": [{**SESSION, "title": "a"}]}))
    await asyncio.sleep(0)
    light = asyncio.create_task(svc._h_sessions_update({"sessions": [{**SESSION, "title": "b"}]}))
    full = asyncio.create_task(svc.tick())
    await asyncio.sleep(0)
    gate.set()
    await asyncio.gather(first, light, full)
    assert reads == ["/t/s.jsonl"] * 2, "the full tick read the transcript"
