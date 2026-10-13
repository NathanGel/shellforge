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


async def listener(port=0):
    """A local port that is bound, as the tab's ssh's forward would be."""
    server = await asyncio.start_server(lambda r, w: w.close(), "127.0.0.1", port)
    return server, server.sockets[0].getsockname()[1]


def free_port():
    import socket
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


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
    port = free_port()
    await tunnels.hold("db", port)
    server, _ = await listener(port)
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
    port = free_port()
    await tunnels.hold("db", port)
    server, _ = await listener(port)
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
    await tunnels.hold("db", free_port())
    assert tunnels.list()[0]["state"] == "connecting" and tunnels.list()[0]["heldBy"] == "tab"
    await wait_until(lambda: tunnels.list()[0]["state"] == "stopped", timeout=3)
    assert tunnels.list()[0]["heldBy"] is None, "no start ever sent: nothing to hand back to"
    await tunnels.stop_all()


async def test_stopping_a_held_tunnel_stops_watching_it(ssh_env):
    events = Events()
    tunnels = held(events)
    port = free_port()
    await tunnels.hold("db", port)
    server, _ = await listener(port)
    await wait_until(lambda: tunnels.list()[0]["state"] == "up")
    await tunnels.stop("db")
    assert tunnels.list()[0]["state"] == "stopped" and tunnels.list()[0]["heldBy"] is None
    server.close()
    await server.wait_closed()


async def test_tunnels_hold_through_the_daemon(tunnel_stack):
    svc, r, w = tunnel_stack
    port = free_port()
    assert (await call(r, w, "tunnels.hold", {"alias": "db", "port": port}))["result"] == {"ok": True}
    server, _ = await listener(port)
    await wait_until(lambda: svc.tunnels.list()[0]["state"] == "up")
    server.close()
    await server.wait_closed()
    await svc.tunnels.stop("db")


@pytest.mark.parametrize("params", [{}, {"alias": "db"}, {"alias": "db", "port": 0}, {"alias": "db", "port": 70000},
                                    {"alias": "db", "port": "22"}, {"alias": "-x", "port": 22}, {"alias": "db", "port": True}])
async def test_malformed_hold_params_are_bad_params(tunnel_stack, params):
    svc, r, w = tunnel_stack
    assert (await call(r, w, "tunnels.hold", params))["error"]["code"] == "bad_params"



async def test_the_hold_never_connects_to_the_forward(ssh_env):
    """Each probe through the tab's forward would reach the remote service: one connection a second
    to a database behind a bastion. Being bound is enough."""
    accepted = []
    port = free_port()
    events = Events()
    tunnels = held(events)
    await tunnels.hold("db", port)
    server = await asyncio.start_server(lambda r, w: (accepted.append(1), w.close()), "127.0.0.1", port)
    await wait_until(lambda: tunnels.list()[0]["state"] == "up")
    await asyncio.sleep(0.3)
    assert accepted == []
    server.close()
    await server.wait_closed()
    await tunnels.stop_all()


async def test_a_port_already_held_is_refused(ssh_env):
    """Another listener on the port would read as the tab's ssh up, for as long as it lives."""
    server, port = await listener()
    events = Events()
    tunnels = held(events)
    await tunnels.hold("db", port)
    info = tunnels.list()[0]
    assert info["state"] == "failed" and info["heldBy"] is None
    assert info["error"] == f"Port {port} is already in use."
    server.close()
    await server.wait_closed()


async def test_a_start_during_a_hold_is_not_orphaned(ssh_env):
    """An auto-start that lands while the hold ends the last run is ended too, not left untracked."""
    events = Events()
    tunnels = held(events)
    await tunnels.start("db", ssh_env())
    await wait_until(lambda: "up" in events.states("db"))
    hold = asyncio.ensure_future(tunnels.hold("db", free_port()))
    await asyncio.sleep(0)
    await tunnels.start("db", ssh_env())
    racer = tunnels._tunnels["db"]
    await asyncio.sleep(0.1)  # its ssh is running by now
    await hold
    assert tunnels.pid("db") is None and tunnels.list()[0]["heldBy"] == "tab"
    assert racer.child is None and racer.task.done(), "the run that raced the hold is ended, not orphaned"
    await tunnels.stop_all()


async def test_the_hold_watches_the_forwards_own_address(ssh_env):
    """`LocalForward [::1]:5432 …` binds the IPv6 loopback only: that is where the hold looks."""
    import socket
    with socket.socket(socket.AF_INET6) as s:
        s.bind(("::1", 0))
        port = s.getsockname()[1]
    events = Events()
    tunnels = held(events)
    await tunnels.hold("db", port, bind="::1")
    server = await asyncio.start_server(lambda r, w: w.close(), "::1", port)
    await wait_until(lambda: tunnels.list()[0]["state"] == "up")
    server.close()
    await server.wait_closed()
    await tunnels.stop_all()


async def test_hold_takes_a_bind_through_the_daemon(tunnel_stack):
    svc, r, w = tunnel_stack
    assert (await call(r, w, "tunnels.hold", {"alias": "db", "port": free_port(), "bind": "localhost"}))["result"] == {"ok": True}
    assert (await call(r, w, "tunnels.hold", {"alias": "db", "port": 22, "bind": 3}, id_=2))["error"]["code"] == "bad_params"
    await svc.tunnels.stop("db")



async def test_a_held_tunnel_s_end_is_seen_within_a_second(ssh_env):
    """A held forward is probed at `probe_every` up or not: its end is seen within it."""
    events = Events()
    tunnels = held(events, probe_every=1.0)
    await tunnels.start("db", ssh_env("fail", FAKE_SSH_LINE="Host key verification failed."))
    await wait_until(lambda: "failed" in events.states("db"))
    port = free_port()
    await tunnels.hold("db", port)
    server, _ = await listener(port)
    await wait_until(lambda: tunnels.list()[0]["state"] == "up", timeout=3)
    server.close()
    await server.wait_closed()
    await wait_until(lambda: tunnels.list()[0]["heldBy"] is None, timeout=1.5)
    await tunnels.stop_all()


async def test_the_sampler_ends_with_only_a_held_tunnel_up(ssh_env):
    """A tab's forward has no ssh of the supervisor's to count: nothing to sample, so no wakeups."""
    events = Events()
    tunnels = held(events, traffic_every=0.05)
    await tunnels.start("db", ssh_env("fail", FAKE_SSH_LINE="Host key verification failed."))
    await wait_until(lambda: "failed" in events.states("db"))
    port = free_port()
    await tunnels.hold("db", port)
    server, _ = await listener(port)
    await wait_until(lambda: tunnels.list()[0]["state"] == "up")
    await wait_until(lambda: tunnels._sampler is None or tunnels._sampler.done())
    server.close()
    await tunnels.stop_all()
