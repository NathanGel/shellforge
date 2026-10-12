"""The daemon's half of the wire contract with the app: a golden frame of every event, every reply
and every error code, as a running daemon sends them to an attached app, and a manifest of the
protocol's names, written to tests/wire/. The app's WireContractTests decodes each frame with its
production decoders and checks its own names against the manifest, so a change to a model, an
event or a method that the other side was not changed for fails one suite or the other.

The fixtures are checked in, and this test fails while they differ from what the daemon emits. To
regenerate them after a deliberate change to the wire, run (from daemon/)

    SHELLFORGE_UPDATE_WIRE_FIXTURES=1 .venv/bin/pytest tests/test_wire_contract.py

then run the app's WireContractTests against them before committing both.

They live here rather than in app/Tests: they are the daemon's output, written by its suite; they
sit outside every SwiftPM target, so no target has to declare them as resources; and they are
outside the `shellforged` package, so nothing ships them in the app bundle."""
from __future__ import annotations
import asyncio
import json
import os
from collections.abc import Callable
from pathlib import Path
from typing import Any, get_args

from shellforged import protocol, service
from shellforged.models import AgentKind, State
from tests.conftest import wait_until
from tests.fake_iterm import FakeIterm
from shellforged.app_sessions import AppSessions

WIRE = Path(__file__).parent / "wire"
UPDATE = "SHELLFORGE_UPDATE_WIRE_FIXTURES"
FRAME = {"x": 324, "y": 36, "w": 1104, "h": 852}
TASK_ID = "2F9C4B7E-5A1D-4C3B-9E8F-0A1B2C3D4E5F"
PROJECT_ID = "7D6E5F4A-3B2C-4D1E-8F9A-0B1C2D3E4F5A"
WORKTREE = "/repo/.worktrees/feat-wire"
REFUSAL = "execution error: Not authorized to send Apple events to iTerm2. (-1743)"


class App:
    """The app's end of the daemon's socket: every line it is sent, in the order sent."""

    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        self.writer = writer
        self.lines: list[dict[str, Any]] = []
        self._next_id = 0
        self._arrived = asyncio.Event()
        self._reading = asyncio.get_running_loop().create_task(self._read(reader))

    async def _read(self, reader: asyncio.StreamReader) -> None:
        while line := await reader.readline():
            self.lines.append(json.loads(line))
            self._arrived.set()

    async def first(self, after: int, matches: Callable[[dict[str, Any]], bool]) -> dict[str, Any]:
        """The first line sent after `after` (a `mark()`) that `matches`."""
        async def found() -> dict[str, Any]:
            while True:
                if line := next((m for m in self.lines[after:] if matches(m)), None):
                    return line
                self._arrived.clear()
                await self._arrived.wait()
        return await asyncio.wait_for(found(), 2)

    async def call(self, method: str, params: Any = None) -> dict[str, Any]:
        """The reply to one request, sent as the app sends it."""
        self._next_id += 1
        request_id = self._next_id
        await self.send(json.dumps({"id": request_id, "method": method, "params": params}))
        return await self.first(0, lambda m: "event" not in m and m.get("id") == request_id)

    async def send(self, line: str) -> None:
        self.writer.write(line.encode() + b"\n")
        await self.writer.drain()

    def mark(self) -> int:
        return len(self.lines)

    async def event(self, name: str, after: int = 0) -> dict[str, Any]:
        """The first `name` event sent after `after` (a `mark()`)."""
        return await self.first(after, lambda m: m.get("event") == name)

    async def close(self) -> None:
        self.writer.close()
        self._reading.cancel()
        await asyncio.gather(self._reading, return_exceptions=True)


async def emitted(make_service, monkeypatch) -> dict[str, str]:
    """Every fixture file's name and content, from one scripted run of a real daemon over a
    FakeIterm: the app attaches while iTerm2 refuses the cookie it was given, connects with the
    next, opens a task window with a PI tab and a terminal, closes the terminal, and loses iTerm2.
    Each frame is taken as the app receives it. Ids are FakeIterm's counters and the request ids
    the script sends; the clock is make_service's, stopped at 1000."""
    # Only this script ticks: a poll between its steps would make what each event carries depend
    # on timing.
    monkeypatch.setattr(service, "POLL_SECONDS", 3600)

    async def no_pause(_seconds: float) -> None:
        await asyncio.sleep(0)

    iterm = FakeIterm(connected=False)
    svc = make_service(iterm=iterm, supervisor={"cookies_from_app": True, "apply_cookie": lambda cookie, key: None,
                                                "reconnect_sleep": no_pause})
    await svc.start()
    app = App(*await asyncio.open_unix_connection(svc.rpc.path))
    events: dict[str, dict[str, Any]] = {}
    replies: dict[str, dict[str, Any]] = {}
    errors: dict[str, dict[str, Any]] = {}
    try:
        # Refused. The first cookie request went out before the app attached, so it learns of it
        # from its snapshot, as the app does; the refusal of that cookie brings the next request.
        assert (await app.call("workspace.snapshot"))["result"]["itermCookieRequest"] == 1
        mark = app.mark()
        replies["iterm.provideCookie"] = await app.call("iterm.provideCookie", {"requestId": 1, "error": REFUSAL})
        events[protocol.ITERM_AUTH_FAILED] = await app.event(protocol.ITERM_AUTH_FAILED, mark)
        events[protocol.ITERM_COOKIE_REQUESTED] = await app.event(protocol.ITERM_COOKIE_REQUESTED, mark)
        replies["workspace.snapshot.refused"] = await app.call("workspace.snapshot")
        errors[protocol.ITERM_UNAVAILABLE] = await app.call("window.activate", {"windowId": "w1"})

        # Connected.
        await iterm.reconnect()
        mark = app.mark()
        await app.call("iterm.provideCookie", {"requestId": 2, "cookie": "cookie", "key": "key"})
        events[protocol.ITERM_CONNECTED] = await app.event(protocol.ITERM_CONNECTED, mark)
        replies["iterm.status"] = await app.call("iterm.status")

        mark = app.mark()
        replies["window.createTask"] = await app.call("window.createTask", {
            "taskId": TASK_ID, "cwd": WORKTREE, "title": "feat-wire", "agentCommand": "pi", "frame": FRAME})
        task_window = replies["window.createTask"]["result"]["windowId"]
        await iterm.settle()
        events[protocol.SESSION_OPENED] = await app.event(protocol.SESSION_OPENED, mark)
        replies["tab.create"] = await app.call("tab.create", {"windowId": task_window, "cwd": WORKTREE})
        replies["window.createTerminal"] = await app.call("window.createTerminal", {
            "projectId": PROJECT_ID, "cwd": "/repo", "title": "Logs", "frame": FRAME})
        terminal_window = replies["window.createTerminal"]["result"]["windowId"]
        await iterm.settle()

        # PI starts a turn in the task's first tab, reporting everything a session can carry.
        pi = iterm.windows[task_window]["sessions"][0]
        await iterm.user_runs(pi, "pi", job_pid=4242, title="pi")
        await svc.tick()
        mark = app.mark()
        await svc.hook_router.handle_hook("/hook/pi", {
            "hook_event_name": "agent_start", "session_id": "pi-wire", "cwd": WORKTREE + "/app", "model": "claude-opus-5",
            "reasoning": "high", "context_percent": 42,
            "tokens": {"input": 936018, "cached": 935988, "output": 5625}, "_shellforge_iterm_session_id": pi})
        events[protocol.SESSION_CHANGED] = await app.event(protocol.SESSION_CHANGED, mark)

        mark = app.mark()
        await svc.hook_router.handle_hook("/statusline", {"rate_limits": {
            "five_hour": {"used_percentage": 23.4, "resets_at": 1_790_000_000},
            "seven_day": {"used_percentage": 61, "resets_at": 1_790_400_000},
            "spend_limit": {"used_percentage": 5}}})
        events[protocol.USAGE_CHANGED] = await app.event(protocol.USAGE_CHANGED, mark)

        mark = app.mark()
        await iterm.user_activates_window(terminal_window)
        events[protocol.WINDOW_ACTIVATED] = await app.event(protocol.WINDOW_ACTIVATED, mark)

        replies["window.activate"] = await app.call("window.activate", {"windowId": task_window})
        replies["window.setFrame"] = await app.call("window.setFrame", {"windowId": task_window, "frame": FRAME})
        replies["sessions.setTitles"] = await app.call("sessions.setTitles", {"titles": [{"sessionId": pi, "title": "feat/wire"}]})
        replies["sessions.markSeen"] = await app.call("sessions.markSeen", {"taskId": TASK_ID})
        replies["interface.setMatchItermBackground"] = await app.call("interface.setMatchItermBackground", {"matchItermBackground": True})
        replies["sessions.list"] = await app.call("sessions.list")
        replies["usage.get"] = await app.call("usage.get")
        # A tunnel whose ssh is not on the handed-in PATH: it fails at once, the same way every run.
        replies["tunnels.start"] = await app.call("tunnels.start", {"alias": "db-staging", "environment": {"PATH": "/nonexistent"}})
        events[protocol.TUNNEL_CHANGED] = await app.event(protocol.TUNNEL_CHANGED, mark)
        await wait_until(lambda: svc.tunnels.list()[0]["state"] == "failed")
        replies["tunnels.list"] = await app.call("tunnels.list")
        replies["workspace.snapshot"] = await app.call("workspace.snapshot")
        replies["tunnels.stop"] = await app.call("tunnels.stop", {"alias": "db-staging"})
        # Held by a tab whose port nothing listens on yet: watched, then stopped.
        replies["tunnels.hold"] = await app.call("tunnels.hold", {"alias": "db-staging", "port": 1})
        await app.call("tunnels.stop", {"alias": "db-staging"})

        mark = app.mark()
        replies["window.close"] = await app.call("window.close", {"windowId": terminal_window})
        events[protocol.SESSION_CLOSED] = await app.event(protocol.SESSION_CLOSED, mark)
        events[protocol.WINDOW_CLOSED] = await app.event(protocol.WINDOW_CLOSED, mark)

        errors[protocol.NOT_FOUND] = await app.call("window.activate", {"windowId": "w999"})
        errors[protocol.BAD_PARAMS] = await app.call("window.activate", {})
        errors[protocol.UNKNOWN_METHOD] = await app.call("window.minimize", {"windowId": task_window})

        async def broken(window_id: str, frame: Any) -> None:
            raise RuntimeError("iTerm2 sent a reply the daemon could not read")

        iterm.set_frame = broken  # type: ignore[method-assign]
        errors[protocol.INTERNAL] = await app.call("window.setFrame", {"windowId": task_window, "frame": FRAME})
        mark = app.mark()
        await app.send("[]")
        errors[protocol.PROTOCOL] = await app.first(mark, lambda m: "error" in m and m.get("id") is None)

        mark = app.mark()
        await iterm.disconnect()
        events[protocol.ITERM_DISCONNECTED] = await app.event(protocol.ITERM_DISCONNECTED, mark)

        # Shellforge's own source: the app sends its tabs instead of the daemon reading iTerm2.
        app_svc = make_service(iterm=AppSessions())
        await app_svc.start()
        shellforge = App(*await asyncio.open_unix_connection(app_svc.rpc.path))
        try:
            replies["sessions.update"] = await shellforge.call("sessions.update", {"sessions": [{
                "sessionId": "SESSION-GUID", "windowId": "w1", "tabIndex": 0, "commandLine": "pi", "jobPid": 4242,
                "title": "pi", "cwd": WORKTREE, "active": True, "taskId": TASK_ID, "projectId": PROJECT_ID}]})
        finally:
            await shellforge.close()
        methods = svc.rpc.methods
    finally:
        await app.close()

    assert sorted(events) == sorted(protocol.EVENTS), "every event has a fixture"
    assert sorted(errors) == sorted(protocol.ERROR_CODES), "every error code has a fixture"
    assert {name.removesuffix(".refused") for name in replies} == set(methods), "every method has a fixture"

    files = {f"event.{name}.json": frame for name, frame in events.items()}
    files |= {f"reply.{name}.json": frame for name, frame in replies.items()}
    files |= {f"error.{code}.json": frame for code, frame in errors.items()}
    files["manifest.json"] = {
        "protocolVersion": protocol.VERSION, "maxFrameBytes": protocol.MAX_FRAME_BYTES,
        "events": sorted(protocol.EVENTS), "methods": methods, "errorCodes": sorted(protocol.ERROR_CODES),
        # The raw values a session's `agent` and `state` can take: the app reads one it does not
        # know as a shell or as idle, so a new one would otherwise go unnoticed.
        "sessionAgents": sorted(get_args(AgentKind)), "sessionStates": sorted(get_args(State)),
        # Which files show each name: a reply can have more than one, a snapshot both refused and connected.
        "fixtures": {
            "events": {name: f"event.{name}.json" for name in sorted(events)},
            "replies": {method: sorted(f"reply.{name}.json" for name in replies if name.removesuffix(".refused") == method)
                        for method in methods},
            "errors": {code: f"error.{code}.json" for code in sorted(errors)},
        },
    }
    return {name: json.dumps(content, indent=2, sort_keys=True, ensure_ascii=False) + "\n" for name, content in sorted(files.items())}


async def test_the_checked_in_wire_fixtures_are_what_the_daemon_sends(make_service, monkeypatch):
    fixtures = await emitted(make_service, monkeypatch)
    if os.environ.get(UPDATE):
        WIRE.mkdir(exist_ok=True)
        for stale in WIRE.glob("*.json"):
            if stale.name not in fixtures:
                stale.unlink()
        for name, content in fixtures.items():
            (WIRE / name).write_text(content, encoding="utf-8")
        return
    on_disk = {path.name: path.read_text(encoding="utf-8") for path in WIRE.glob("*.json")}
    missing = sorted(set(fixtures) - set(on_disk))
    extra = sorted(set(on_disk) - set(fixtures))
    changed = sorted(name for name in set(fixtures) & set(on_disk) if fixtures[name] != on_disk[name])
    assert not (missing or extra or changed), (
        f"tests/wire/ is not what the daemon sends (missing {missing}, no longer sent {extra}, changed {changed}). "
        f"If the change is meant, run `{UPDATE}=1 .venv/bin/pytest tests/test_wire_contract.py` from daemon/, "
        "then the app's WireContractTests, and commit the fixtures with the change.")


async def test_the_fixtures_come_out_the_same_on_every_run(make_service, monkeypatch):
    """Nothing in them depends on timing or the machine, or the check above would fail at random."""
    assert await emitted(make_service, monkeypatch) == await emitted(make_service, monkeypatch)

