"""SSH tunnels as the app starts them: one `ssh -N <alias>` per started `~/.ssh/config` host, run
with the environment the app hands in (its login shell's -- the daemon has none of its own), its
state broadcast as `tunnel.changed`, restarted with backoff after a drop, and ended with the daemon
-- unless it keeps running, when the next daemon adopts it.

A tunnel is *up* once its ssh has run `up_after` seconds: `ExitOnForwardFailure` makes a port that
cannot be bound end it at once, and `BatchMode` a prompt it cannot answer. An exit before then is
*failed*, with ssh's last line, and is not restarted -- a taken port would fail the same way again.
An exit after it was up is a *drop*: it goes back to *connecting* and restarts after a backoff that
doubles to `backoff_cap`, and starts over once a run has lasted `steady_after` seconds.

ssh runs as a plain child (`subprocess.Popen`), polled, never through an asyncio transport: closing
a transport -- at the daemon's exit, or when it is collected -- kills its process, and a tunnel
that keeps running must not die with the daemon. Its stderr goes to a file beside the ledger for
the same reason: a pipe with no reader left would end ssh at its next line.

The ledger (`tunnels.json`) lists every ssh running: alias, pid, since and keep-running, never the
environment. At start, `adopt()` takes back the keep-running ones and ends the rest -- what a
crash left behind -- but only a pid whose command line is still this supervisor's ssh for that
alias; a pid since reused by another program is left alone."""
from __future__ import annotations

import asyncio
import contextlib
import hashlib
import json
import logging
import os
import shutil
import signal
import subprocess
import tempfile
import time
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

from . import protocol, traffic

log = logging.getLogger(__name__)

SSH_OPTIONS = ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
               "-o", "BatchMode=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none"]

# ssh's lines for a tunnel that cannot work as configured. ssh binds its forwards only after it has
# authenticated, which through a bastion can take longer than `up_after`: one of these is a failure
# whenever it comes, never a drop to restart.
FATAL = ("Address already in use", "forwarding failed", "cannot listen to port", "Permission denied",
         "Host key verification failed", "Could not resolve hostname", "Bad configuration option")

POLL = 0.05


def ps_command(pid: int) -> str | None:
    """`pid`'s command line, or None when no such process runs (a zombie counts as none)."""
    try:
        out = subprocess.run(["/bin/ps", "-o", "stat=,command=", "-p", str(pid)], capture_output=True, text=True,
                             timeout=2, check=False).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    if not out:
        return None
    stat, _, command = out.partition(" ")
    return None if stat.startswith("Z") else command.strip() or None


def is_tunnel_ssh(command: str | None, alias: str) -> bool:
    """Whether `command` is this supervisor's ssh for `alias`: every option, the alias last."""
    parts = (command or "").split()
    return bool(parts) and parts[-1] == alias and all(option in parts for option in SSH_OPTIONS)


class _Child:
    """A running ssh: one this daemon started (`popen`), or one it adopted by pid."""

    def __init__(self, pid: int, popen: subprocess.Popen[bytes] | None, alias: str,
                 ps: Callable[[int], str | None]):
        self.pid, self.popen, self.alias, self.ps = pid, popen, alias, ps

    def alive(self) -> bool:
        if self.popen is not None:
            return self.popen.poll() is None
        try:
            os.kill(self.pid, 0)
        except (ProcessLookupError, PermissionError):
            return False
        return is_tunnel_ssh(self.ps(self.pid), self.alias)


class _Tunnel:
    def __init__(self, alias: str, environment: dict[str, str] | None, keep_running: bool = False):
        self.alias, self.environment, self.keep_running = alias, environment, keep_running
        self.state, self.error, self.since = "stopped", None, 0.0
        self.bytes_in: int | None = None
        self.bytes_out: int | None = None
        self.held_by: str | None = None
        self.needs_input: bool | None = None
        self.child: _Child | None = None
        self.task: asyncio.Task[None] | None = None
        self.stopping = False

    def to_json(self) -> dict[str, Any]:
        return {"alias": self.alias, "state": self.state, "error": self.error, "since": self.since,
                "bytesIn": self.bytes_in, "bytesOut": self.bytes_out, "heldBy": self.held_by, "needsInput": self.needs_input}


class TunnelSupervisor:
    def __init__(self, broadcast: Callable[[str, Any], Awaitable[None]], clock: Callable[[], float] = time.time,
                 up_after: float = 2.0, backoff_start: float = 1.0, backoff_cap: float = 30.0, steady_after: float = 60.0,
                 ledger: Path | None = None, ps: Callable[[int], str | None] = ps_command, traffic_every: float = 5.0,
                 sample: Callable[[list[int]], Awaitable[dict[int, tuple[int, int]]]] = traffic.sample):
        self.broadcast, self.clock = broadcast, clock
        self.up_after, self.backoff_start, self.backoff_cap, self.steady_after = up_after, backoff_start, backoff_cap, steady_after
        self.ledger, self.ps = ledger, ps
        self.traffic_every, self.sample = traffic_every, sample
        self._sampler: asyncio.Task[None] | None = None
        self._tunnels: dict[str, _Tunnel] = {}
        # Set by stop_all: the daemon is going, and an ssh started now would outlive it.
        self._closed = False
        # ssh's stderr files: beside the ledger, or -- with none, as in tests -- a temporary folder
        # made at the first start.
        self._logs: Path | None = ledger.parent / "tunnel-logs" if ledger else None

    def list(self) -> list[dict[str, Any]]:
        return [t.to_json() for t in self._tunnels.values()]

    def pid(self, alias: str) -> int | None:
        tunnel = self._tunnels.get(alias)
        return tunnel.child.pid if tunnel and tunnel.child else None

    async def start(self, alias: str, environment: dict[str, str], keep_running: bool = False) -> None:
        """Starts `alias`'s tunnel; nothing while its run is going -- connecting, up, adopted, or a
        start just made whose run has not said so yet."""
        if self._closed:
            return
        current = self._tunnels.get(alias)
        # A run that has said "failed" is over, though its task has a step left.
        if current and current.task is not None and not current.task.done() and not current.stopping \
                and current.state != "failed":
            return
        tunnel = _Tunnel(alias, environment, keep_running)
        self._tunnels[alias] = tunnel
        tunnel.task = asyncio.get_running_loop().create_task(self._run(tunnel))
        self._start_sampler()

    async def stop(self, alias: str) -> None:
        """Ends `alias`'s ssh and any restart pending; it is stopped until started again."""
        tunnel = self._tunnels.get(alias)
        if tunnel is None:
            return
        tunnel.stopping = True
        await self._end_all([tunnel.child], grace=2.0)
        tunnel.child = None
        await self._finish([tunnel])
        self._write_ledger()

    async def stop_all(self) -> None:
        """Ends every tunnel at once, within one budget -- the app kills the daemon two seconds after
        asking it to stop, and an ssh still running then holds its port for good -- except those
        that keep running, which stay in the ledger for the next daemon."""
        self._closed = True
        if self._sampler is not None:
            self._sampler.cancel()
            await asyncio.gather(self._sampler, return_exceptions=True)
        tunnels = list(self._tunnels.values())
        for tunnel in tunnels:
            tunnel.stopping = True
        ending = [t for t in tunnels if not t.keep_running]
        await self._end_all([t.child for t in ending], grace=1.0)
        for tunnel in ending:
            tunnel.child = None
        await self._finish(tunnels, broadcast=ending)
        self._write_ledger()

    async def _finish(self, tunnels: list[_Tunnel], broadcast: list[_Tunnel] | None = None) -> None:
        """Cancels the tunnels' runs, and says `stopped` for those in `broadcast` (all, by default)."""
        current = asyncio.current_task()
        tasks = [t.task for t in tunnels if t.task is not None and t.task is not current]
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        for tunnel in tunnels if broadcast is None else broadcast:
            await self._set(tunnel, "stopped", tunnel.error if tunnel.state == "failed" else None)

    # -- adopting ---------------------------------------------------------------------------

    async def adopt(self) -> None:
        """Takes back the keep-running tunnels the ledger lists and ends every other ssh it names;
        a pid that is no longer this supervisor's ssh for its alias is dropped, never signalled."""
        entries = self._read_ledger()
        leftovers: list[_Child] = []
        loop = asyncio.get_running_loop()
        for entry in entries:
            child = _Child(entry["pid"], None, entry["alias"], self.ps)
            if not child.alive():
                continue
            if entry["keepRunning"] and entry["alias"] not in self._tunnels:
                tunnel = _Tunnel(entry["alias"], None, keep_running=True)
                tunnel.child, tunnel.state, tunnel.since = child, "up", float(entry["since"])
                self._tunnels[tunnel.alias] = tunnel
                tunnel.task = loop.create_task(self._watch_adopted(tunnel))
                await self._broadcast(tunnel)
                self._start_sampler()
            else:
                leftovers.append(child)
        await self._end_all(leftovers, grace=1.0)
        self._write_ledger()

    async def _watch_adopted(self, tunnel: _Tunnel) -> None:
        """An adopted ssh is no child of this daemon: its end is seen by polling its pid."""
        while tunnel.child is not None and tunnel.child.alive():
            await asyncio.sleep(POLL * 4)
        if tunnel.stopping:
            return
        tunnel.child = None
        self._write_ledger()
        await self._set(tunnel, "stopped", "Ended outside Shellforge.")

    # -- the run ---------------------------------------------------------------------------

    async def _run(self, tunnel: _Tunnel) -> None:
        backoff = self.backoff_start
        loop = asyncio.get_running_loop()
        environment = tunnel.environment or {}
        while not tunnel.stopping:
            if tunnel.state != "connecting":
                await self._set(tunnel, "connecting", tunnel.error)
            ssh = shutil.which("ssh", path=environment.get("PATH"))
            if ssh is None:
                await self._set(tunnel, "failed", "ssh isn’t on the login shell’s PATH.")
                return
            errors = self._log_file(tunnel.alias)
            try:
                with open(errors, "wb") as stderr:
                    popen = subprocess.Popen([ssh, *SSH_OPTIONS, tunnel.alias], env=environment, stdin=subprocess.DEVNULL,
                                             stdout=subprocess.DEVNULL, stderr=stderr, start_new_session=True)
            except OSError as exc:
                await self._set(tunnel, "failed", f"Couldn’t start ssh: {exc}")
                return
            tunnel.child = _Child(popen.pid, popen, tunnel.alias, self.ps)
            # nettop counts per process: a new ssh starts from nothing.
            tunnel.bytes_in = tunnel.bytes_out = None
            self._write_ledger()
            started = loop.time()
            while popen.poll() is None:
                if tunnel.state != "up" and loop.time() - started >= self.up_after and not tunnel.stopping:
                    await self._set(tunnel, "up", None)
                await asyncio.sleep(POLL)
            tunnel.child = None
            self._write_ledger()
            if tunnel.stopping:
                return
            why = self._last_line(errors) or f"ssh exited with status {popen.returncode}."
            if tunnel.state != "up" or any(text in why for text in FATAL):
                await self._set(tunnel, "failed", why)
                return
            if loop.time() - started >= self.steady_after:
                backoff = self.backoff_start
            await self._set(tunnel, "connecting", why)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, self.backoff_cap)

    def _log_file(self, alias: str) -> Path:
        """Where `alias`'s ssh writes its stderr: named by a hash, as an alias may hold any character."""
        if self._logs is None:
            self._logs = Path(tempfile.mkdtemp(prefix="shellforge-tunnels-"))
        self._logs.mkdir(parents=True, exist_ok=True)
        return self._logs / f"{hashlib.sha256(alias.encode()).hexdigest()[:16]}.log"

    @staticmethod
    def _last_line(path: Path) -> str | None:
        """ssh's last non-empty stderr line: what a failed or dropped tunnel says."""
        try:
            lines = path.read_bytes()[-4096:].decode(errors="replace").splitlines()
        except OSError:
            return None
        return next((line.strip() for line in reversed(lines) if line.strip()), None)

    @staticmethod
    async def _end_all(children: list[_Child | None], grace: float) -> None:
        """SIGTERM to every live ssh's process group at once, then SIGKILL to those still running
        `grace` seconds later."""
        live = [c for c in children if c is not None and c.alive()]
        for child in live:
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.killpg(child.pid, signal.SIGTERM)
        loop = asyncio.get_running_loop()
        deadline = loop.time() + grace
        while any(c.alive() for c in live) and loop.time() < deadline:
            await asyncio.sleep(POLL)
        for child in live:
            if child.alive():
                with contextlib.suppress(ProcessLookupError, PermissionError):
                    os.killpg(child.pid, signal.SIGKILL)
        while any(c.alive() for c in live):
            await asyncio.sleep(POLL)

    # -- the ledger --------------------------------------------------------------------------

    def _read_ledger(self) -> list[dict[str, Any]]:
        if self.ledger is None:
            return []
        try:
            data = json.loads(self.ledger.read_text())
        except (OSError, ValueError):
            return []
        entries = data.get("tunnels") if isinstance(data, dict) else None
        if not isinstance(entries, list):
            return []
        return [e for e in entries if isinstance(e, dict) and isinstance(e.get("alias"), str)
                and isinstance(e.get("pid"), int) and not isinstance(e.get("pid"), bool) and e["pid"] > 1
                and isinstance(e.get("since"), (int, float)) and isinstance(e.get("keepRunning"), bool)]

    def _write_ledger(self) -> None:
        """Every ssh running now, written whole and atomically; never the environment."""
        if self.ledger is None:
            return
        entries = [{"alias": t.alias, "pid": t.child.pid, "since": t.since, "keepRunning": t.keep_running}
                   for t in self._tunnels.values() if t.child is not None]
        try:
            self.ledger.parent.mkdir(parents=True, exist_ok=True)
            fd, temp = tempfile.mkstemp(dir=self.ledger.parent, prefix=".tunnels-")
            with os.fdopen(fd, "w") as f:
                json.dump({"tunnels": entries}, f)
            os.replace(temp, self.ledger)
        except OSError:
            log.exception("writing the tunnel ledger failed")

    # -- traffic -----------------------------------------------------------------------------

    def _start_sampler(self) -> None:
        if self._sampler is None or self._sampler.done():
            self._sampler = asyncio.get_running_loop().create_task(self._sample_forever())

    async def _sample_forever(self) -> None:
        """Every `traffic_every` seconds, the up tunnels' bytes; a change is broadcast. A sample that
        fails is skipped -- the counts stay as they were -- and the loop goes on."""
        while not self._closed:
            await asyncio.sleep(self.traffic_every)
            up = [t for t in self._tunnels.values() if t.state == "up" and t.child is not None]
            if not up:
                continue
            try:
                counts = await self.sample([t.child.pid for t in up if t.child is not None])
            except Exception:  # noqa: BLE001 - traffic is shown, never relied on
                log.exception("sampling tunnel traffic failed")
                continue
            for tunnel in up:
                if tunnel.child is None or tunnel.child.pid not in counts or tunnel.state != "up":
                    continue
                received, sent = counts[tunnel.child.pid]
                if (received, sent) != (tunnel.bytes_in, tunnel.bytes_out):
                    tunnel.bytes_in, tunnel.bytes_out = received, sent
                    await self._broadcast(tunnel)

    async def _set(self, tunnel: _Tunnel, state: str, error: str | None) -> None:
        if (tunnel.state, tunnel.error) == (state, error) and state != "connecting":
            return
        tunnel.state, tunnel.error, tunnel.since = state, error, self.clock()
        if state != "up":
            tunnel.bytes_in = tunnel.bytes_out = None
        if state == "up":
            # The ledger keeps when it came up, for an adopting daemon's uptime.
            self._write_ledger()
        await self._broadcast(tunnel)

    async def _broadcast(self, tunnel: _Tunnel) -> None:
        try:
            await self.broadcast(protocol.TUNNEL_CHANGED, tunnel.to_json())
        except Exception:  # noqa: BLE001 - a client gone mid-broadcast must not stop the tunnel
            log.exception("broadcasting %s's state failed", tunnel.alias)
