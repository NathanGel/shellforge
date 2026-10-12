"""SSH tunnels as the app starts them: one `ssh -N <alias>` per started `~/.ssh/config` host, run
with the environment the app hands in (its login shell's -- the daemon has none of its own), its
state broadcast as `tunnel.changed`, restarted with backoff after a drop, and ended with the daemon.

A tunnel is *up* once its ssh has run `up_after` seconds: `ExitOnForwardFailure` makes a port that
cannot be bound end it at once, and `BatchMode` a prompt it cannot answer. An exit before then is
*failed*, with ssh's last line, and is not restarted -- a taken port would fail the same way again.
An exit after it was up is a *drop*: it goes back to *connecting* and restarts after a backoff that
doubles to `backoff_cap`, and starts over once a run has lasted `steady_after` seconds."""
from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import shutil
import signal
import time
from collections.abc import Awaitable, Callable
from typing import Any

from . import protocol

log = logging.getLogger(__name__)

SSH_OPTIONS = ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
               "-o", "BatchMode=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none"]

# ssh's lines for a tunnel that cannot work as configured. ssh binds its forwards only after it has
# authenticated, which through a bastion can take longer than `up_after`: one of these is a failure
# whenever it comes, never a drop to restart.
FATAL = ("Address already in use", "forwarding failed", "cannot listen to port", "Permission denied",
         "Host key verification failed", "Could not resolve hostname", "Bad configuration option")


class _Tunnel:
    def __init__(self, alias: str, environment: dict[str, str]):
        self.alias, self.environment = alias, environment
        self.state, self.error, self.since = "stopped", None, 0.0
        self.process: asyncio.subprocess.Process | None = None
        self.task: asyncio.Task[None] | None = None
        self.stopping = False

    def to_json(self) -> dict[str, Any]:
        return {"alias": self.alias, "state": self.state, "error": self.error, "since": self.since}


class TunnelSupervisor:
    def __init__(self, broadcast: Callable[[str, Any], Awaitable[None]], clock: Callable[[], float] = time.time,
                 up_after: float = 2.0, backoff_start: float = 1.0, backoff_cap: float = 30.0, steady_after: float = 60.0):
        self.broadcast, self.clock = broadcast, clock
        self.up_after, self.backoff_start, self.backoff_cap, self.steady_after = up_after, backoff_start, backoff_cap, steady_after
        self._tunnels: dict[str, _Tunnel] = {}
        # Set by stop_all: the daemon is going, and an ssh started now would outlive it.
        self._closed = False

    def list(self) -> list[dict[str, Any]]:
        return [t.to_json() for t in self._tunnels.values()]

    def pid(self, alias: str) -> int | None:
        tunnel = self._tunnels.get(alias)
        return tunnel.process.pid if tunnel and tunnel.process else None

    async def start(self, alias: str, environment: dict[str, str]) -> None:
        """Starts `alias`'s tunnel; nothing while its run is going -- connecting, up, or a start
        just made whose run has not said so yet."""
        if self._closed:
            return
        current = self._tunnels.get(alias)
        # A run that has said "failed" is over, though its task has a step left.
        if current and current.task is not None and not current.task.done() and not current.stopping \
                and current.state != "failed":
            return
        tunnel = _Tunnel(alias, environment)
        self._tunnels[alias] = tunnel
        tunnel.task = asyncio.get_running_loop().create_task(self._run(tunnel))

    async def stop(self, alias: str) -> None:
        """Ends `alias`'s ssh and any restart pending; it is stopped until started again."""
        tunnel = self._tunnels.get(alias)
        if tunnel is None:
            return
        tunnel.stopping = True
        await self._end(tunnel.process)
        if tunnel.task is not None and tunnel.task is not asyncio.current_task():
            tunnel.task.cancel()
            await asyncio.gather(tunnel.task, return_exceptions=True)
        await self._set(tunnel, "stopped", tunnel.error if tunnel.state == "failed" else None)

    async def stop_all(self) -> None:
        """Ends every tunnel at once, within one budget: the app kills the daemon two seconds after
        asking it to stop, and an ssh still running then holds its port for good."""
        self._closed = True
        tunnels = list(self._tunnels.values())
        for tunnel in tunnels:
            tunnel.stopping = True
        await self._end_all([t.process for t in tunnels], grace=1.0)
        for tunnel in tunnels:
            if tunnel.task is not None and tunnel.task is not asyncio.current_task():
                tunnel.task.cancel()
        await asyncio.gather(*(t.task for t in tunnels if t.task is not None and t.task is not asyncio.current_task()),
                             return_exceptions=True)
        for tunnel in tunnels:
            await self._set(tunnel, "stopped", tunnel.error if tunnel.state == "failed" else None)

    # -- the run ---------------------------------------------------------------------------

    async def _run(self, tunnel: _Tunnel) -> None:
        backoff = self.backoff_start
        loop = asyncio.get_running_loop()
        while not tunnel.stopping:
            if tunnel.state != "connecting":
                await self._set(tunnel, "connecting", tunnel.error)
            ssh = shutil.which("ssh", path=tunnel.environment.get("PATH"))
            if ssh is None:
                await self._set(tunnel, "failed", "ssh isn’t on the login shell’s PATH.")
                return
            try:
                process = await asyncio.create_subprocess_exec(
                    ssh, *SSH_OPTIONS, tunnel.alias, env=tunnel.environment, stdin=asyncio.subprocess.DEVNULL,
                    stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE, start_new_session=True)
            except OSError as exc:
                await self._set(tunnel, "failed", f"Couldn’t start ssh: {exc}")
                return
            tunnel.process = process
            started = loop.time()
            last_line: list[str] = []
            reader = loop.create_task(self._read_errors(process, last_line))
            exited = loop.create_task(process.wait())
            done, _ = await asyncio.wait({exited}, timeout=self.up_after)
            if not done and not tunnel.stopping:
                await self._set(tunnel, "up", None)
            await exited
            await asyncio.gather(reader, return_exceptions=True)
            if tunnel.stopping:
                return
            why = last_line[0] if last_line else f"ssh exited with status {process.returncode}."
            if tunnel.state != "up" or any(text in why for text in FATAL):
                await self._set(tunnel, "failed", why)
                return
            if loop.time() - started >= self.steady_after:
                backoff = self.backoff_start
            await self._set(tunnel, "connecting", why)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, self.backoff_cap)

    @staticmethod
    async def _read_errors(process: asyncio.subprocess.Process, last_line: list[str]) -> None:
        """Keeps ssh's last non-empty stderr line: what a failed or dropped tunnel says."""
        assert process.stderr is not None
        while line := await process.stderr.readline():
            if text := line.decode(errors="replace").strip():
                last_line[:] = [text]

    @classmethod
    async def _end(cls, process: asyncio.subprocess.Process | None) -> None:
        """SIGTERM to ssh's own process group, then SIGKILL two seconds later."""
        await cls._end_all([process], grace=2.0)

    @staticmethod
    async def _end_all(processes: list[asyncio.subprocess.Process | None], grace: float) -> None:
        """SIGTERM to every live ssh's process group at once, then SIGKILL to those still running
        `grace` seconds later."""
        live = [p for p in processes if p is not None and p.returncode is None]
        for process in live:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGTERM)
        if not live:
            return
        _, pending = await asyncio.wait([asyncio.ensure_future(p.wait()) for p in live], timeout=grace)
        if pending:
            for process in live:
                if process.returncode is None:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(process.pid, signal.SIGKILL)
            await asyncio.gather(*pending, return_exceptions=True)

    async def _set(self, tunnel: _Tunnel, state: str, error: str | None) -> None:
        if (tunnel.state, tunnel.error) == (state, error) and state != "connecting":
            return
        tunnel.state, tunnel.error, tunnel.since = state, error, self.clock()
        try:
            await self.broadcast(protocol.TUNNEL_CHANGED, tunnel.to_json())
        except Exception:  # noqa: BLE001 - a client gone mid-broadcast must not stop the tunnel
            log.exception("broadcasting %s's state failed", tunnel.alias)
