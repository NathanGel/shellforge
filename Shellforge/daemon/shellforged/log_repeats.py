"""One line for a failure that repeats: the helper's tick runs every 2 s, and a check that fails on
every tick would otherwise write the same line all day into a log only the app's launch empties."""
from __future__ import annotations

import copy
import logging
import threading
import time
from collections.abc import Callable


class RepeatFilter(logging.Filter):
    """Lets a message through once per `every` seconds; the next one through says how many were held
    back. A message is its logger, level, words as formatted, and the kind of exception it carries:
    the same words over a different failure are a different message."""

    #: How many distinct messages are remembered; past it the oldest go first.
    LIMIT = 256

    def __init__(self, every: float = 300, clock: Callable[[], float] = time.monotonic):
        super().__init__()
        self.every, self.clock = every, clock
        self._lock = threading.Lock()  # the helper logs from worker threads too
        # key -> (when it was last let through, how many held back since)
        self._seen: dict[tuple[str, int, str, str], tuple[float, int]] = {}

    def filter(self, record: logging.LogRecord) -> bool | logging.LogRecord:
        kind = record.exc_info[0].__name__ if record.exc_info and record.exc_info[0] else ""
        key = (record.name, record.levelno, record.getMessage(), kind)
        with self._lock:
            now = self.clock()
            last = self._seen.get(key)
            if last is not None and now - last[0] < self.every:
                self._seen[key] = (last[0], last[1] + 1)
                return False
            self._seen.pop(key, None)
            self._seen[key] = (now, 0)  # newest last, so the oldest go first past LIMIT
            while len(self._seen) > self.LIMIT:
                del self._seen[next(iter(self._seen))]
        if last is None or not last[1]:
            return True
        # A copy carries the count: other handlers see the record as it was logged.
        said = copy.copy(record)
        said.msg, said.args = f"{record.getMessage()} (repeated {last[1]} more times in the last {now - last[0]:.0f} s)", None
        return said
