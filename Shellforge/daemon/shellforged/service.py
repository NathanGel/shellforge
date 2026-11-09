# daemon/shellforged/service.py
from __future__ import annotations
import asyncio
import logging
import time
from pathlib import Path
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from typing import Any, TypeVar

from . import protocol
from .auto_status import AutoStatus
from .claude_sessions import ClaudeSessionFiles
from .claude_subagents import SubagentTranscripts, TranscriptTail
from .claude_tokens import ClaudeTranscriptTallies
from .codex_sessions import CodexSessionFiles
from .connection import ItermSupervisor
from .hook_router import HookRouter
from .hooks_server import HookServer
from .iterm_port import ItermPort, ItermUnavailable
from .launch_env import TAKE_WAIT_SECONDS, LaunchEnvironments
from .offload import run_detached
from .publisher import Publisher
from .resolver import SessionResolver
from .rpc_params import frame_param, guard, optional_param, param, require_iterm
from .proc_tty import controlling_tty
from .rpc_server import Caller, RpcError, RpcServer
from .models import HARNESS_BY_AGENT, SessionInfo, TokenTally
from .sessions import SessionRegistry, SnapshotDiff
from .status import StatusEngine, path_is_missing
from .usage import UsageStore, parse_codex_rate_limits
from .windows import WindowManager

log = logging.getLogger(__name__)


@contextmanager
def _logged(step: str) -> Iterator[None]:
    """Runs a step that must not stop the ones after it: a failure is logged and the caller carries on."""
    try:
        yield
    except Exception:  # noqa: BLE001 - the steps after it are independent of it
        log.exception("%s failed", step)


POLL_SECONDS = 2.0
# How long `stop` waits for the poll loop after each cancel, and how many cancels it sends.
STOP_WAIT_SECONDS = 0.4  # x3 stays under the app's 2 s grace before it kills the daemon
STOP_CANCEL_ATTEMPTS = 3
# With no agent in any session there is nothing a poll would find every 2 s: Codex's rate limits
# for the footer are read this often instead. A hook or a sessions.update still ticks at once.
IDLE_POLL_SECONDS = 10.0
# How long a tick waits for a check it runs on a worker thread: the orphan directories, the subagent
# transcripts, the Codex rollouts.
OFF_LOOP_CHECK_SECONDS = 1.0
# Both of a tick's Codex reads -- the account's rate limits and the sessions' context fill and spend -- run
# under this one off-loop name. They share CodexSessionFiles' caches, which nothing locks, so a read
# still stuck from an earlier tick holds back the other kind as well, rather than race it on a
# second worker thread.
CODEX_READ = "the Codex rollout read"
# A tick's Claude transcript reads, which share ClaudeTranscriptTallies' cursors: a read still stuck
# from an earlier tick holds the next one back rather than race it on a second worker thread.
CLAUDE_READ = "the Claude transcript read"

T = TypeVar("T")
# Each tab's (session id, agent, job pid, cwd, agent cwd, transcript), and the Codex thread each runs.
_FilesKey = tuple[frozenset[tuple[str, str, int | None, str, str | None, str | None]], frozenset[tuple[str, str]]]


#: How long a hook that placed nowhere waits for the app's next session list before re-reading.
APP_UPDATE_WAIT_SECONDS = 2.0


class Service:
    """The daemon's composition root: builds the registry, status engine and usage store, wires
    the supervisor, the hook router and the window manager to them, answers the RPC methods none
    of those own, and polls iTerm2 into the registry."""

    def __init__(self, iterm: ItermPort, rpc: RpcServer, hooks: HookServer, claude_files: ClaudeSessionFiles,
                 clock: Callable[[], float], codex_files: CodexSessionFiles | None = None,
                 supervisor: ItermSupervisor | None = None, path_missing: Callable[[str], bool] = path_is_missing,
                 monotonic: Callable[[], float] = time.monotonic, tunnel_ledger: Path | None = None,
                 tty_of: Callable[[int], int | None] = controlling_tty):
        self.iterm, self.rpc, self.hooks = iterm, rpc, hooks
        # `clock` is the wall clock, in seconds. Fractional: the status engine stamps each hook with
        # it and compares the stamp with a session file's mtime, which a whole second would blur.
        # `monotonic` times the orphan settle, and `path_missing` is its directory check, which runs
        # on a worker thread: a stat on a hung network mount must not stall the daemon.
        self.claude_files, self.codex_files, self.clock = claude_files, codex_files, clock
        self.supervisor = supervisor or ItermSupervisor(iterm, rpc.broadcast, lambda: rpc.client_count)
        from .app_sessions import AppSessions
        self.registry = SessionRegistry(inherit_window_tags=not isinstance(iterm, AppSessions))
        self.status = StatusEngine(self.registry, clock, monotonic)
        self.auto_status = AutoStatus(monotonic)
        self.usage = UsageStore()
        self.resolver = SessionResolver(self.registry, claude_files)
        self.publisher = Publisher(rpc.broadcast, self.registry, self.usage)
        self.hook_router = HookRouter(self.resolver, self.status, self.usage, clock, self.publisher, tick=self._tick_for_hooks)
        self.hooks.on_post = self.hook_router.handle_hook
        self.windows = WindowManager(iterm, self.registry, self.tick)
        self.supervisor.on_connected = self.windows.forget_titles
        from .tunnels import TunnelSupervisor
        self.tunnels = TunnelSupervisor(rpc.broadcast, clock=clock, ledger=tunnel_ledger)
        self.launches = LaunchEnvironments(monotonic)
        # A process's controlling terminal: an armed launch is taken only from the tab's own.
        self._tty_of = tty_of
        self._poll_task: asyncio.Task[None] | None = None
        self._stopping = False
        self._stop_cancels = 0  # cancels `stop` has sent, for the test of the normal case
        # window.setFrame and window.activate each leave a state the next one replaces, and the app
        # sends them from separate tasks; requests are answered concurrently, so they take this in
        # turn, in the order they came, and the last one sent is the one that stays.
        self._placement_lock = asyncio.Lock()
        self._tick_lock = asyncio.Lock()
        # Ticks started so far, and the number of the last to finish without raising: a tick whose
        # caller asked before another started and finished has nothing left to read.
        self._ticks_started = 0
        # The poll loop's current sleep, and the event that cuts it short.
        self._sleeping_for = POLL_SECONDS
        self._poll_sooner = asyncio.Event()
        self._last_good_tick = 0
        # The same for the last tick that read the agents' files: a retitle's tick may skip them.
        self._last_good_read_tick = 0
        # When the agents' files were last read, on `monotonic`, and what the tabs were then: a
        # sessions.update reads them again only once POLL_SECONDS have passed or that has changed.
        self._monotonic = monotonic
        self._files_read_at = float("-inf")
        self._files_read_for: _FilesKey | None = None
        self._path_missing = path_missing
        self.subagent_transcripts = SubagentTranscripts()
        self.claude_tallies = ClaudeTranscriptTallies()
        # The Codex thread each tab ran at the last tick, by session: a tab that moves to a thread with
        # no totals yet (/new, /resume) must drop the old thread's, which no reading replaces.
        self._codex_threads: dict[str, str] = {}
        # Each off-loop check's latest run, by name, while its worker thread may still be running: a
        # thread stuck on a hung mount cannot be cancelled, so no second one is started beside it.
        self._checks: dict[str, asyncio.Future[Any]] = {}
        # When the last re-read for unplaced hooks began, on the event loop's clock.
        self._hook_tick_started = float("-inf")
        self._register_handlers()

    # -- lifecycle ---------------------------------------------------------
    async def start(self) -> None:
        self.iterm.on_new_session(self.windows.on_new_session)
        self.iterm.on_session_closed(self._on_session_closed)
        self.iterm.on_window_activated(self._on_window_activated)
        # Before any app can ask: the tunnels the last daemon left keep their state, the rest end.
        await self.tunnels.adopt()
        await self.rpc.start()
        try:
            await self.hooks.start()
        except BaseException:
            await self.rpc.stop()
            raise
        await self.supervisor.start()
        self._stopping = False
        self._poll_task = asyncio.get_running_loop().create_task(self._poll_forever())

    async def stop(self) -> None:
        # Before anything else: no ssh the app started may outlive it holding its ports.
        await self.tunnels.stop_all()
        self._stopping = True
        if (task := self._poll_task) is not None and task is not asyncio.current_task():
            # A cancel can be swallowed (wait_for racing the event it waits on), so it is repeated
            # while the task lives, and the wait for it is bounded: a stop never hangs on the loop.
            for _ in range(STOP_CANCEL_ATTEMPTS):
                self._stop_cancels += 1
                task.cancel()
                done, _pending = await asyncio.wait({task}, timeout=STOP_WAIT_SECONDS)
                if done:
                    break
            else:
                log.error("the poll loop did not stop")
            if task.done() and not task.cancelled():
                task.exception()  # retrieved, so it is not reported as never read
        await self.supervisor.stop()
        await self.hooks.stop()
        await self.rpc.stop()

    def poll_interval(self) -> float:
        """2 s while any session runs an agent, else 10 s."""
        return POLL_SECONDS if any(s.agent != "shell" for s in self.registry.all()) else IDLE_POLL_SECONDS

    async def _poll_forever(self) -> None:
        while not self._stopping:
            try:
                await self.tick()
            except Exception:  # noqa: BLE001
                log.exception("tick failed")
            self._sleeping_for = self.poll_interval()
            # Another tick that finds an agent while this one sleeps the idle 10 s ends that sleep
            # and starts the 2 s an agent gets: the next poll comes within it, as it would have.
            try:
                await asyncio.wait_for(self._poll_sooner.wait(), timeout=self._sleeping_for)
            except TimeoutError:
                pass
            else:
                self._poll_sooner.clear()
                if self._stopping:
                    return
                await asyncio.sleep(POLL_SECONDS)

    # -- RPC ---------------------------------------------------------------
    def _register_handlers(self) -> None:
        r = self.rpc.register
        r("iterm.status", self.supervisor.status)
        r("iterm.provideCookie", self.supervisor.provide_cookie)
        r("workspace.snapshot", self._h_snapshot)
        r("window.createTask", self.windows.create_task)
        r("window.createTerminal", self.windows.create_terminal)
        r("window.activate", self._h_activate)
        r("window.setFrame", self._h_set_frame)
        r("window.close", self._h_close)
        r("tab.create", self.windows.create_tab)
        r("sessions.list", self._h_sessions_list)
        r("sessions.update", self._h_sessions_update)
        r("sessions.setTitles", self.windows.set_titles)
        r("sessions.markSeen", self._h_mark_seen)
        r("usage.get", self._h_usage_get)
        r("interface.setMatchItermBackground", self.windows.set_match_iterm_background)
        r("tunnels.start", self._h_tunnels_start)
        r("tunnels.stop", self._h_tunnels_stop)
        r("tunnels.list", self._h_tunnels_list)
        r("tunnels.hold", self._h_tunnels_hold)
        r("agents.armLaunch", self._h_arm_launch)
        self.rpc.register_with_caller("agents.takeLaunch", self._h_take_launch)

    async def _h_snapshot(self, _p: Any) -> dict[str, Any]:
        try:
            await self.tick()
        except Exception:  # noqa: BLE001 - the last known registry beats no bootstrap at all
            log.exception("tick failed")
        # No await between reading state and returning it. RpcServer writes the reply
        # before yielding, making it a barrier between earlier and later events.
        return {"protocolVersion": protocol.VERSION, **self.supervisor.snapshot_fields(),
                "sessions": [s.to_json() for s in self.registry.all()],
                "tunnels": self.tunnels.list(),
                "usage": self.usage.snapshot()}

    async def _h_activate(self, p: Any) -> dict[str, Any]:
        window_id = param(p, "windowId", str)
        async with self._placement_lock:
            require_iterm(self.iterm)
            await guard(self.iterm.activate_window(window_id))
        return {}

    async def _h_set_frame(self, p: Any) -> dict[str, Any]:
        window_id, frame = param(p, "windowId", str), frame_param(p)
        async with self._placement_lock:
            require_iterm(self.iterm)
            await guard(self.iterm.set_frame(window_id, frame))
        return {}

    async def _h_close(self, p: Any) -> dict[str, Any]:
        window_id = param(p, "windowId", str)
        require_iterm(self.iterm)
        await guard(self.iterm.close_window(window_id))
        try:
            await self.tick()
        except Exception:  # noqa: BLE001 - the window is closed either way; the next tick sees it
            log.exception("tick after closing a window failed")
        return {}

    async def _h_tunnels_start(self, p: Any) -> dict[str, Any]:
        """`{alias, environment}`: the `~/.ssh/config` host to run, and the app's login environment to
        run it in. An alias that ssh would read as an option is refused."""
        alias = tunnel_alias(p)
        environment = param(p, "environment", dict)
        if not all(isinstance(k, str) and isinstance(v, str) for k, v in environment.items()):
            raise RpcError(protocol.BAD_PARAMS, "environment must map strings to strings")
        keep_running = optional_param(p, "keepRunning", bool) or False
        await self.tunnels.start(alias, environment, keep_running)
        return {"ok": True}

    async def _h_tunnels_stop(self, p: Any) -> dict[str, Any]:
        await self.tunnels.stop(tunnel_alias(p))
        return {"ok": True}

    async def _h_tunnels_hold(self, p: Any) -> dict[str, Any]:
        """`{alias, port}`: the app opened the tunnel in a tab for the user to answer ssh; `port` is
        its first local forward, which the daemon watches."""
        alias = tunnel_alias(p)
        port = param(p, "port", int)
        if isinstance(port, bool) or not 1 <= port <= 65535:
            raise RpcError(protocol.BAD_PARAMS, "port must be a TCP port")
        bind = optional_param(p, "bind", str)
        await self.tunnels.hold(alias, port, bind)
        return {"ok": True}

    # Neither of these logs its params, and no error they raise names a value: the environment holds
    # the agent's secrets (`launch_env.py`).
    async def _h_arm_launch(self, p: Any) -> dict[str, Any]:
        """`{sessionId, agentId, environment}`: the app is starting `agentId` in the tab `sessionId`
        through `shellforge-run`, which takes `environment` from here once (`agents.takeLaunch`)."""
        session_id, agent_id = param(p, "sessionId", str), param(p, "agentId", str)
        environment = param(p, "environment", dict)
        if not session_id or not agent_id:
            raise RpcError(protocol.BAD_PARAMS, "sessionId and agentId must not be empty")
        if not all(_is_variable(k, v) for k, v in environment.items()):
            raise RpcError(protocol.BAD_PARAMS, "environment must map variable names to strings without NUL")
        self.launches.arm(session_id, agent_id, environment)
        return {"ok": True}

    async def _h_take_launch(self, p: Any, caller: Caller) -> dict[str, Any]:
        """`{session, agentId}`: `shellforge-run`'s, with the tab's `$ITERM_SESSION_ID`. The environment
        armed for it, once; `not_found` when nothing was armed within TAKE_WAIT_SECONDS, it expired, or
        the caller isn't a process of that tab (`_take_allowed`), which leaves the arm for the tab's own."""
        session, agent_id = param(p, "session", str), param(p, "agentId", str)

        async def allowed(tab: str) -> bool | None:
            return await self._take_allowed(tab, caller)

        environment = await self.launches.take(session, agent_id, timeout=TAKE_WAIT_SECONDS, check=allowed)
        if environment is None:
            raise RpcError(protocol.NOT_FOUND, "nothing armed for this tab and agent")
        return {"environment": environment}

    async def _take_allowed(self, tab: str, caller: Caller) -> bool | None:
        """Whether `caller` may take `tab`'s arm: it is still connected, and its controlling terminal,
        read from its pid as the kernel gave it for the socket, is the terminal of the tab's job. The
        session id alone is no proof: any process of this user can read another tab's environment.
        None while the tab's terminal isn't known (no job pid from the app yet); anything else unknown
        is a no."""
        if caller.gone() or caller.pid is None or (caller_tty := self._tty_of(caller.pid)) is None:
            return False
        try:
            info = await self.iterm.session_info(tab)
        except (ItermUnavailable, KeyError):
            info = None
        tab_tty = self._tty_of(info.job_pid) if info is not None and info.job_pid else None
        if tab_tty is None:
            return None
        # Asked again after the await: a caller that left meanwhile mustn't spend the arm.
        return tab_tty == caller_tty and not caller.gone()

    async def _h_tunnels_list(self, _p: Any) -> list[dict[str, Any]]:
        return self.tunnels.list()

    async def _h_sessions_list(self, _p: Any) -> list[dict[str, Any]]:
        return [s.to_json() for s in self.registry.all()]

    async def _tick_for_hooks(self) -> None:
        """The re-read that hooks which placed nowhere wait for. Each of them arrived after the
        previous such re-read began, so a list from the app that came after that point is newer
        than the one they failed on: re-read at once. Otherwise wait for the next list first; the
        one in hand is the one they already failed on, and no new snapshot comes from iTerm2 here."""
        from .app_sessions import AppSessions
        loop = asyncio.get_running_loop()
        previous, self._hook_tick_started = self._hook_tick_started, loop.time()
        if isinstance(self.iterm, AppSessions) and self.iterm.updated_at <= previous:
            await self.iterm.next_update(timeout=APP_UPDATE_WAIT_SECONDS)
        await self.tick()

    async def _h_sessions_update(self, p: Any) -> dict[str, Any]:
        """The app's tabs, replacing the last list; answered after the tick that reads them. The app
        sends one on every retitle -- Claude's spinner retitles several times a second -- so the tick
        reads the agents' files only when the poll would have, or the tabs changed (`_files_due`)."""
        from .app_sessions import AppSessions, parse_sessions
        sessions = parse_sessions(p)
        if not isinstance(self.iterm, AppSessions):
            raise RpcError(protocol.BAD_PARAMS, "sessions.update needs the app session source")
        self.iterm.replace(sessions)
        self.launches.changed()  # a take waiting to learn its tab's terminal looks again
        await self.tick(light=True)
        return {"ok": True}

    async def _h_mark_seen(self, p: Any) -> dict[str, Any]:
        # A task's sessions by its id, or a terminal's by theirs.
        if (ids := optional_param(p, "sessionIds", list)) is not None:
            if not all(isinstance(i, str) for i in ids):
                raise RpcError(protocol.BAD_PARAMS, "sessionIds must be a list of strings")
            changed = self.status.mark_seen_sessions(ids)
        else:
            changed = self.status.mark_seen(param(p, "taskId", str))
        await self.publisher.session_changed(changed)
        return {"changed": len(changed)}

    async def _h_usage_get(self, _p: Any) -> dict[str, Any]:
        return self.usage.snapshot()

    # -- iTerm2 notifications ------------------------------------------------
    async def _on_window_activated(self, window_id: str) -> None:
        # A macOS notification can bring an iTerm2 window forward without an Shellforge row being
        # clicked. Tell the app which window received focus so it can keep its sidebar selection
        # in sync. The window id is enough: the app owns the task/terminal mapping.
        try:
            await self.rpc.broadcast(protocol.WINDOW_ACTIVATED, {"windowId": window_id})
        except Exception:  # noqa: BLE001 - must not escape into the iTerm2 library's dispatch
            log.exception("on_window_activated failed for %s", window_id)

    async def _on_session_closed(self, session_id: str) -> None:
        try:
            await self.tick()
        except Exception:  # noqa: BLE001 - must not escape into the iTerm2 library's dispatch
            log.exception("on_session_closed failed for %s", session_id)

    # -- polling -------------------------------------------------------------------
    async def tick(self, light: bool = False) -> None:
        """Reads iTerm2 (or the app's list) into the registry and publishes what changed. A `light`
        tick reads the agents' files -- transcripts, rollouts -- only when they are due."""
        # The poll loop, iTerm2 notification callbacks, and RPC handlers can
        # all call tick() concurrently; serialize the whole body so a
        # `windows_before` snapshot taken by one call can't be diffed against
        # a `windows_after` produced by an interleaved call (which double-
        # broadcasts window.closed, among other races).
        #
        # Callers queued behind one tick share the next: it starts after all of them asked, so it
        # reads everything each would have. The running one does not count -- it may have read
        # iTerm2 before the change its caller is waiting to see -- and neither does a failed one.
        # A caller that is not `light` is served only by a tick that read the files.
        asked_after = self._ticks_started
        async with self._tick_lock:
            if (self._last_good_tick if light else self._last_good_read_tick) > asked_after:
                return
            self._ticks_started += 1
            number = self._ticks_started
            read_files = await self._tick(light)
            self._last_good_tick = number
            if read_files:
                self._last_good_read_tick = number
        # An agent found while the poll loop sleeps the idle 10 s: it polls again within 2 s.
        if self.poll_interval() < self._sleeping_for:
            self._sleeping_for = self.poll_interval()
            self._poll_sooner.set()

    async def _tick(self, light: bool) -> bool:
        """One tick's work; whether it read the agents' files. A light one decides that once it
        knows the tabs, after the snapshot, so it reads Codex usage there too."""
        if not light:
            await self._read_codex_usage_logged()
        if not self.iterm.is_connected():
            return not light
        windows_before = {s.window_id for s in self.registry.all()}
        positions_before = {s.session_id: (s.window_id, s.tab_index) for s in self.registry.all()}
        diff = self.registry.apply_snapshot(await self.iterm.snapshot())
        # A session.changed from the snapshot diff is deliberately *not* broadcast as it is found:
        # the status pass can change the same session again in this very tick (its state, its
        # model, the agent's cwd), and two events for one tick make a client redraw twice and,
        # worse, make "the next session.changed" ambiguous. Held back and merged into `changed`, it
        # is re-rendered from the registry once, at the end -- in a `finally`: the registry already
        # holds the snapshot, so a tick that raised without publishing would leave the next one
        # diffing nothing, and the app stale for that session until something else moved it.
        changed = list(diff.changed)
        try:
            return await self._after_snapshot(diff, windows_before, positions_before, changed, light)
        finally:
            await self.publisher.session_changed(changed)

    async def _read_codex_usage_logged(self) -> None:
        try:
            await self._read_codex_usage()
        except Exception:  # noqa: BLE001 - another process's file must not stop session polling
            log.exception("reading Codex usage failed")

    def _files_key(self, threads: dict[str, str]) -> _FilesKey:
        """What decides which of the agents' files a tick reads: each tab's agent, conversation and
        directories, and the Codex thread it runs. Not its title, its position or whether it is current."""
        return (frozenset((s.session_id, s.agent, s.job_pid, s.cwd, s.agent_cwd, s.transcript) for s in self.registry.all()),
                frozenset(threads.items()))

    def _files_due(self, threads: dict[str, str]) -> bool:
        """Whether a light tick reads the agents' files: POLL_SECONDS since they were last read, as
        the poll would, or a tab that opened, closed or moved to another conversation or directory."""
        return (self._monotonic() - self._files_read_at >= POLL_SECONDS
                or self._files_key(threads) != self._files_read_for)

    async def _after_snapshot(self, diff: SnapshotDiff, windows_before: set[str],
                              positions_before: dict[str, tuple[str, int]], changed: list[str], light: bool) -> bool:
        """Announces what the snapshot opened and closed, then reads the corroborating signals, each
        step guarded so one that raises costs only its own changes. Appends to `changed` as it goes.
        Whether it read the agents' files: a light tick skips them unless they are due."""
        # A session moved to another tab or window keeps its id but not its tab's title.
        for s in self.registry.all():
            if positions_before.get(s.session_id, (s.window_id, s.tab_index)) != (s.window_id, s.tab_index):
                with _logged(f"forgetting the title of moved session {s.session_id}"):
                    self.windows.forget_title(s.session_id)
        with _logged("validating the bindings after the snapshot"):
            self.resolver.snapshot_applied()
        for sid in diff.replaced:
            with _logged(f"resetting the turn of replaced session {sid}"):
                self.status.reset_turn(sid)
                self.auto_status.forget(sid)
        for sid in diff.opened:
            with _logged(f"announcing opened session {sid}"):
                if opened := self.registry.get(sid):
                    await self.rpc.broadcast(protocol.SESSION_OPENED, opened.to_json())
        for sid in diff.closed:
            self._forget_session(sid)
            with _logged(f"announcing closed session {sid}"):
                await self.rpc.broadcast(protocol.SESSION_CLOSED, {"sessionId": sid})
        windows_after = {s.window_id for s in self.registry.all()}
        for wid in windows_before - windows_after:
            with _logged(f"announcing closed window {wid}"):
                await self.rpc.broadcast(protocol.WINDOW_CLOSED, {"windowId": wid})
        threads: dict[str, str] = {}
        for s in self.registry.all():
            # Another process's file must not stop the other tabs.
            with _logged(f"corroborating session {s.session_id}"):
                self._corroborate(s, threads, changed)
        read_files = not light or self._files_due(threads)
        if read_files:
            self._files_read_at, self._files_read_for = self._monotonic(), self._files_key(threads)
            if light:
                await self._read_codex_usage_logged()
            with _logged("reading the Codex rollouts"):
                changed += await self._apply_codex_rollouts(threads)
            with _logged("reading the Claude transcripts"):
                changed += await self._apply_claude_tallies()
        # Both only read when a turn waits on them, and a stat each: every tick.
        with _logged("settling orphaned sessions"):
            changed += self.status.settle_orphans(await self._missing_paths(self.status.orphan_paths()))
        with _logged("releasing dead subagents"):
            changed += self.status.release_dead_subagents(await self._subagent_tails(self.status.subagent_transcripts()))
        return read_files

    def _corroborate(self, s: SessionInfo, threads: dict[str, str], changed: list[str]) -> None:
        """Adds to `changed` what the agent's own files and the tab say of `s` that its hooks have
        not, and to `threads` the Codex thread it runs, by session. A step that raises keeps the
        changes before it. The Codex rollout is not read here: see `_apply_codex_rollouts`."""
        if s.agent == "shell":
            self.auto_status.forget(s.session_id)
            if s.state != "idle":
                changed += self.status.agent_exited(s.session_id)
            return
        if s.agent not in HARNESS_BY_AGENT:  # a custom agent: its exact reports win, else guess from its terminal
            if self.status.reported(s.session_id):
                self.auto_status.forget(s.session_id)
            elif (guess := self.auto_status.observe(s.session_id, s.state, s.output_bytes, s.attention)):
                changed += self.status.apply_guess(s.session_id, guess)
            return
        corroboration = HARNESS_BY_AGENT[s.agent].corroboration
        if corroboration == "claude_file":
            if s.job_pid and (f := self.claude_files.read(s.job_pid)):
                changed += self.status.apply_claude_file_status(s.session_id, f.status, f.written_at)
                # The file's cwd is the agent's own, and it follows it into a worktree;
                # `s.cwd` is the shell's and never moves (spec: branch awareness, §1).
                changed += self.status.apply_metadata(s.session_id, cwd=f.cwd)
        elif corroboration == "codex_title":
            changed += self.status.apply_codex_title(s.session_id, s.title)
            if self.codex_files is not None and (thread_id := self.resolver.codex_thread(s.session_id)):
                threads[s.session_id] = thread_id

    async def _apply_codex_rollouts(self, threads: dict[str, str]) -> list[str]:
        """The sessions whose context fill or spend their Codex rollouts changed, and the rollouts'
        caches pruned to the threads still running. A rollout grows without bound and a hung mount can
        stall its read, so it is read on a worker thread: everything that touches the caches runs there."""
        if (files := self.codex_files) is None:
            return []

        def read() -> dict[str, tuple[int | None, TokenTally | None]]:
            readings: dict[str, tuple[int | None, TokenTally | None]] = {}
            for thread_id in set(threads.values()):
                # Another process's file: one that cannot be read costs only its own thread, and only
                # the reading that failed -- a tally that raises still lets the context through.
                context: int | None = None
                tally: TokenTally | None = None
                try:
                    context = files.context_percent(thread_id)
                except Exception:  # noqa: BLE001
                    log.exception("reading the Codex context of thread %s failed", thread_id)
                try:
                    tally = files.tally(thread_id)
                except Exception:  # noqa: BLE001
                    log.exception("reading the Codex tally of thread %s failed", thread_id)
                readings[thread_id] = (context, tally)
            files.retain(set(threads.values()))
            return readings

        none: dict[str, tuple[int | None, TokenTally | None]] = {}
        readings = await self._off_loop(CODEX_READ, read, none)
        changed: list[str] = []
        for session_id, thread_id in threads.items():
            context, tally = readings.get(thread_id, (None, None))
            # None is no reading, which apply_metadata leaves alone; on a new thread it is no spend yet.
            if tally is None and self._codex_threads.get(session_id) != thread_id and self.registry.set_tokens(session_id, None):
                changed.append(session_id)
            changed += self.status.apply_metadata(session_id, context=context, tokens=tally)
        # Only the tabs running Codex now: a closed or quit one's binding goes with it.
        self._codex_threads = dict(threads)
        return changed

    async def _apply_claude_tallies(self) -> list[str]:
        """The sessions whose Claude conversation has spent more since the last tick. A transcript
        grows to hundreds of megabytes and its first read starts at 0, so it is read on a worker thread, which keeps
        what it read for the next tick even when this one stops waiting."""
        transcripts = {s.session_id: s.transcript for s in self.registry.all() if s.transcript}
        if not transcripts:
            # Nothing to read. The cache is pruned by the next read that has transcripts, on the
            # worker thread: pruning here could race a read an earlier tick left running.
            return []
        tallies = self.claude_tallies

        def read() -> dict[str, TokenTally | None]:
            found: dict[str, TokenTally | None] = {}
            for transcript in set(transcripts.values()):
                try:  # another process's file: one that cannot be read costs only its own conversation
                    found[transcript] = tallies.tally(transcript)
                except Exception:  # noqa: BLE001
                    log.exception("reading the Claude transcript %s failed", transcript)
            tallies.retain(set(transcripts.values()))
            return found

        none: dict[str, TokenTally | None] = {}
        found = await self._off_loop(CLAUDE_READ, read, none)
        changed: list[str] = []
        for session_id, transcript in transcripts.items():
            # The tab may have moved on while the read ran (/clear, /resume), its tokens already reset:
            # the old conversation's tally must not be written back onto the new one.
            if ((tally := found.get(transcript)) is not None and (s := self.registry.get(session_id)) is not None
                    and s.transcript == transcript):
                changed += self.status.apply_metadata(session_id, tokens=tally)
        return changed

    async def _missing_paths(self, paths: set[str]) -> frozenset[str]:
        """Which of `paths` are gone. A check that cannot answer finds nothing missing: a directory
        it cannot see is not proof that a turn ended."""
        if not paths:
            return frozenset()
        check = self._path_missing
        return await self._off_loop("the directory check", lambda: frozenset(p for p in paths if check(p)), frozenset())

    async def _subagent_tails(self, paths: set[str]) -> dict[str, TranscriptTail]:
        """The end of each of `paths`, the transcripts of the children a deferred done waits on. Only
        a turn that has one reads any. A read that cannot answer finds none, which proves no child dead."""
        if not paths:
            return {}
        read = self.subagent_transcripts.read_all
        return await self._off_loop("the subagent transcript read", lambda: read(paths), {})

    async def _off_loop(self, name: str, work: Callable[[], T], nothing: T) -> T:
        """`work`, run on a worker thread. It answers `nothing` if it has not finished within
        OFF_LOOP_CHECK_SECONDS, if it raises, or if the run an earlier tick started is still stuck."""
        running = self._checks.get(name)
        if running is not None and not running.done():
            return nothing
        gave_up = False

        def consume(done: asyncio.Future[T]) -> None:
            # Retrieved here, so a run that fails after its tick stopped waiting is not reported by
            # asyncio as "exception was never retrieved" when the future is collected.
            if not done.cancelled() and (error := done.exception()) is not None and gave_up:
                log.warning("%s failed after its tick stopped waiting for it", name, exc_info=error)

        check = run_detached(work)
        check.add_done_callback(consume)
        self._checks[name] = check
        # Waited on, not awaited: a timeout must leave the worker's future pending until its thread returns.
        done, _ = await asyncio.wait({check}, timeout=OFF_LOOP_CHECK_SECONDS)
        if not done:
            gave_up = True
            log.warning("%s took over %.0f s", name, OFF_LOOP_CHECK_SECONDS)
            return nothing
        try:
            return check.result()
        except Exception:  # noqa: BLE001 - a check that cannot answer finds nothing, as documented
            log.exception("%s failed", name)
            return nothing

    def _forget_session(self, session_id: str) -> None:
        """Drops what each part keeps of a closed session, each on its own: one that raises keeps
        only its own state, not the others'."""
        for what, forget in (("window state", self.windows.forget_session), ("turn", self.status.reset_turn),
                             ("bindings", self.resolver.forget), ("terminal signals", self.auto_status.forget)):
            with _logged(f"forgetting the {what} of closed session {session_id}"):
                forget(session_id)

    async def _read_codex_usage(self) -> None:
        # Codex writes its account rate limits into every `token_count` record of its rollout
        # file, so the number arrives the way Claude's does -- as data the agent already emits --
        # with no subprocess to spawn, time out or kill. Account-wide, hence once per tick rather
        # than per session, and before the iTerm2 check: the feed does not depend on the terminal.
        if self.codex_files is None:
            return
        # On a worker thread, as the contexts are: a rollout without a `token_count` is read to its start.
        found = await self._off_loop(CODEX_READ, self.codex_files.rate_limits, None)
        if found is None:
            return
        limits, written_at = found
        usage = parse_codex_rate_limits(limits, written_at if written_at is not None else int(self.clock()))
        if self.usage.set("codex", usage):
            await self.publisher.usage_changed()


def tunnel_alias(p: Any) -> str:
    """A `Host` alias as ssh takes it as its destination: not empty, no whitespace, and not
    starting with `-`, which ssh would read as an option."""
    alias = param(p, "alias", str)
    if not alias or alias.startswith("-") or any(c.isspace() or not c.isprintable() for c in alias):
        raise RpcError(protocol.BAD_PARAMS, "alias must be a Host alias from ~/.ssh/config")
    return alias


def _is_variable(name: Any, value: Any) -> bool:
    """An environment entry exec can carry: a name without `=` or NUL, and a value without NUL."""
    return (isinstance(name, str) and isinstance(value, str) and bool(name)
            and "=" not in name and "\0" not in name and "\0" not in value)
