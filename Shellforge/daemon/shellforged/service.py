# daemon/shellforged/service.py
from __future__ import annotations
import asyncio
import logging
import time
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from typing import Any, TypeVar

from . import protocol
from .claude_sessions import ClaudeSessionFiles
from .claude_subagents import SubagentTranscripts, TranscriptTail
from .claude_tokens import ClaudeTranscriptTallies
from .codex_sessions import CodexSessionFiles
from .connection import ItermSupervisor
from .hook_router import HookRouter
from .hooks_server import HookServer
from .iterm_bridge import ItermPort
from .offload import run_detached
from .publisher import Publisher
from .resolver import SessionResolver
from .rpc_params import frame_param, guard, param, require_iterm
from .rpc_server import RpcServer
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


class Service:
    """The daemon's composition root: builds the registry, status engine and usage store, wires
    the supervisor, the hook router and the window manager to them, answers the RPC methods none
    of those own, and polls iTerm2 into the registry."""

    def __init__(self, iterm: ItermPort, rpc: RpcServer, hooks: HookServer, claude_files: ClaudeSessionFiles,
                 clock: Callable[[], float], codex_files: CodexSessionFiles | None = None,
                 supervisor: ItermSupervisor | None = None, path_missing: Callable[[str], bool] = path_is_missing,
                 monotonic: Callable[[], float] = time.monotonic):
        self.iterm, self.rpc, self.hooks = iterm, rpc, hooks
        # `clock` is the wall clock, in seconds. Fractional: the status engine stamps each hook with
        # it and compares the stamp with a session file's mtime, which a whole second would blur.
        # `monotonic` times the orphan settle, and `path_missing` is its directory check, which runs
        # on a worker thread: a stat on a hung network mount must not stall the daemon.
        self.claude_files, self.codex_files, self.clock = claude_files, codex_files, clock
        self.supervisor = supervisor or ItermSupervisor(iterm, rpc.broadcast, lambda: rpc.client_count)
        self.registry = SessionRegistry()
        self.status = StatusEngine(self.registry, clock, monotonic)
        self.usage = UsageStore()
        self.resolver = SessionResolver(self.registry, claude_files)
        self.publisher = Publisher(rpc.broadcast, self.registry, self.usage)
        self.hook_router = HookRouter(self.resolver, self.status, self.usage, clock, self.publisher, tick=self.tick)
        self.hooks.on_post = self.hook_router.handle_hook
        self.windows = WindowManager(iterm, self.registry, self.tick)
        self.supervisor.on_connected = self.windows.forget_titles
        self._poll_task: asyncio.Task[None] | None = None
        # window.setFrame and window.activate each leave a state the next one replaces, and the app
        # sends them from separate tasks; requests are answered concurrently, so they take this in
        # turn, in the order they came, and the last one sent is the one that stays.
        self._placement_lock = asyncio.Lock()
        self._tick_lock = asyncio.Lock()
        # Ticks started so far, and the number of the last to finish without raising: a tick whose
        # caller asked before another started and finished has nothing left to read.
        self._ticks_started = 0
        self._last_good_tick = 0
        self._path_missing = path_missing
        self.subagent_transcripts = SubagentTranscripts()
        self.claude_tallies = ClaudeTranscriptTallies()
        # The Codex thread each tab ran at the last tick, by session: a tab that moves to a thread with
        # no totals yet (/new, /resume) must drop the old thread's, which no reading replaces.
        self._codex_threads: dict[str, str] = {}
        # Each off-loop check's latest run, by name, while its worker thread may still be running: a
        # thread stuck on a hung mount cannot be cancelled, so no second one is started beside it.
        self._checks: dict[str, asyncio.Future[Any]] = {}
        self._register_handlers()

    # -- lifecycle ---------------------------------------------------------
    async def start(self) -> None:
        self.iterm.on_new_session(self.windows.on_new_session)
        self.iterm.on_session_closed(self._on_session_closed)
        self.iterm.on_window_activated(self._on_window_activated)
        await self.rpc.start()
        try:
            await self.hooks.start()
        except BaseException:
            await self.rpc.stop()
            raise
        await self.supervisor.start()
        self._poll_task = asyncio.get_running_loop().create_task(self._poll_forever())

    async def stop(self) -> None:
        if (task := self._poll_task) is not None and task is not asyncio.current_task():
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        await self.supervisor.stop()
        await self.hooks.stop()
        await self.rpc.stop()

    async def _poll_forever(self) -> None:
        while True:
            try:
                await self.tick()
            except Exception:  # noqa: BLE001
                log.exception("tick failed")
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
        r("sessions.setTitles", self.windows.set_titles)
        r("sessions.markSeen", self._h_mark_seen)
        r("usage.get", self._h_usage_get)
        r("interface.setMatchItermBackground", self.windows.set_match_iterm_background)

    async def _h_snapshot(self, _p: Any) -> dict[str, Any]:
        try:
            await self.tick()
        except Exception:  # noqa: BLE001 - the last known registry beats no bootstrap at all
            log.exception("tick failed")
        # No await between reading state and returning it. RpcServer writes the reply
        # before yielding, making it a barrier between earlier and later events.
        return {"protocolVersion": protocol.VERSION, **self.supervisor.snapshot_fields(),
                "sessions": [s.to_json() for s in self.registry.all()],
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

    async def _h_sessions_list(self, _p: Any) -> list[dict[str, Any]]:
        return [s.to_json() for s in self.registry.all()]

    async def _h_mark_seen(self, p: Any) -> dict[str, Any]:
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
    async def tick(self) -> None:
        # The poll loop, iTerm2 notification callbacks, and RPC handlers can
        # all call tick() concurrently; serialize the whole body so a
        # `windows_before` snapshot taken by one call can't be diffed against
        # a `windows_after` produced by an interleaved call (which double-
        # broadcasts window.closed, among other races).
        #
        # Callers queued behind one tick share the next: it starts after all of them asked, so it
        # reads everything each would have. The running one does not count -- it may have read
        # iTerm2 before the change its caller is waiting to see -- and neither does a failed one.
        asked_after = self._ticks_started
        async with self._tick_lock:
            if self._last_good_tick > asked_after:
                return
            self._ticks_started += 1
            number = self._ticks_started
            await self._tick()
            self._last_good_tick = number

    async def _tick(self) -> None:
        try:
            await self._read_codex_usage()
        except Exception:  # noqa: BLE001 - another process's file must not stop session polling
            log.exception("reading Codex usage failed")
        if not self.iterm.is_connected():
            return
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
            await self._after_snapshot(diff, windows_before, positions_before, changed)
        finally:
            await self.publisher.session_changed(changed)

    async def _after_snapshot(self, diff: SnapshotDiff, windows_before: set[str],
                              positions_before: dict[str, tuple[str, int]], changed: list[str]) -> None:
        """Announces what the snapshot opened and closed, then reads the corroborating signals, each
        step guarded so one that raises costs only its own changes. Appends to `changed` as it goes."""
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
        with _logged("reading the Codex rollouts"):
            changed += await self._apply_codex_rollouts(threads)
        with _logged("reading the Claude transcripts"):
            changed += await self._apply_claude_tallies()
        with _logged("settling orphaned sessions"):
            changed += self.status.settle_orphans(await self._missing_paths(self.status.orphan_paths()))
        with _logged("releasing dead subagents"):
            changed += self.status.release_dead_subagents(await self._subagent_tails(self.status.subagent_transcripts()))

    def _corroborate(self, s: SessionInfo, threads: dict[str, str], changed: list[str]) -> None:
        """Adds to `changed` what the agent's own files and the tab say of `s` that its hooks have
        not, and to `threads` the Codex thread it runs, by session. A step that raises keeps the
        changes before it. The Codex rollout is not read here: see `_apply_codex_rollouts`."""
        if s.agent == "shell":
            if s.state != "idle":
                changed += self.status.agent_exited(s.session_id)
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
        grows to megabytes and its first read is whole, so it is read on a worker thread, which keeps
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
                             ("bindings", self.resolver.forget)):
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

