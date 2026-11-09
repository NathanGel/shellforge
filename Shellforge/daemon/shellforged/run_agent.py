"""`shellforge-run <agent-id> -- <command…>`: starts an agent with the environment and secrets the app
armed for this tab, so that none of them is ever typed, shown in scrollback or kept in shell history.

It asks the helper's socket once (`agents.takeLaunch`) for what was armed for this tab
(`$ITERM_SESSION_ID`) and this agent, adds `SHELLFORGE_AGENT_ID`, and execs the command. Anything
short of that (nothing armed, the arm expired, the helper down, no tab) prints one line and exits 1:
the agent never starts without its settings, and the take never waits longer than the socket's
timeout. Nothing it prints ever holds a value it was given.

Run as a script by `hooks/shellforge-run`, under the helper's own Python with `-I`: standard library
only, and no import from the package it sits in."""
from __future__ import annotations

import json
import os
import re
import socket
import sys
import time
from collections.abc import Callable, Mapping
from typing import Any, NoReturn, TextIO

Request = Callable[[str, dict[str, Any]], dict[str, Any]]
Exec = Callable[[str, list[str], dict[str, str]], NoReturn]

#: Longer than the helper's TAKE_WAIT_SECONDS (`launch_env.py`), so its not_found arrives first.
SOCKET_TIMEOUT_SECONDS = 15.0
#: The longest reply line read, as the helper's MAX_FRAME_BYTES.
MAX_LINE_BYTES = 1 << 20
AGENT_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")
# As `shellforge-status` accepts it: `w0t1p0:` and a GUID.
SESSION_ID = re.compile(r"[A-Za-z0-9:._-]{1,128}")
USAGE = "usage: shellforge-run <agent-id> -- <command> [arguments…]"


def failure(agent_id: str) -> str:
    return f"shellforge-run: Shellforge didn’t send {agent_id}’s settings. Start the task again from Shellforge."


def default_socket(env: Mapping[str, str]) -> str:
    home = env.get("HOME") or os.path.expanduser("~")
    return os.path.join(home, "Library", "Application Support", "Shellforge", "shellforged.sock")


def socket_request(path: str, timeout: float) -> Request:
    """One request over the helper's socket: its reply, read past the events the helper broadcasts to
    every client, within `timeout` seconds in all. Raises OSError (TimeoutError included) or
    ValueError when there is no reply."""
    def request(method: str, params: dict[str, Any]) -> dict[str, Any]:
        deadline = time.monotonic() + timeout

        def left() -> float:
            if (seconds := deadline - time.monotonic()) <= 0:
                raise TimeoutError("no reply from the helper")
            return seconds

        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(left())
            sock.connect(path)
            sock.sendall((json.dumps({"id": 1, "method": method, "params": params}) + "\n").encode())
            buffered = b""
            while True:
                while b"\n" not in buffered:
                    if len(buffered) > MAX_LINE_BYTES:
                        raise ValueError("reply line too long")
                    sock.settimeout(left())  # events arriving must not stretch the wait
                    chunk = sock.recv(65536)
                    if not chunk:
                        raise ConnectionError("the helper closed the connection")
                    buffered += chunk
                line, _, buffered = buffered.partition(b"\n")
                message = json.loads(line)
                if isinstance(message, dict) and message.get("id") == 1:
                    return message
    return request


def _environment(reply: Any) -> dict[str, str] | None:
    """The armed environment in a takeLaunch reply, or None for an error or anything unreadable."""
    result = reply.get("result") if isinstance(reply, dict) else None
    environment = result.get("environment") if isinstance(result, dict) else None
    if not isinstance(environment, dict):
        return None
    if not all(isinstance(k, str) and isinstance(v, str) for k, v in environment.items()):
        return None
    return environment


def main(argv: list[str], env: Mapping[str, str], request: Request, execvpe: Exec, err: TextIO) -> int:
    """`argv` without the program name. Returns only on failure: 2 for usage, 1 when nothing was
    taken, 127 when the command could not be started."""
    if len(argv) < 3 or argv[1] != "--" or not AGENT_ID.fullmatch(argv[0]):
        print(USAGE, file=err)
        return 2
    agent_id, command = argv[0], argv[2:]
    session = env.get("ITERM_SESSION_ID", "")
    if not SESSION_ID.fullmatch(session):
        print(failure(agent_id), file=err)
        return 1
    try:
        reply = request("agents.takeLaunch", {"session": session, "agentId": agent_id})
    except KeyboardInterrupt:
        return 130  # ^C while waiting: the person meant it, so quietly
    except Exception:  # noqa: BLE001 - whatever went wrong, the agent must not start without its settings
        reply = None
    environment = _environment(reply)
    if environment is None:
        print(failure(agent_id), file=err)
        return 1
    launched = {**env, **environment, "SHELLFORGE_AGENT_ID": agent_id}
    # Only printable characters of the command's name: never a terminal escape.
    name = "".join(c for c in command[0] if c.isprintable())
    try:
        execvpe(command[0], command, launched)
    except OSError as exc:
        # The errno's own words, never the exception's text, which a caller could have filled.
        reason = os.strerror(exc.errno) if exc.errno else "it couldn’t be run"
        print(f"shellforge-run: {name} couldn’t be started: {reason}.", file=err)
        return 127
    except ValueError:  # a NUL in an argument or a variable
        print(f"shellforge-run: {name} couldn’t be started: an argument or setting holds a NUL character.", file=err)
        return 127


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], os.environ, socket_request(default_socket(os.environ), SOCKET_TIMEOUT_SECONDS),
                  os.execvpe, sys.stderr))
