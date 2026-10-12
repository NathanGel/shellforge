# daemon/tests/test_tunnel_hold.py
"""A tunnel held by a terminal tab: ssh needed an answer, so the app ran it in a tab where the user
can give one. The daemon watches its port -- up while it accepts -- and when the tab's ssh ends,
hands the tunnel back to supervision with one batch-mode start."""
import asyncio

import pytest

from shellforged.tunnels import TunnelSupervisor
from tests.conftest import wait_until
from tests.test_service import call
from tests.test_tunnels import Events, ssh_env, tunnel_stack  # noqa: F401 - fixtures


def held(events, **overrides):
    return TunnelSupervisor(events.broadcast, **{"up_after": 0.2, "backoff_start": 0.1, "backoff_cap": 0.4,
                                                  "probe_every": 0.05, "hold_timeout": 2.0, **overrides})


async def listener():
    """A local port that accepts, as the tab's ssh's forward would."""
    server = await asyncio.start_server(lambda r, w: w.close(), "127.0.0.1", 0)
    return server, server.sockets[0].getsockname()[1]


async def test_a_prompt_failure_says_it_needs_input(ssh_env):
    events = Events()
    tunnels = held(events)
    await tunnels.start("db", ssh_env("fail", FAKE_SSH_LINE="Host key verification failed."))
    await wait_until(lambda: "failed" in events.states("db"))
    assert tunnels.list()[0]["needsInput"] is True
    await tunnels.start("web", ssh_env("fail"))
    await wait_until(lambda: "failed" in events.states("web"))
    assert tunnels.list()[1]["needsInput"] is None, "a taken port needs no answer"
    await tunnels.stop_all()


async def test_a_held_tunnel_is_up_while_its_port_accepts(ssh_env):
    events = Events()
    tunnels = held(events)
    await tunnels.start("db", ssh_env("fail", FAKE_SSH_LINE="Permission denied (keyboard-interactive)."))
    await wait_until(lambda: "failed" in events.states("db"))
    server, port = await listener()
    await tunnels.hold("db", port)
    await wait_until(lambda: tunnels.list()[0]["state"] == "up")
    info = tunnels.list()[0]
    assert info["heldBy"] == "tab" and info["error"] is None and info["needsInput"] is None
    assert tunnels.pid("db") is None, "no ssh of the supervisor's runs while the tab holds it"
    server.close()
    await tunnels.stop_all()


async def test_a_held_tunnel_is_handed_back_when_its_port_closes(ssh_env):
    events = Events()
    tunnels = held(events)
    await tunnels.start("db", ssh_env("fail", FAKE_SSH_LINE="Host key verification failed."))
    await wait_until(lambda: "failed" in events.states("db"))
    server, port = await listener()
    await tunnels.hold("db", port)
    await wait_until(lambda: tunnels.list()[0]["state"] == "up")
    server.close()
    await server.wait_closed()
    # Handed back: started once in batch mode with the environment of the last start, which here
    # fails again, so the row offers the tab again.
    await wait_until(lambda: tunnels.list()[0]["heldBy"] is None and tunnels.list()[0]["state"] == "failed", timeout=3)
    assert tunnels.list()[0]["needsInput"] is True
    await tunnels.stop_all()


async def test_a_hold_that_never_comes_up_ends(ssh_env):
    events = Events()
    tunnels = held(events, hold_timeout=0.3)
    server, port = await listener()
    server.close()
    await server.wait_closed()
    await tunnels.hold("db", port)
    assert tunnels.list()[0]["state"] == "connecting" and tunnels.list()[0]["heldBy"] == "tab"
    await wait_until(lambda: tunnels.list()[0]["state"] == "stopped", timeout=3)
    assert tunnels.list()[0]["heldBy"] is None, "no start ever sent: nothing to hand back to"
    await tunnels.stop_all()


async def test_stopping_a_held_tunnel_stops_watching_it(ssh_env):
    events = Events()
    tunnels = held(events)
    server, port = await listener()
    await tunnels.hold("db", port)
    await wait_until(lambda: tunnels.list()[0]["state"] == "up")
    await tunnels.stop("db")
    assert tunnels.list()[0]["state"] == "stopped" and tunnels.list()[0]["heldBy"] is None
    server.close()


async def test_tunnels_hold_through_the_daemon(tunnel_stack):
    svc, r, w = tunnel_stack
    server, port = await listener()
    assert (await call(r, w, "tunnels.hold", {"alias": "db", "port": port}))["result"] == {"ok": True}
    await wait_until(lambda: svc.tunnels.list()[0]["state"] == "up")
    server.close()
    await svc.tunnels.stop("db")


@pytest.mark.parametrize("params", [{}, {"alias": "db"}, {"alias": "db", "port": 0}, {"alias": "db", "port": 70000},
                                    {"alias": "db", "port": "22"}, {"alias": "-x", "port": 22}, {"alias": "db", "port": True}])
async def test_malformed_hold_params_are_bad_params(tunnel_stack, params):
    svc, r, w = tunnel_stack
    assert (await call(r, w, "tunnels.hold", params))["error"]["code"] == "bad_params"
