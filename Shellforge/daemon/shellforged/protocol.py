"""JSON-lines framing shared by the Unix-socket RPC server and the ctl client."""
import json
from typing import Any


# The app's half of this contract is app/Sources/AiTermCore/Daemon/DaemonProtocol.swift. Both are
# checked against tests/wire/manifest.json, which tests/test_wire_contract.py writes from this
# module and the registered methods, beside a golden frame of every event and reply.

# The version of this protocol, as the `workspace.snapshot` bootstrap reports it.
VERSION = 1
# The longest request line the server reads, and the longest line the app reads from it.
MAX_FRAME_BYTES = 1 << 20

# The events the daemon broadcasts to every attached client.
ITERM_CONNECTED = "iterm.connected"
ITERM_DISCONNECTED = "iterm.disconnected"
ITERM_AUTH_FAILED = "iterm.auth_failed"
ITERM_COOKIE_REQUESTED = "iterm.cookieRequested"
WINDOW_ACTIVATED = "window.activated"
WINDOW_CLOSED = "window.closed"
SESSION_OPENED = "session.opened"
SESSION_CHANGED = "session.changed"
SESSION_CLOSED = "session.closed"
USAGE_CHANGED = "usage.changed"
EVENTS = (ITERM_CONNECTED, ITERM_DISCONNECTED, ITERM_AUTH_FAILED, ITERM_COOKIE_REQUESTED, WINDOW_ACTIVATED, WINDOW_CLOSED,
          SESSION_OPENED, SESSION_CHANGED, SESSION_CLOSED, USAGE_CHANGED)

# The codes of an error reply.
BAD_PARAMS = "bad_params"
NOT_FOUND = "not_found"
ITERM_UNAVAILABLE = "iterm_unavailable"
# A line that is not a request: not JSON, not an object, or without a method name.
PROTOCOL = "protocol"
INTERNAL = "internal"
UNKNOWN_METHOD = "unknown_method"
ERROR_CODES = (BAD_PARAMS, NOT_FOUND, ITERM_UNAVAILABLE, PROTOCOL, INTERNAL, UNKNOWN_METHOD)


class ProtocolError(ValueError):
    pass


def encode(obj: dict[str, Any]) -> bytes:
    # "replace": json.loads turns a hook body's "\ud800" into a lone surrogate, which UTF-8
    # cannot encode -- and a raise here would close the app's connection on every snapshot.
    return (json.dumps(obj, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8", "replace")


def decode(line: bytes) -> dict[str, Any]:
    try:
        obj = json.loads(line)
    except (json.JSONDecodeError, UnicodeDecodeError, RecursionError) as exc:
        # RecursionError: nesting deeper than the parser's recursion limit.
        raise ProtocolError(f"invalid JSON: {exc}") from exc
    if not isinstance(obj, dict):
        raise ProtocolError("message must be a JSON object")
    return obj


def response(request_id: Any, result: Any) -> dict[str, Any]:
    return {"id": request_id, "result": result}


def error(request_id: Any, code: str, message: str) -> dict[str, Any]:
    return {"id": request_id, "error": {"code": code, "message": message}}


def event(name: str, payload: Any) -> dict[str, Any]:
    return {"event": name, "payload": payload}
