"""Reading an RPC request's parameters, and the failures every handler answers the same way."""
from __future__ import annotations
from collections.abc import Awaitable
from typing import Any, TypeVar

from . import protocol
from .iterm_bridge import ItermPort, ItermUnavailable
from .models import Frame
from .rpc_server import RpcError

T = TypeVar("T")


def optional_param(p: Any, name: str, kind: type[T]) -> T | None:
    """An RPC parameter of one JSON type, or None when absent. A malformed request is the
    caller's error, `bad_params`, rather than a KeyError the server reports as `internal`."""
    if not isinstance(p, dict):
        raise RpcError(protocol.BAD_PARAMS, "params must be an object")
    value = p.get(name)
    if value is None:
        return None
    if not isinstance(value, kind) or (isinstance(value, bool) and kind is not bool):
        raise RpcError(protocol.BAD_PARAMS, f"{name} must be a {kind.__name__}")
    return value


def param(p: Any, name: str, kind: type[T]) -> T:
    if (value := optional_param(p, name, kind)) is None:
        raise RpcError(protocol.BAD_PARAMS, f"missing parameter: {name}")
    return value


def frame_param(p: Any) -> Frame:
    try:
        return Frame.from_json(param(p, "frame", dict))
    except (KeyError, TypeError, ValueError) as exc:
        raise RpcError(protocol.BAD_PARAMS, f"frame must have numeric x, y, w and h: {exc}") from exc


def require_iterm(iterm: ItermPort) -> None:
    if not iterm.is_connected():
        raise RpcError(protocol.ITERM_UNAVAILABLE, "iTerm2 is not connected")


async def guard(coro: Awaitable[T]) -> T:
    """An iTerm2 call's result, with an unknown window or session answered as `not_found` and a
    lost connection as `iterm_unavailable`."""
    try:
        return await coro
    except KeyError as exc:
        raise RpcError(protocol.NOT_FOUND, f"no such window or session: {exc.args[0]}") from exc
    except ItermUnavailable as exc:
        raise RpcError(protocol.ITERM_UNAVAILABLE, str(exc)) from exc
