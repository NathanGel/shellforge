"""One line for a failure that repeats: the helper's tick runs every 2 s, and a check that fails on
every tick would otherwise write the same line all day into a log only the app's launch empties."""
from __future__ import annotations

import logging
import time
from collections.abc import Callable


class RepeatFilter(logging.Filter):
    """Lets a message through once per `every` seconds; the next one through says how many were held
    back. A message is its logger, level and format string, so the same failure with a different
    detail is still the same message."""

    def __init__(self, every: float = 300, clock: Callable[[], float] = time.monotonic):
        super().__init__()
        self.every, self.clock = every, clock
        # (logger, level, format) -> (when it was last let through, how many held back since)
        self._seen: dict[tuple[str, int, str], tuple[float, int]] = {}

    def filter(self, record: logging.LogRecord) -> bool:
        now = self.clock()
        key = (record.name, record.levelno, str(record.msg))
        last = self._seen.get(key)
        if last is not None and now - last[0] < self.every:
            self._seen[key] = (last[0], last[1] + 1)
            return False
        if last is not None and last[1]:
            record.msg = f"{record.msg} (repeated {last[1]} more times in the last {now - last[0]:.0f} s)"
        self._seen[key] = (now, 0)
        # Kept to the messages seen within the window: the format strings are few, but not fixed.
        if len(self._seen) > 256:
            self._seen = {k: v for k, v in self._seen.items() if now - v[0] < self.every}
        return True
