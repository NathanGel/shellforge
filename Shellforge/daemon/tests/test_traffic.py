# daemon/tests/test_traffic.py
"""A running tunnel's bytes in and out, as `nettop` counts them for its ssh. nettop is injected:
nothing here runs the real one."""
import asyncio

import pytest

from shellforged import traffic
from shellforged.tunnels import TunnelSupervisor
from tests.conftest import wait_until
from tests.test_tunnels import Events, ssh_env  # noqa: F401 - the fixture


def test_parses_nettop_rows():
    text = ",bytes_in,bytes_out,\nssh.14718,2749,2594,\nssh.200,0,12,\n"
    assert traffic.parse(text) == {14718: (2749, 2594), 200: (0, 12)}


@pytest.mark.parametrize("text", ["", "garbage", ",bytes_in,bytes_out,\nssh.x,1,2,\n", "ssh.5,a,b,\n", "ssh.5,1\n"])
def test_unexpected_rows_are_skipped(text):
    assert traffic.parse(text) == {}


async def test_sample_asks_nettop_for_the_pids():
    asked = []

    async def run(args):
        asked.append(args)
        return ",bytes_in,bytes_out,\nssh.7,10,20,\n"

    assert await traffic.sample([7, 9], run=run) == {7: (10, 20)}
    assert asked == [["/usr/bin/nettop", "-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out", "-p", "7", "-p", "9"]]
    assert await traffic.sample([], run=run) == {} and len(asked) == 1, "no pids, no nettop"


async def test_a_broken_nettop_leaves_bytes_unknown(ssh_env):
    """Missing, failing or hanging: the sampler keeps going and the tunnel's state never moves."""
    async def broken(args):
        return None

    events = Events()
    tunnels = TunnelSupervisor(events.broadcast, up_after=0.2, traffic_every=0.1, sample=lambda pids: traffic.sample(pids, run=broken))
    await tunnels.start("db", ssh_env())
    await wait_until(lambda: "up" in events.states("db"))
    await asyncio.sleep(0.4)
    assert tunnels.list()[0]["bytesIn"] is None and tunnels.list()[0]["state"] == "up"
    assert events.states("db") == ["connecting", "up"]
    await tunnels.stop_all()


async def test_a_hanging_nettop_times_out():
    assert await traffic.run_nettop(["/bin/sleep", "10"], timeout=0.2) is None
    assert await traffic.run_nettop(["/nonexistent/nettop"], timeout=0.2) is None


async def test_up_tunnels_get_their_bytes(ssh_env):
    counts = {"n": 0}

    async def fake(pids):
        counts["n"] += 1
        return {pid: (1000 * counts["n"], 50) for pid in pids}

    events = Events()
    tunnels = TunnelSupervisor(events.broadcast, up_after=0.2, traffic_every=0.1, sample=fake)
    await tunnels.start("db", ssh_env())
    await wait_until(lambda: any(e.get("bytesIn") for e in events.seen), timeout=3)
    first = next(e for e in events.seen if e.get("bytesIn"))
    assert first["state"] == "up" and first["bytesOut"] == 50
    await tunnels.stop_all()
    assert tunnels.list()[0]["bytesIn"] is None, "a stopped tunnel has no traffic to show"
