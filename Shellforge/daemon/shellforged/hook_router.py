"""Agent hook posts, turned into status and usage changes."""
from __future__ import annotations
import asyncio
import logging
from collections.abc import Awaitable, Callable
from typing import Any

from .hook_events import HOOK_PARSERS, STATUSLINE_PARSERS
from .models import AgentKind
from .publisher import Publisher
from .resolver import SessionResolver
from .status import StatusEngine
from .usage import UsageStore

log = logging.getLogger(__name__)
# The least time between two ticks that unplaced hooks ask for. A hook from an agent outside iTerm2
# (another terminal, an editor) never places however often it is retried, so without a floor each
# of its posts would cost a tick.
RETICK_SECONDS = 1.0


class HookRouter:
    """Places each post on a tab through the resolver, applies it to the status engine or the
    usage store, and publishes what changed. Knows nothing of HTTP or of iTerm2."""

    def __init__(self, resolver: SessionResolver, status: StatusEngine, usage: UsageStore,
                 clock: Callable[[], float], publisher: Publisher,
                 tick: Callable[[], Awaitable[None]] | None = None, retick_seconds: float = RETICK_SECONDS):
        self.resolver, self.status, self.usage, self.clock, self.publisher = resolver, status, usage, clock, publisher
        # `tick` re-reads iTerm2 into the registry: the service's own, which already shares one pass
        # between callers that ask together.
        self._tick, self._retick_seconds = tick, retick_seconds
        # The tick the next unplaced hook will wait for, until it starts reading; and when the last began.
        self._pending_tick: asyncio.Task[bool] | None = None
        self._last_tick_start = float("-inf")

    async def handle_hook(self, path: str, body: dict[str, Any]) -> dict[str, Any] | None:
        if (statusline := STATUSLINE_PARSERS.get(path)) is not None:
            agent, parse = statusline
            tick = parse(body, int(self.clock()))
            usage = tick.usage
            if usage and (usage.five_hour or usage.seven_day or usage.spend) and self.usage.set(agent, usage):
                await self.publisher.usage_changed()
            # The model, reasoning, context and spend all arrive from one session, so one resolution
            # serves them. Status keeps the model and the spend on that session and promotes context
            # to the task's latest value. A tick can carry any of them without the rest:
            # `context_window` is present from the first turn, `model` only once Claude has settled on
            # one, and a Grok tick between turns may carry nothing new but its totals.
            if (tick.model or tick.reasoning or tick.context_percent is not None or tick.tokens is not None
                    or tick.transcript) and (
                    sid := self._resolve_post(agent, tick.session_id, tick.cwd, tick.iterm_session_id)):
                await self.publisher.session_changed(self.status.apply_metadata(
                    sid, model=tick.model, reasoning=tick.reasoning, context=tick.context_percent,
                    tokens=tick.tokens, transcript=tick.transcript))
            return None
        # Tool text and Stop hooks are telemetry, never checkout-removal authority.
        # Leave shell commands intact; explicit cleanup belongs to the app's Remove action.
        parser = HOOK_PARSERS.get(path)
        ev = parser(body) if parser else None
        if ev is None:
            return None
        sid = self._resolve_post(ev.agent, ev.session_id, ev.cwd, ev.iterm_session_id, ev.event_name)
        if sid is None and await self._tick_for_unplaced():
            sid = self._resolve_post(ev.agent, ev.session_id, ev.cwd, ev.iterm_session_id, ev.event_name)
        if sid is None:
            log.debug("hook for unknown session: %s %s", ev.agent, ev.cwd)
            return None
        # The post came from the agent itself, so its cwd is the agent's — the only source
        # there is for a Codex or PI session, neither of which has a polled session file.
        changed = self.status.apply_metadata(sid, model=ev.model, reasoning=ev.reasoning,
                                             context=ev.context_percent, cwd=ev.cwd,
                                             tokens=ev.tokens, transcript=ev.transcript)
        # A new session forgets the tab's subagents and deferred completion — only for a tab the post
        # provably came from. A stale pin or a shared directory could otherwise wipe another tab's turn.
        starts_elsewhere = ev.kind == "sessionStart" and sid != self.resolver.resolve_directly(
            ev.agent, ev.session_id, ev.iterm_session_id)
        if not starts_elsewhere:
            changed += self.status.apply_event(sid, ev)
        await self.publisher.session_changed(changed)
        return None

    async def _tick_for_unplaced(self) -> bool:
        """Waits for a tick that began after the caller's post arrived, so that a tab the registry
        still classifies as `shell` (an agent's first hooks come before the poll that sees it start)
        is read again. Every post that arrives before that tick starts shares it, and one that
        arrives while it runs shares the next, which waits out `retick_seconds` since this one began:
        at most one running and one waiting, however many posts come. False if there is no tick to
        wait for or it failed, and the post is then dropped as before."""
        if self._tick is None:
            return False
        if (task := self._pending_tick) is None:
            task = self._pending_tick = asyncio.get_running_loop().create_task(self._paced_tick(self._tick))
        return await asyncio.shield(task)

    async def _paced_tick(self, tick: Callable[[], Awaitable[None]]) -> bool:
        loop = asyncio.get_running_loop()
        try:
            if (wait := self._last_tick_start + self._retick_seconds - loop.time()) > 0:
                await asyncio.sleep(wait)
        finally:
            # From here a post that arrives is not covered by this tick, which has begun to read.
            self._pending_tick, self._last_tick_start = None, loop.time()
        try:
            await tick()
        except Exception:  # noqa: BLE001 - a failed tick must not break the hook; the poll retries itself
            log.warning("tick for an unplaced hook failed", exc_info=True)
            return False
        return True

    def _resolve_post(self, agent: AgentKind, session_id: str | None, cwd: str | None,
                      iterm_session_id: str | None = None, hook_event: str | None = None) -> str | None:
        if (sid := self.resolver.resolve(agent, session_id, cwd, iterm_session_id)) is not None:
            self.resolver.bind(sid, agent, session_id, hook_event)
        return sid
