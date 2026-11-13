"""The helper's per-user secret: one random token in `hook-token` in the support folder, readable
by its owner only. The app shows it to claim the app-only RPC methods (`app.hello`), and every hook,
shim and status line sends it to the hook port in the `X-Shellforge-Token` header, so another
account on the Mac can neither post status events nor pass as the app.

The file holds the header line itself, `X-Shellforge-Token: <64 hex digits>`, so a curl command can
send it with `-H @<file>` and the token never appears in a command line, which `ps` shows to every
account. The Swift package's `HookToken` reads and writes the same file the same way: whichever of
the app and the helper comes first creates it, and the other reads it."""
from __future__ import annotations

import hmac
import os
import re
import secrets
import stat
from pathlib import Path

FILE_NAME = "hook-token"
HEADER = "X-Shellforge-Token"
_LINE = re.compile(rb"\AX-Shellforge-Token: ([0-9a-f]{64})\n?\Z")
# The longest file read: the line, and room for a stray byte that makes it invalid.
_MAX_BYTES = 128


def path_in(folder: Path) -> Path:
    return folder / FILE_NAME


def line(token: str) -> bytes:
    return f"{HEADER}: {token}\n".encode()


def read(folder: Path) -> str | None:
    """The token in `folder`, or None when there is none to trust: no file, a symlink, anything but
    a regular file of this user's that no one else may read, or anything but the one line."""
    try:
        fd = os.open(path_in(folder), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            return None
        data = os.read(fd, _MAX_BYTES)
    except OSError:
        return None
    finally:
        os.close(fd)
    match = _LINE.match(data)
    return match.group(1).decode() if match else None


def read_or_create(folder: Path) -> str:
    """The token in `folder`, made first when there is none to trust. Made whole and out of sight,
    then linked into place, which fails when another process made one first: that one is used. A
    file that cannot be trusted is replaced rather than read."""
    if (token := read(folder)) is not None:
        return token
    folder.mkdir(parents=True, exist_ok=True)
    target = path_in(folder)
    temporary = folder / f".{FILE_NAME}.{os.getpid()}.{secrets.token_hex(4)}.tmp"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        try:
            os.write(fd, line(secrets.token_hex(32)))
            os.fsync(fd)
        finally:
            os.close(fd)
        try:
            os.link(temporary, target)  # never follows a link at `target`: that is an existing file
        except FileExistsError:
            if read(folder) is None:
                os.replace(temporary, target)  # replaces a link or a bad file itself, never what it names
    finally:
        temporary.unlink(missing_ok=True)
    if (token := read(folder)) is None:
        raise OSError(f"{target} could not be made private")
    return token


class HookToken:
    """The token the helper checks against: read or made once at start, and read again when a
    presented one does not match, in case the file was replaced since."""

    def __init__(self, folder: Path):
        self.folder = folder
        self._token = read_or_create(folder)

    def matches(self, presented: str | None) -> bool:
        if not presented:
            return False
        if hmac.compare_digest(presented.encode(), self._token.encode()):
            return True
        if (current := read(self.folder)) is None or current == self._token:
            return False
        self._token = current
        return hmac.compare_digest(presented.encode(), current.encode())
