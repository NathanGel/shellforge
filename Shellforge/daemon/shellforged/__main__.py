from __future__ import annotations
import argparse
import asyncio
import json
import logging
import os
import signal
import sys
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

from . import __version__, protocol
from .rpc_server import AlreadyRunning
from .log_repeats import RepeatFilter

#: Exit status for "another daemon already owns the socket". Kept distinct from the
#: generic failure status so a supervisor can adopt the running daemon instead of
#: treating the refusal as a crash and restarting forever.
EXIT_ALREADY_RUNNING = 3

#: How long the daemon keeps running with no app attached before quitting. The app holds an
#: RPC connection for its whole lifetime, so "no client" means "no app" - and a daemon with no
#: app is useless while still holding the socket the next launch needs. Generous enough that a
#: relaunch inside the window still finds it up and adopts it, which beats a cold start.
IDLE_EXIT_SECONDS = 60.0
IDLE_CHECK_SECONDS = 2.0
log = logging.getLogger("shellforged")


class IdleWatchdog:
    """Calls `on_idle` once no client has been attached for `idle_exit_seconds`, or never when
    that is 0. The countdown starts at launch, so a daemon whose app died before it could connect
    is reaped too; any connection resets it."""

    def __init__(self, client_count: Callable[[], int], idle_exit_seconds: float, on_idle: Callable[[], None],
                 check_seconds: float = IDLE_CHECK_SECONDS, monotonic: Callable[[], float] = time.monotonic):
        self.client_count, self.idle_exit_seconds, self.on_idle = client_count, idle_exit_seconds, on_idle
        self.check_seconds, self.monotonic = check_seconds, monotonic

    async def run(self) -> None:
        if self.idle_exit_seconds <= 0:
            return
        last_seen = self.monotonic()
        while True:
            await asyncio.sleep(self.check_seconds)
            if self.client_count() > 0:
                last_seen = self.monotonic()
            elif self.monotonic() - last_seen >= self.idle_exit_seconds:
                log.info("no client for %.0fs, shutting down", self.idle_exit_seconds)
                self.on_idle()
                return


def support_dir() -> Path:
    """Where Shellforge keeps its socket, info file, log and hook port: its own folder, so the daemon
    it was copied from can run beside it. Read at call time, so HOME is the current one."""
    return Path.home() / "Library" / "Application Support" / "Shellforge"


#: Not 47821, the port of the daemon this one was copied from, so both can run on one Mac.
DEFAULT_HOOK_PORT = 47831


def build_parser() -> argparse.ArgumentParser:
    folder = support_dir()
    p = argparse.ArgumentParser(prog="shellforged")
    sub = p.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run", help="run the daemon")
    run.add_argument("--socket", default=str(folder / "shellforged.sock"))
    run.add_argument("--hook-port", type=int, default=DEFAULT_HOOK_PORT)
    run.add_argument("--log-level", default="INFO")
    run.add_argument("--idle-exit-seconds", type=float, default=IDLE_EXIT_SECONDS,
                     help="quit after this long with no client attached (0 disables)")
    run.add_argument("--session-source", choices=["app", "iterm"], default="app",
                     help="app: Shellforge sends its tabs (sessions.update); iterm: read them from iTerm2's Python API")
    run.add_argument("--cookies-from-app", action="store_true",
                     help="with --session-source iterm: ask the attached app for each iTerm2 API cookie instead of running osascript")
    ctl = sub.add_parser("ctl", help="send one request to a running daemon")
    ctl.add_argument("method")
    ctl.add_argument("params", nargs="?", default="null")
    ctl.add_argument("--socket", default=str(folder / "shellforged.sock"))
    return p


async def ctl_request(socket_path: str, method: str, params: Any) -> dict[str, Any]:
    reader, writer = await asyncio.open_unix_connection(socket_path)
    writer.write((json.dumps({"id": 1, "method": method, "params": params}) + "\n").encode())
    await writer.drain()
    try:
        while line := await asyncio.wait_for(reader.readline(), 10):
            msg: dict[str, Any] = json.loads(line)
            if msg.get("id") == 1:
                return msg
    finally:
        writer.close()
    raise RuntimeError("daemon closed the connection")


async def run_daemon(ns: argparse.Namespace) -> None:
    from .claude_sessions import ClaudeSessionFiles
    from .codex_sessions import CodexSessionFiles
    from .connection import ItermSupervisor
    from .hooks_server import HookServer
    from .iterm_port import ItermPort
    from .rpc_server import RpcServer
    from .service import Service

    # The idle watchdog signals this: an app that died without a graceful quit never sends
    # SIGTERM, and the watchdog is the only way the daemon learns it is no longer needed.
    stop = asyncio.Event()
    iterm: ItermPort
    if ns.session_source == "iterm":
        from .iterm_bridge import ItermBridge
        iterm = ItermBridge()
    else:
        from .app_sessions import AppSessions
        iterm = AppSessions()
    rpc = RpcServer(ns.socket)
    # A cookie is for iTerm2's Python API: with the app as the source there is none to ask for.
    supervisor = ItermSupervisor(iterm, rpc.broadcast, lambda: rpc.client_count,
                                 cookies_from_app=ns.cookies_from_app and ns.session_source == "iterm")
    svc = Service(iterm=iterm, rpc=rpc, hooks=HookServer(port=ns.hook_port),
                  claude_files=ClaudeSessionFiles(), codex_files=CodexSessionFiles(),
                  clock=time.time, supervisor=supervisor, tunnel_ledger=Path(ns.socket).parent / "tunnels.json")
    await svc.start()
    watchdog = asyncio.get_running_loop().create_task(
        IdleWatchdog(lambda: rpc.client_count, ns.idle_exit_seconds, stop.set, check_seconds=IDLE_CHECK_SECONDS).run())
    folder = support_dir()
    folder.mkdir(parents=True, exist_ok=True)
    info = folder / "daemon.json"
    info.write_text(json.dumps({"pid": os.getpid(), "socket": ns.socket, "hookPort": svc.hooks.port, "version": __version__}))
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    try:
        await stop.wait()
    finally:
        watchdog.cancel()
        await asyncio.gather(watchdog, return_exceptions=True)
        await svc.stop()
        info.unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    ns = build_parser().parse_args(argv)
    if ns.command == "run":
        # A failure on every 2 s tick is one line every five minutes, not thousands a day. On the
        # helper's own handler only: basicConfig installs it only when nothing else has one.
        handler = logging.StreamHandler()
        handler.addFilter(RepeatFilter())
        logging.basicConfig(level=ns.log_level, format="%(asctime)s %(levelname)s %(name)s: %(message)s", handlers=[handler])
        try:
            asyncio.run(run_daemon(ns))
        except AlreadyRunning as exc:
            print(str(exc), file=sys.stderr)
            return EXIT_ALREADY_RUNNING
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            return 1
        except OSError as exc:  # e.g. the hook port in use: say so, without a traceback
            print(f"shellforged could not start: {exc}", file=sys.stderr)
            return 1
        return 0
    try:
        params = json.loads(ns.params)
    except json.JSONDecodeError as exc:
        print(json.dumps({"error": {"code": protocol.BAD_PARAMS, "message": str(exc)}}), file=sys.stderr)
        return 1
    try:
        resp = asyncio.run(ctl_request(ns.socket, ns.method, params))
    except (OSError, RuntimeError) as exc:
        print(json.dumps({"error": {"code": "unreachable", "message": str(exc)}}), file=sys.stderr)
        return 1
    print(json.dumps(resp, indent=2, ensure_ascii=False))
    return 0 if "error" not in resp else 1


if __name__ == "__main__":
    sys.exit(main())
