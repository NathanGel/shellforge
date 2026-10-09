from __future__ import annotations
import json
import os
from collections.abc import Collection
from dataclasses import dataclass
from pathlib import Path
from typing import Any

# How much of a transcript's end is read. The records that end a child -- an interruption, a
# SubagentStop hook's attachment -- are a few hundred bytes; a transcript grows to megabytes.
TAIL_BYTES = 64 * 1024
# The text Claude Code writes as a user message when it aborts an agent's run: Esc, or its stream
# watchdog ("Agent stalled: no progress for 600s"). Mid-tool it reads "... for tool use]".
INTERRUPTED = "[Request interrupted by user"


@dataclass(frozen=True, slots=True)
class TranscriptTail:
    """What the end of a subagent's transcript says. `stamp` is (st_mtime_ns, st_size), which
    changes whenever Claude appends; `written_at` is the st_mtime, in the wall clock's seconds."""
    stamp: tuple[int, int]
    written_at: float
    # The last record ends the child's run: an interruption, or a SubagentStop hook that ran.
    ended: bool


def _is_interruption(record: dict[str, Any]) -> bool:
    if record.get("type") != "user" or not isinstance(message := record.get("message"), dict):
        return False
    content = message.get("content")
    if isinstance(content, str):
        return content.startswith(INTERRUPTED)
    return isinstance(content, list) and any(
        isinstance(block, dict) and block.get("type") == "text" and isinstance(text := block.get("text"), str)
        and text.startswith(INTERRUPTED) for block in content)


def _is_subagent_stop(record: dict[str, Any]) -> bool:
    """A SubagentStop hook's attachment, whatever came of the hook: Claude sent it, so the child
    stopped, even if the daemon never saw the post."""
    return record.get("type") == "attachment" and isinstance(a := record.get("attachment"), dict) \
        and a.get("hookEvent") == "SubagentStop"


def _has_ended(tail: bytes) -> bool:
    """Whether the last complete record in `tail` ends the child. A record still being written, or
    one longer than the tail, is neither of the small records that do."""
    if not tail.endswith(b"\n"):
        return False
    body = tail[:-1]
    start = body.rfind(b"\n")
    if start < 0 and len(tail) >= TAIL_BYTES:
        return False
    try:
        record = json.loads(body[start + 1:])
    except ValueError:
        return False
    return isinstance(record, dict) and (_is_interruption(record) or _is_subagent_stop(record))


# A transcript as last read, keyed by its stamp: only a file Claude has appended to since is read again.
_Entry = tuple[tuple[int, int], TranscriptTail]


class SubagentTranscripts:
    """Reads the end of Claude subagents' transcripts, for the status engine's check on children
    whose SubagentStop never came. Blocking file I/O: the service runs it on a worker thread."""

    def __init__(self) -> None:
        self._cache: dict[str, _Entry] = {}

    def read_all(self, paths: Collection[str]) -> dict[str, TranscriptTail]:
        """Each of `paths` that exists, read; the cache keeps only these."""
        found = {path: tail for path in paths if (tail := self.read(path)) is not None}
        self._cache = {path: entry for path, entry in self._cache.items() if path in found}
        return found

    def read(self, path: str) -> TranscriptTail | None:
        """The end of the transcript at `path`, or of the same file in a subdirectory beside it --
        Claude Code files some agents under `subagents/<subdir>/`. None while neither exists."""
        if (st := self._stat(path)) is None:
            return None
        real, stat = st
        stamp = (stat.st_mtime_ns, stat.st_size)
        if (cached := self._cache.get(path)) is not None and cached[0] == stamp:
            return cached[1]
        try:
            with open(real, "rb") as f:
                f.seek(max(0, stat.st_size - TAIL_BYTES))
                ended = _has_ended(f.read(TAIL_BYTES))
        except OSError:
            return None
        tail = TranscriptTail(stamp, stat.st_mtime, ended)
        self._cache[path] = (stamp, tail)
        return tail

    @staticmethod
    def _stat(path: str) -> tuple[str, os.stat_result] | None:
        try:
            return path, os.stat(path)
        except (OSError, ValueError):
            pass
        try:
            p = Path(path)
            for candidate in p.parent.glob(f"*/{p.name}"):
                return str(candidate), candidate.stat()
        except (OSError, ValueError):
            pass
        return None
