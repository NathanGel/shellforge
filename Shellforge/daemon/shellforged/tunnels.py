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
               "-o", "BatchMode=yes"]


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

    def list(self) -> list[dict[str, Any]]:
        return [t.to_json() for t in self._tunnels.values()]

    def pid(self, alias: str) -> int | None:
        tunnel = self._tunnels.get(alias)
        return tunnel.process.pid if tunnel and tunnel.process else None

    async def start(self, alias: str, environment: dict[str, str]) -> None:
        """Starts `alias`'s tunnel; nothing while its run is going -- connecting, up, or a start
        just made whose run has not said so yet."""
        current = self._tunnels.get(alias)
        if current and current.task is not None and not current.task.done() and not current.stopping:
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
        for alias in list(self._tunnels):
            await self.stop(alias)

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
            if tunnel.state != "up":
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

    @staticmethod
    async def _end(process: asyncio.subprocess.Process | None) -> None:
        """SIGTERM to ssh's own process group, then SIGKILL two seconds later."""
        if process is None or process.returncode is not None:
            return
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGTERM)
        try:
            await asyncio.wait_for(process.wait(), 2)
        except TimeoutError:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            await process.wait()

    async def _set(self, tunnel: _Tunnel, state: str, error: str | None) -> None:
        if (tunnel.state, tunnel.error) == (state, error) and state != "connecting":
            return
        tunnel.state, tunnel.error, tunnel.since = state, error, self.clock()
        try:
            await self.broadcast(protocol.TUNNEL_CHANGED, tunnel.to_json())
        except Exception:  # noqa: BLE001 - a client gone mid-broadcast must not stop the tunnel
            log.exception("broadcasting %s's state failed", tunnel.alias)
