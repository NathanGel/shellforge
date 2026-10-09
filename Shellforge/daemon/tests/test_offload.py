import asyncio
import threading

import pytest

from shellforged.offload import run_detached


async def test_it_answers_what_the_work_returns():
    assert await run_detached(lambda: 7) == 7


async def test_it_raises_what_the_work_raises():
    def broken():
        raise ValueError("boom")

    with pytest.raises(ValueError, match="boom"):
        await run_detached(broken)


async def test_work_that_finishes_after_its_future_was_cancelled_disturbs_nothing():
    release, handled = threading.Event(), []
    asyncio.get_running_loop().set_exception_handler(lambda loop, context: handled.append(context))
    future = run_detached(lambda: release.wait(5))
    future.cancel()
    release.set()
    await asyncio.sleep(0.05)
    assert future.cancelled() and handled == []
