from __future__ import annotations

from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, field

from .models import State

# How a custom agent that reports nothing gets its dot guessed from its terminal: "working" is output
# sustained above MIN_OUTPUT_RATE for SUSTAIN_SECONDS, which a spinner, a clock or a blinking cursor
# (tens of bytes a second) stays under; "done" is a working tab whose output has been below that rate
# for QUIET_DONE_SECONDS, so a trickle can never hold a tab at working. TypingReadiness.swift mirrors
# MIN_OUTPUT_RATE and SUSTAIN_SECONDS to tell when a typed-in agent has settled.
#
# Tuning record (0.9.0). Bytes per second of the output the host counts (typing echo excluded), at an
# idle prompt and through a turn with its spinner:
#
#   agent                 idle prompt     working
#   Aider                 not measured    not measured
#   Amp                   not measured    not measured
#   GitHub Copilot CLI    not measured    not measured
#   Gemini CLI            not measured    not measured
#   Goose                 not measured    not measured
#   OpenCode              not measured    not measured
#
# None of the six was installed on the tuning Mac, so the starting values stand: 64 B/s sits above a
# spinner's or a clock's redraw and well below an agent streaming text, and 3 s rides out a pause
# between tool calls. Re-measure when one is installed. A known false positive: typing into a TUI agent
# that redraws its whole input box on every key. The host drops output within 0.5 s of a keypress
# (TerminalSignals.echoWindow), which covers a prompt redraw; a TUI that redraws later than that, or
# animates its box after the typing stops, can still pass MIN_OUTPUT_RATE for a few seconds and read as
# "working", and "done" then follows QUIET_DONE_SECONDS later.
MIN_OUTPUT_RATE = 64.0  # bytes per second
SUSTAIN_SECONDS = 3.0
QUIET_DONE_SECONDS = 30.0


@dataclass(slots=True)
class _Tab:
    samples: deque[tuple[float, int]] = field(default_factory=deque)
    attention: int | None = None
    # When the output was last sustained, or when the tab was first seen if it never was.
    last_sustained: float = 0.0


class AutoStatus:
    """Guesses working, needs input or done for a tab from its terminal's output bytes and attention
    count (bell), read on each helper tick. It knows nothing of the registry: the caller passes the
    tab's current state and applies what comes back. `monotonic` is the clock, injected for tests."""

    def __init__(self, monotonic: Callable[[], float]):
        self._now = monotonic
        self._tabs: dict[str, _Tab] = {}

    def forget(self, session_id: str) -> None:
        self._tabs.pop(session_id, None)

    def observe(self, session_id: str, state: State, output_bytes: int | None,
                attention: int | None) -> State | None:
        """The state to set for the tab, or None to leave it. A counter that goes down (a new process
        in the tab, a reset terminal) is a new baseline and says nothing."""
        if output_bytes is None and attention is None:
            return None
        now = self._now()
        tab = self._tabs.get(session_id)
        first = tab is None
        if tab is None:
            tab = self._tabs[session_id] = _Tab(last_sustained=now)
        # The first count seen is the baseline: a bell that rang before the first read, or in the same
        # instant, is not counted.
        rose = attention is not None and tab.attention is not None and attention > tab.attention
        if attention is not None:
            tab.attention = attention
        sustained = output_bytes is not None and self._sustained(tab, now, output_bytes)
        if sustained:
            tab.last_sustained = now
        if first:
            return None
        if rose:
            return None if state == "needsInput" else "needsInput"
        if sustained:
            return None if state == "working" else "working"
        if state == "working" and now - tab.last_sustained >= QUIET_DONE_SECONDS:
            return "done"
        return None

    @staticmethod
    def _sustained(tab: _Tab, now: float, output_bytes: int) -> bool:
        samples = tab.samples
        if samples and output_bytes < samples[-1][1]:
            samples.clear()
        samples.append((now, output_bytes))
        # Keep the samples of the last SUSTAIN_SECONDS and the newest one at least that old.
        while len(samples) >= 2 and samples[1][0] <= now - SUSTAIN_SECONDS:
            samples.popleft()
        then_t, then_bytes = samples[0]
        if now - then_t < SUSTAIN_SECONDS or _rate(then_t, then_bytes, now, output_bytes) < MIN_OUTPUT_RATE:
            return False
        # A burst that ends early is not sustained: each half of the window must be above the rate too,
        # so a middle sample is required (two samples cannot tell a burst from steady output).
        if len(samples) < 3:
            return False
        middle = min(list(samples)[1:-1], key=lambda s: abs(s[0] - (then_t + now) / 2))
        return (_rate(then_t, then_bytes, *middle) >= MIN_OUTPUT_RATE
                and _rate(*middle, now, output_bytes) >= MIN_OUTPUT_RATE)


def _rate(t0: float, b0: int, t1: float, b1: int) -> float:
    return (b1 - b0) / (t1 - t0)
