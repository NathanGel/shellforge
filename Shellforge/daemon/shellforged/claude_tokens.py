"""What a Claude conversation has spent, summed from its transcripts."""
from __future__ import annotations
import contextlib
import json
from dataclasses import dataclass, field
from pathlib import Path

from .models import TokenTally
from .usage import whole_count

# The model Claude Code names on a message it wrote itself -- an error, an interruption -- with
# all-zero usage: no call was made.
SYNTHETIC_MODEL = "<synthetic>"
# What every line carrying a reply's usage contains, so the rest are skipped unparsed.
_USAGE = b'"usage"'

Stamp = tuple[Path, int, int]  # path, st_ino, st_size


@dataclass(slots=True)
class _Cursor:
    """How far one transcript has been read: the byte offset, the inode it was read from, and the
    start of a line Claude was still writing."""
    inode: int
    offset: int = 0
    partial: bytes = b""


@dataclass(slots=True)
class _Conversation:
    cursors: dict[Path, _Cursor] = field(default_factory=dict)
    # Each reply's (input, cached, output) by `message.id`. Claude writes a reply as one line per
    # content block, each repeating its usage and the last with the final output count, so each field
    # keeps the most any of its lines said. Kept across the whole tree: a forked subagent copies its
    # parent's replies, and a fork read after the parent may hold only a reply's partial first line.
    replies: dict[str, tuple[int, int, int]] = field(default_factory=dict)
    stamps: tuple[Stamp, ...] | None = None
    tally: TokenTally | None = None


class ClaudeTranscriptTallies:
    """What each Claude conversation has spent: its transcript's replies and those of every subagent
    beside it. Foreground, background, teammate or nested, Claude writes each child to
    `<transcript without .jsonl>/subagents/**/agent-*.jsonl` (any depth below `subagents/`: a
    workflow's agents sit one directory deeper), and the parent's own records never hold a child's
    calls. The records that restate a child's spend on the parent (`toolUseResult.usage`, a task
    notification's `usage`) are not replies and are never counted. Transcripts only grow, so each is
    read on from where the last read stopped.

    Not counted: Claude's compaction and title calls, which reach no transcript.

    Blocking file I/O: the service runs it on a worker thread."""

    def __init__(self) -> None:
        self._conversations: dict[str, _Conversation] = {}

    def retain(self, transcripts: set[str]) -> None:
        """Drops the conversations no tab runs any more."""
        for transcript in self._conversations.keys() - transcripts:
            del self._conversations[transcript]

    def tally(self, transcript: str) -> TokenTally | None:
        """The conversation's spend so far, or None before its first reply."""
        stamps = self._stamps(Path(transcript))
        conversation = self._conversations.setdefault(transcript, _Conversation())
        if stamps == conversation.stamps:
            return conversation.tally
        if any(self._rewritten(conversation.cursors.get(path), inode, size) for path, inode, size in stamps):
            # Not a transcript Claude appended to: start over rather than count a file twice, or
            # from the middle of a line.
            conversation = self._conversations[transcript] = _Conversation()
        for path, inode, size in stamps:
            self._read(path, inode, size, conversation)
        conversation.stamps = stamps
        conversation.tally = TokenTally.combined(TokenTally(*reply) for reply in conversation.replies.values())
        return conversation.tally

    @staticmethod
    def _stamps(transcript: Path) -> tuple[Stamp, ...]:
        """The transcript and its subagents' that exist, each with its inode and size."""
        paths = [transcript]
        with contextlib.suppress(OSError):
            paths += sorted(transcript.with_suffix("").joinpath("subagents").rglob("agent-*.jsonl"))
        stamps: list[Stamp] = []
        for path in paths:
            try:
                st = path.stat()
            except OSError:
                continue
            stamps.append((path, st.st_ino, st.st_size))
        return tuple(stamps)

    @staticmethod
    def _rewritten(cursor: _Cursor | None, inode: int, size: int) -> bool:
        return cursor is not None and (cursor.inode != inode or size < cursor.offset)

    @classmethod
    def _read(cls, path: Path, inode: int, size: int, conversation: _Conversation) -> None:
        """Reads `path` on from its cursor to `size`, the length it was stamped at, and keeps an
        unfinished last line for the next read."""
        cursor = conversation.cursors.setdefault(path, _Cursor(inode))
        if size <= cursor.offset:
            return
        try:
            with path.open("rb") as stream:
                stream.seek(cursor.offset)
                chunk = stream.read(size - cursor.offset)
        except OSError:
            return
        cursor.offset += len(chunk)
        *lines, cursor.partial = (cursor.partial + chunk).split(b"\n")
        for line in lines:
            if _USAGE in line and (reply := cls._reply(line)) is not None:
                reply_id, spent = reply
                kept = conversation.replies.get(reply_id)
                # The most of each field, not the last line read: a count only ever grows.
                conversation.replies[reply_id] = spent if kept is None else (
                    max(kept[0], spent[0]), max(kept[1], spent[1]), max(kept[2], spent[2]))

    @staticmethod
    def _reply(line: bytes) -> tuple[str, tuple[int, int, int]] | None:
        """A reply's id and its (input, cached, output); None for any line that is not one."""
        try:
            record = json.loads(line)
        except (UnicodeDecodeError, ValueError):
            return None
        if not isinstance(record, dict) or record.get("type") != "assistant":
            return None
        message = record.get("message")
        if not isinstance(message, dict) or message.get("model") == SYNTHETIC_MODEL:
            return None
        reply_id, usage = message.get("id"), message.get("usage")
        if not isinstance(reply_id, str) or not reply_id or not isinstance(usage, dict):
            return None
        fresh, written, read, output = (whole_count(usage.get(key)) or 0 for key in (
            "input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"))
        # Claude's `input_tokens` leaves the cache out; the tally counts it in.
        return reply_id, (fresh + written + read, written + read, output)
