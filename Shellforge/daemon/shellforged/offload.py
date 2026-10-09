"""Blocking work for a worker thread that cannot hold the daemon open."""
from __future__ import annotations
import asyncio
import threading
from collections.abc import Callable
from typing import TypeVar

T = TypeVar("T")


def run_detached(work: Callable[[], T]) -> asyncio.Future[T]:
    """`work`, run on a daemon thread, resolving the returned future on the running loop.

    `asyncio.to_thread` runs on the loop's default executor, which `asyncio.run` joins on exit
    (forever on Python 3.11, 300 s from 3.12). A `stat` stuck on a dead mount, or an osascript
    waiting on a permission dialog, would hold an otherwise finished daemon open after it had
    unlinked its socket. A daemon thread dies with the process instead. Cancelling the future
    abandons the thread's result; it cannot stop the thread."""
    loop = asyncio.get_running_loop()
    future: asyncio.Future[T] = loop.create_future()

    def settle(result: T | None, error: BaseException | None) -> None:
        if future.done():  # cancelled while the thread ran
            return
        if error is not None:
            future.set_exception(error)
        else:
            future.set_result(result)  # type: ignore[arg-type]

    def run() -> None:
        result: T | None = None
        error: BaseException | None = None
        try:
            result = work()
        except BaseException as exc:  # noqa: BLE001 - handed to whoever awaits the future
            error = exc
        try:
            loop.call_soon_threadsafe(settle, result, error)
        except RuntimeError:  # the loop closed first: nobody is waiting
            pass

    threading.Thread(target=run, name="shellforged-offload", daemon=True).start()
    return future
