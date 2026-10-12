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
import errno
import signal
import socket
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

# ssh's lines for a prompt BatchMode refused: the tunnel can be opened in a tab to answer it.
NEEDS_INPUT = ("Host key verification failed", "Permission denied", "passphrase", "verification code",
               "keyboard-interactive")

POLL = 0.05


class InspectionFailed(Exception):
    """ps could not say what a pid is: it failed or timed out. Not the same as no such process."""


def ps_command(pid: int) -> str | None:
    """`pid`'s command line, or None when no such process runs (a zombie counts as none). Raises
    InspectionFailed when ps itself cannot answer."""
    try:
        result = subprocess.run(["/bin/ps", "-o", "stat=,command=", "-p", str(pid)], capture_output=True, text=True,
                                timeout=2, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise InspectionFailed(str(exc)) from exc
    out = result.stdout.strip()
    # ps exits 1 with no output for a pid that does not exist; any other failure is no answer.
    if not out:
        if result.returncode not in (0, 1):
            raise InspectionFailed(result.stderr.strip() or f"ps exited with status {result.returncode}")
        return None
    stat, _, command = out.partition(" ")
    return None if stat.startswith("Z") else command.strip() or None


def is_tunnel_ssh(command: str | None, alias: str) -> bool:
    """Whether `command` is exactly this supervisor's ssh for `alias`: an executable named `ssh`
    (first, or second after the interpreter of a script named ssh), then exactly `SSH_OPTIONS` in
    order, then the alias, and nothing else."""
    parts = (command or "").split()
    tail = [*SSH_OPTIONS, alias]
    if len(parts) not in (len(tail) + 1, len(tail) + 2) or parts[-len(tail):] != tail:
        return False
    return os.path.basename(parts[-len(tail) - 1]) == "ssh"


class _Child:
    """A running ssh: one this daemon started (`popen`), or one it adopted by pid."""

    def __init__(self, pid: int, popen: subprocess.Popen[bytes] | None, alias: str,
                 ps: Callable[[int], str | None]):
        self.pid, self.popen, self.alias, self.ps = pid, popen, alias, ps
        # An adopted pid's command line is checked once, off the event loop, when it is adopted;
        # from then on it is alive while it can be signalled.
        self.verified = False

    async def verify(self) -> bool:
        """Whether the pid is still this supervisor's ssh for the alias, leading its own process
        group as every ssh it starts does. Raises InspectionFailed when ps cannot answer."""
        command = await asyncio.to_thread(self.ps, self.pid)
        try:
            leads = os.getpgid(self.pid) == self.pid
        except (ProcessLookupError, PermissionError):
            leads = False
        self.verified = leads and is_tunnel_ssh(command, self.alias)
        return self.verified

    def alive(self) -> bool:
        if self.popen is not None:
            return self.popen.poll() is None
        if not self.verified:
            return False
        try:
            os.kill(self.pid, 0)
        except (ProcessLookupError, PermissionError):
            return False
        return True

    def signal(self, sig: int) -> None:
        """`sig` to the ssh's own process group, which every ssh this supervisor starts leads (an
        adopted one is verified to). A pid that leads no group of its own is not signalled."""
        with contextlib.suppress(ProcessLookupError, PermissionError):
            if os.getpgid(self.pid) == self.pid:
                os.killpg(self.pid, sig)


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
                 sample: Callable[[list[int]], Awaitable[dict[int, tuple[int, int]]]] = traffic.sample,
                 probe_every: float = 1.0, hold_timeout: float = 120.0):
        self.broadcast, self.clock = broadcast, clock
        self.up_after, self.backoff_start, self.backoff_cap, self.steady_after = up_after, backoff_start, backoff_cap, steady_after
        self.ledger, self.ps = ledger, ps
        self.traffic_every, self.sample = traffic_every, sample
        self.probe_every, self.hold_timeout = probe_every, hold_timeout
        self._sampler: asyncio.Task[None] | None = None
        self._tunnels: dict[str, _Tunnel] = {}
        # Ledger entries ps could not answer for: kept as they were, for the next daemon to try.
        self._unknown: list[dict[str, Any]] = []
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
            # Running already -- adopted, or the checkbox changed: no second ssh, but its
            # environment and keep-running are the app's latest.
            if current.held_by is None:
                current.environment = environment or current.environment
                current.keep_running = keep_running
                self._write_ledger()
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
        tunnel.held_by = None
        await self._finish([tunnel])
        self._write_ledger()

    # -- held by a tab -----------------------------------------------------------------------

    async def hold(self, alias: str, port: int, bind: str | None = None) -> None:
        """The app opened `alias` in a terminal tab for the user to answer ssh: any run of the
        supervisor's ends, and the tunnel is watched by its first local `port` -- up while it accepts.
        When it stops accepting after being up, or never does within `hold_timeout`, the tab's ssh
        is over: the tunnel is started once more in batch mode with the environment of its last
        start, or is stopped when it never had one."""
        if self._closed:
            return
        environment, keep_running = None, False
        # A start can land while a run is being ended: end whatever holds the alias until nothing
        # does, so no run is left untracked beside the tab.
        while (current := self._tunnels.get(alias)) is not None and not getattr(current, "_ended_for_hold", False):
            environment = current.environment or environment
            keep_running = current.keep_running or keep_running
            current.stopping = True
            current._ended_for_hold = True  # type: ignore[attr-defined]
            await self._end_all([current.child], grace=2.0)
            current.child = None
            await self._finish([current], broadcast=[])
            self._write_ledger()
            if self._tunnels.get(alias) is current:
                break
        tunnel = _Tunnel(alias, environment, keep_running)
        self._tunnels[alias] = tunnel
        address = self._loopback(bind)
        if self._bound(port, address):
            # Something else listens there: it would read as the tab's ssh, up, for as long as it lives.
            await self._set(tunnel, "failed", f"Port {port} is already in use.")
            return
        tunnel.held_by = "tab"
        await self._set(tunnel, "connecting", None)
        tunnel.task = asyncio.get_running_loop().create_task(self._watch_hold(tunnel, port, address))

    async def _watch_hold(self, tunnel: _Tunnel, port: int, address: str) -> None:
        loop = asyncio.get_running_loop()
        deadline = loop.time() + self.hold_timeout
        while not tunnel.stopping:
            accepts = self._bound(port, address)
            if accepts and tunnel.state != "up":
                await self._set(tunnel, "up", None)
            elif not accepts and (tunnel.state == "up" or loop.time() >= deadline):
                break
            await asyncio.sleep(self.probe_every)
        if tunnel.stopping:
            return
        tunnel.held_by = None
        if tunnel.environment is None:
            await self._set(tunnel, "stopped", None)
            return
        # Handed back: a fresh run, as a start from the app would make.
        tunnel.stopping = True
        self._tunnels.pop(tunnel.alias, None)
        await self.start(tunnel.alias, tunnel.environment, tunnel.keep_running)

    @staticmethod
    def _loopback(bind: str | None) -> str:
        """The address a forward's `bind` listens on: ssh's default, the IPv4 loopback, for none,
        `localhost`, `*` or empty; otherwise the address itself, brackets dropped."""
        address = (bind or "").strip("[]")
        return "127.0.0.1" if address in ("", "localhost", "*") else address

    @staticmethod
    def _bound(port: int, address: str = "127.0.0.1") -> bool:
        """Whether something holds `port` at `address`: binding it fails. Never a connection --
        through the tab's forward, that would reach the remote service on every probe."""
        family = socket.AF_INET6 if ":" in address else socket.AF_INET
        try:
            with socket.socket(family, socket.SOCK_STREAM) as probe:
                probe.bind((address, port))
        except OSError as exc:
            return exc.errno == errno.EADDRINUSE
        return False

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
            try:
                ours = await child.verify()
            except InspectionFailed:
                log.warning("could not inspect pid %d for tunnel %s; kept in the ledger", entry["pid"], entry["alias"])
                self._unknown.append(entry)
                continue
            if not ours or not child.alive():
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
            await asyncio.sleep(1.0)
        if tunnel.stopping:
            return
        tunnel.child = None
        self._write_ledger()
        if tunnel.environment:
            # The app has handed it an environment since: a drop, restarted as any other.
            await self._set(tunnel, "connecting", "Ended outside Shellforge.")
            await self._run(tunnel)
            return
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
                tunnel.needs_input = True if any(text in why for text in NEEDS_INPUT) else None
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
            child.signal(signal.SIGTERM)
        loop = asyncio.get_running_loop()
        deadline = loop.time() + grace
        while any(c.alive() for c in live) and loop.time() < deadline:
            await asyncio.sleep(POLL)
        for child in live:
            if child.alive():
                child.signal(signal.SIGKILL)
        # Bounded: a process that outlives SIGKILL (stuck in the kernel) must not hang a stop.
        deadline = loop.time() + 0.5
        while any(c.alive() for c in live) and loop.time() < deadline:
            await asyncio.sleep(POLL)
        for child in live:
            if child.alive():
                log.warning("ssh %d for %s outlived SIGKILL", child.pid, child.alias)

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
        entries += [e for e in self._unknown if e["alias"] not in self._tunnels]
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
        """`traffic_every` seconds after the last sample -- which itself takes nettop about five --
        the up tunnels' bytes; a change is broadcast. A sample that
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
        if state != "failed":
            tunnel.needs_input = None
        if state == "up":
            # The ledger keeps when it came up, for an adopting daemon's uptime.
            self._write_ledger()
        await self._broadcast(tunnel)

    async def _broadcast(self, tunnel: _Tunnel) -> None:
        try:
            await self.broadcast(protocol.TUNNEL_CHANGED, tunnel.to_json())
        except Exception:  # noqa: BLE001 - a client gone mid-broadcast must not stop the tunnel
            log.exception("broadcasting %s's state failed", tunnel.alias)
