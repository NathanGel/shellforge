"""A tunnel's traffic: the bytes its ssh has received and sent, as `nettop` counts them per process.
nettop is a system tool on every Mac; when it is missing, fails or hangs, the counts are unknown,
and nothing else changes."""
from __future__ import annotations

import asyncio
import contextlib
from collections.abc import Awaitable, Callable

NETTOP = "/usr/bin/nettop"


def parse(text: str) -> dict[int, tuple[int, int]]:
    """`nettop -x -J bytes_in,bytes_out`'s CSV: a header, then `<name>.<pid>,<in>,<out>,` per process."""
    counts: dict[int, tuple[int, int]] = {}
    for line in text.splitlines():
        fields = line.split(",")
        if len(fields) < 3:
            continue
        name, _, pid = fields[0].rpartition(".")
        if not name or not pid.isdigit() or not fields[1].isdigit() or not fields[2].isdigit():
            continue
        counts[int(pid)] = (int(fields[1]), int(fields[2]))
    return counts


# `nettop -L 1` waits one sampling interval before it prints, about five seconds whatever `-s`
# says: it is given twice that.
NETTOP_TIMEOUT = 10.0


async def run_nettop(args: list[str], timeout: float = NETTOP_TIMEOUT) -> str | None:
    """`args`' output, or None when it cannot start, fails, or runs past `timeout`."""
    try:
        process = await asyncio.create_subprocess_exec(*args, stdin=asyncio.subprocess.DEVNULL,
                                                       stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
    except OSError:
        return None
    try:
        out, _ = await asyncio.wait_for(process.communicate(), timeout)
    except TimeoutError:
        with contextlib.suppress(ProcessLookupError):
            process.kill()
        await process.wait()
        return None
    return out.decode(errors="replace") if process.returncode == 0 else None


async def sample(pids: list[int], run: Callable[[list[str]], Awaitable[str | None]] = run_nettop) -> dict[int, tuple[int, int]]:
    """Each pid's bytes in and out; a pid nettop did not report is left out."""
    if not pids:
        return {}
    args = [NETTOP, "-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]
    for pid in pids:
        args += ["-p", str(pid)]
    text = await run(args)
    return parse(text) if text else {}
