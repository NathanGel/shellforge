"""The events a session or usage change becomes."""
from __future__ import annotations
from collections.abc import Awaitable, Callable
from typing import Any

from . import protocol
from .sessions import SessionRegistry
from .usage import UsageStore


class Publisher:
    """Rendered when sent, from the registry and the usage store, so an event always carries the
    latest state -- and several changes to one session in a pass become one event."""

    def __init__(self, broadcast: Callable[[str, Any], Awaitable[None]], registry: SessionRegistry, usage: UsageStore):
        self.broadcast, self.registry, self.usage = broadcast, registry, usage

    async def session_changed(self, session_ids: list[str]) -> None:
        for sid in dict.fromkeys(session_ids):
            if s := self.registry.get(sid):
                await self.broadcast(protocol.SESSION_CHANGED, s.to_json())

    async def usage_changed(self) -> None:
        await self.broadcast(protocol.USAGE_CHANGED, self.usage.snapshot())
