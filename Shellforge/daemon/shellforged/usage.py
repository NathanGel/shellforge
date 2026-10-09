from __future__ import annotations
import math
from dataclasses import replace
from typing import Any

from .models import USAGE_VENDORS, Usage, UsageWindow

FIVE_HOUR_MINS, WEEK_MINS = 300, 10080
# How far `updatedAt` may advance before an otherwise unchanged `Usage` is news again. The
# footer greys a number whose age passes a threshold, so its idea of the age has to keep up
# with the daemon's -- but not at the rate a status line ticks.
HEARTBEAT_SECONDS = 60


class UsageStore:
    def __init__(self) -> None:
        # Every vendor is in the snapshot, a None until it first reports.
        self._usage: dict[str, Usage | None] = dict.fromkeys(USAGE_VENDORS)
        # What the clients were last told, per vendor: the reference for "is this news?", which
        # the latest stored value cannot be once a quiet minute has been absorbed into it.
        self._announced: dict[str, Usage] = {}

    def set(self, vendor: str, usage: Usage) -> bool:
        """Stores `usage` and says whether clients should hear about it: new content, or the same
        content a heartbeat older than the last announcement."""
        told = self._announced.get(vendor)
        changed = (told is None or replace(told, updated_at=usage.updated_at) != usage
                   or usage.updated_at - told.updated_at >= HEARTBEAT_SECONDS)
        self._usage[vendor] = usage
        if changed:
            self._announced[vendor] = usage
        return changed

    def snapshot(self) -> dict[str, Any]:
        return {v: (u.to_json() if u else None) for v, u in self._usage.items()}


def finite_number(value: Any) -> float | None:
    """A number from another process's JSON. json.loads accepts Infinity and NaN, and `int()` or
    `round()` raise on both -- and on an int too large for a float -- so those are no number at
    all; bool is excluded by name, being an int to Python."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        number = float(value)
    except OverflowError:
        return None
    return number if math.isfinite(number) else None


# The most a count may be: the largest whole number a double holds exactly. A finite 1e30 would
# otherwise reach the wire as a 31-digit int, which the app's `Int` cannot decode.
MAX_WHOLE_COUNT = 2**53


def whole_count(value: Any) -> int | None:
    """A token count from another process's JSON: a finite number from zero to MAX_WHOLE_COUNT, as
    an int. Anything else -- a string, a bool, a negative, a count no session could reach -- is no
    count at all, never zero."""
    number = finite_number(value)
    # Compared as given, not as the float: 2**53 + 1 rounds to 2**53 as a double.
    return int(number) if number is not None and 0 <= value <= MAX_WHOLE_COUNT else None


def _window(d: Any, percent_key: str) -> UsageWindow | None:
    """One rate-limit window: a used percentage (a float) and `resets_at` (epoch seconds). Anything
    that is not a number is not a window."""
    if not isinstance(d, dict) or (used := finite_number(d.get(percent_key))) is None:
        return None
    resets = finite_number(d.get("resets_at"))
    return UsageWindow(round(used), int(resets) if resets is not None else None)


def parse_claude_rate_limits(rl: Any, updated_at: int) -> Usage:
    """The `rate_limits` block of Claude Code's status-line payload, windows keyed by name."""
    if not isinstance(rl, dict):
        rl = {}
    five_hour, seven_day, spend = (_window(rl.get(key), "used_percentage") for key in ("five_hour", "seven_day", "spend_limit"))
    return Usage(five_hour, seven_day, spend, None, updated_at)


def parse_codex_rate_limits(rl: dict[str, Any], updated_at: int) -> Usage:
    """The `rate_limits` block Codex writes into every `token_count` record of its rollout file.
    `primary`/`secondary` are told apart by `window_minutes` (300 → 5h, 10080 → wk); a window of
    unknown length fills 5h first, then wk."""
    five_hour = seven_day = None
    for key in ("primary", "secondary"):
        w = _window(rl.get(key), "used_percent")
        if w is None:
            continue
        mins = rl[key].get("window_minutes")
        if mins == WEEK_MINS and not isinstance(mins, bool) and seven_day is None:
            seven_day = w
        elif mins == FIVE_HOUR_MINS and not isinstance(mins, bool) and five_hour is None:
            five_hour = w
        elif five_hour is None:
            five_hour = w
        elif seven_day is None:
            seven_day = w
    plan = rl.get("plan_type")
    return Usage(five_hour, seven_day, None, plan if isinstance(plan, str) else None, updated_at)
