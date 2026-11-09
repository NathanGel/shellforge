"""Armed launches: the app hands the helper an agent's environment for one tab, and `shellforge-run`
in that tab takes it once, within ARM_TTL_SECONDS."""
import asyncio

import pytest

from shellforged.launch_env import ARM_TTL_SECONDS, TAKE_WAIT_SECONDS, LaunchEnvironments

SECRET = {"API_KEY": "sk-test-value"}


class Clock:
    def __init__(self):
        self.now = 100.0

    def __call__(self):
        return self.now


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def launches(clock):
    return LaunchEnvironments(clock)


def test_the_timings():
    assert ARM_TTL_SECONDS == 60.0 and TAKE_WAIT_SECONDS == 10.0


async def test_take_returns_the_arm_once(launches):
    launches.arm("ABC", "gemini", SECRET)
    assert await launches.take("ABC", "gemini", timeout=0) == SECRET
    assert await launches.take("ABC", "gemini", timeout=0) is None


async def test_take_waits_for_a_late_arm(launches):
    taking = asyncio.create_task(launches.take("w0t0p0:ABC", "gemini", timeout=TAKE_WAIT_SECONDS))
    await asyncio.sleep(0)  # the take is now waiting
    assert not taking.done()
    launches.arm("ABC", "gemini", SECRET)
    assert await asyncio.wait_for(taking, 1) == SECRET


async def test_take_times_out(launches):
    assert await launches.take("ABC", "gemini", timeout=0) is None


async def test_wrong_agent_gets_nothing(launches):
    launches.arm("ABC", "gemini", SECRET)
    assert await launches.take("ABC", "aider", timeout=0) is None
    # Nor did asking for it spend the arm.
    assert await launches.take("ABC", "gemini", timeout=0) == SECRET


async def test_another_tab_gets_nothing(launches):
    launches.arm("ABC", "gemini", SECRET)
    assert await launches.take("w0t1p0:XYZ", "gemini", timeout=0) is None
    assert await launches.take("", "gemini", timeout=0) is None


async def test_expired_arm_gets_nothing(launches, clock):
    launches.arm("ABC", "gemini", SECRET)
    clock.now += ARM_TTL_SECONDS + 0.1
    assert await launches.take("ABC", "gemini", timeout=0) is None


async def test_an_arm_just_inside_its_time_is_taken(launches, clock):
    launches.arm("ABC", "gemini", SECRET)
    clock.now += ARM_TTL_SECONDS - 0.1
    assert await launches.take("ABC", "gemini", timeout=0) == SECRET


async def test_an_expired_arm_is_dropped_by_the_next_call(launches, clock):
    launches.arm("ABC", "gemini", SECRET)
    clock.now += ARM_TTL_SECONDS + 0.1
    launches.arm("DEF", "aider", {})
    assert launches.armed_sessions() == ["DEF"]


async def test_pane_prefix_matches(launches):
    launches.arm("ABC", "gemini", SECRET)
    assert await launches.take("w1t0p0:ABC", "gemini", timeout=0) == SECRET


async def test_a_new_arm_for_a_tab_replaces_the_old(launches):
    launches.arm("ABC", "gemini", SECRET)
    launches.arm("ABC", "aider", {"OTHER": "x"})
    assert await launches.take("ABC", "gemini", timeout=0) is None
    assert await launches.take("ABC", "aider", timeout=0) == {"OTHER": "x"}


async def test_an_empty_environment_is_still_an_arm(launches):
    launches.arm("ABC", "goose", {})
    assert await launches.take("ABC", "goose", timeout=0) == {}
    assert await launches.take("ABC", "goose", timeout=0) is None


async def test_the_taken_environment_is_a_copy(launches):
    given = {"API_KEY": "v"}
    launches.arm("ABC", "gemini", given)
    given["API_KEY"] = "changed"
    assert await launches.take("ABC", "gemini", timeout=0) == {"API_KEY": "v"}


async def test_two_takes_for_one_arm_get_it_once(launches):
    first = asyncio.create_task(launches.take("ABC", "gemini", timeout=TAKE_WAIT_SECONDS))
    second = asyncio.create_task(launches.take("ABC", "gemini", timeout=0.05))
    await asyncio.sleep(0)
    launches.arm("ABC", "gemini", SECRET)
    results = await asyncio.wait_for(asyncio.gather(first, second), 1)
    assert sorted(results, key=lambda r: r is None) == [SECRET, None]


def test_an_arms_repr_shows_no_value(launches):
    launches.arm("ABC", "gemini", SECRET)
    assert "sk-test-value" not in repr(launches._arms["ABC"])


async def test_a_refused_caller_gets_nothing_and_the_arm_stays(launches):
    async def no(tab):
        return False

    launches.arm("ABC", "gemini", SECRET)
    assert await launches.take("ABC", "gemini", timeout=1, check=no) is None
    assert launches.armed_sessions() == ["ABC"]


async def test_a_caller_not_known_yet_waits_for_a_change(launches):
    verdicts = [None, True]
    asked = []

    async def later(tab):
        asked.append(tab)
        return verdicts[len(asked) - 1]

    launches.arm("ABC", "gemini", SECRET)
    taking = asyncio.create_task(launches.take("ABC", "gemini", timeout=TAKE_WAIT_SECONDS, check=later))
    await asyncio.sleep(0)
    assert asked == ["ABC"] and not taking.done()
    launches.changed()
    assert await asyncio.wait_for(taking, 1) == SECRET and asked == ["ABC", "ABC"]


async def test_a_caller_never_known_gets_nothing(launches):
    async def unknown(tab):
        return None

    launches.arm("ABC", "gemini", SECRET)
    assert await launches.take("ABC", "gemini", timeout=0, check=unknown) is None
    assert launches.armed_sessions() == ["ABC"]


async def test_an_arm_replaced_while_the_check_ran_is_not_taken(launches):
    async def replacing(tab):
        launches.arm("ABC", "gemini", {"API_KEY": "newer"})
        return True

    launches.arm("ABC", "gemini", SECRET)
    # The newer arm is checked in turn, and taken.
    calls = []

    async def once_replacing(tab):
        calls.append(tab)
        return await replacing(tab) if len(calls) == 1 else True

    assert await launches.take("ABC", "gemini", timeout=1, check=once_replacing) == {"API_KEY": "newer"}
    assert len(calls) == 2
