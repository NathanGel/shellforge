from __future__ import annotations
import json
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True, slots=True)
class ClaudeSessionFile:
    pid: int
    session_id: str
    cwd: str
    status: str
    # When Claude last wrote the file (its st_mtime): a status older than the latest hook is stale.
    written_at: float


# A session file as last parsed, keyed by (st_mtime_ns, st_size): only a file Claude has rewritten
# since needs parsing again.
_Entry = tuple[tuple[int, int], ClaudeSessionFile | None]


class ClaudeSessionFiles:
    def __init__(self, root: Path | None = None):
        self.root = root or Path.home() / ".claude" / "sessions"
        # Every session file as last parsed. A tick reads each Claude tab's file and a hook post
        # asks for a pid by session id; both go through this, so an unchanged file is not reparsed.
        self._index: dict[Path, _Entry] = {}

    def read(self, pid: int) -> ClaudeSessionFile | None:
        path = self.root / f"{pid}.json"
        if (entry := self._load(path)) is None:
            self._index.pop(path, None)
            return None
        self._index[path] = entry
        return entry[1]

    def pid_for_session(self, session_id: str) -> int | None:
        if not self.root.is_dir():
            return None
        index = {path: entry for path in self.root.glob("*.json") if (entry := self._load(path)) is not None}
        self._index = index
        return next((f.pid for _, f in index.values() if f and f.session_id == session_id), None)

    def _load(self, path: Path) -> _Entry | None:
        """The file at `path`, reparsed only if it changed since the last look; None when it is gone."""
        try:
            st = path.stat()
        except OSError:
            return None
        stamp = (st.st_mtime_ns, st.st_size)
        cached = self._index.get(path)
        return cached if cached is not None and cached[0] == stamp else (stamp, self._parse(path, st.st_mtime))

    @staticmethod
    def _parse(path: Path, written_at: float) -> ClaudeSessionFile | None:
        try:
            d = json.loads(path.read_text())
            return ClaudeSessionFile(int(d["pid"]), str(d["sessionId"]), str(d.get("cwd", "")), str(d.get("status", "")),
                                     written_at)
        except (OSError, ValueError, KeyError, TypeError, OverflowError):
            return None
