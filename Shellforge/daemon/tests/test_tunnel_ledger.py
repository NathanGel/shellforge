# daemon/tests/test_tunnel_ledger.py
"""The tunnel ledger: every ssh the supervisor runs is written to `tunnels.json`, so a keep-running
tunnel outlives the daemon and the next one adopts it, and an ssh a crash left behind is ended. A
pid is only ever signalled when its command line is still the supervisor's ssh for that alias."""
import asyncio
import json
import os

import pytest

from shellforged.tunnels import TunnelSupervisor, ps_command
from tests.conftest import wait_until
from tests.test_tunnels import Events, ssh_env  # noqa: F401 - the fixture


def supervisor(events, ledger, **overrides):
    return TunnelSupervisor(events.broadcast, ledger=ledger,
                            **{"up_after": 0.2, "backoff_start": 0.1, "backoff_cap": 0.4, **overrides})


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # A zombie of an exited child still answers kill(0) until reaped: ask ps.
    return ps_command(pid) is not None


async def test_keep_running_survives_stop_all(tmp_path, ssh_env):
    events, ledger = Events(), tmp_path / "tunnels.json"
    tunnels = supervisor(events, ledger)
    await tunnels.start("kept", ssh_env(), keep_running=True)
    await tunnels.start("plain", ssh_env())
    await wait_until(lambda: "up" in events.states("kept") and "up" in events.states("plain"))
    kept, plain = tunnels.pid("kept"), tunnels.pid("plain")
    await tunnels.stop_all()
    assert alive(kept) and not alive(plain)
    entries = json.loads(ledger.read_text())["tunnels"]
    assert [(e["alias"], e["pid"], e["keepRunning"]) for e in entries] == [("kept", kept, True)]
    os.killpg(kept, 9)


async def test_a_kept_tunnel_is_adopted_and_can_be_stopped(tmp_path, ssh_env):
    events, ledger = Events(), tmp_path / "tunnels.json"
    first = supervisor(events, ledger)
    await first.start("kept", ssh_env(), keep_running=True)
    await wait_until(lambda: "up" in events.states("kept"))
    pid, since = first.pid("kept"), first.list()[0]["since"]
    await first.stop_all()

    later = Events()
    second = supervisor(later, ledger)
    await second.adopt()
    assert second.list()[0]["state"] == "up" and second.list()[0]["since"] == since
    assert second.pid("kept") == pid
    await second.stop("kept")
    await wait_until(lambda: not alive(pid))
    assert second.list()[0]["state"] == "stopped"
    assert json.loads(ledger.read_text())["tunnels"] == []


async def test_an_adopted_tunnel_that_ends_is_said_stopped(tmp_path, ssh_env):
    events, ledger = Events(), tmp_path / "tunnels.json"
    first = supervisor(events, ledger)
    await first.start("kept", ssh_env(), keep_running=True)
    await wait_until(lambda: "up" in events.states("kept"))
    pid = first.pid("kept")
    await first.stop_all()
    later = Events()
    second = supervisor(later, ledger)
    await second.adopt()
    os.killpg(pid, 15)
    await wait_until(lambda: second.list()[0]["state"] == "stopped", timeout=3)
    assert second.list()[0]["error"] == "Ended outside Shellforge."
    await second.stop_all()


async def test_a_leftover_tunnel_is_ended_at_start(tmp_path, ssh_env):
    """The daemon crashed: its plain tunnel's ssh still runs, holding the port, in the ledger."""
    events, ledger = Events(), tmp_path / "tunnels.json"
    first = supervisor(events, ledger)
    await first.start("plain", ssh_env())
    await wait_until(lambda: "up" in events.states("plain"))
    pid = first.pid("plain")
    for task in [t.task for t in first._tunnels.values()]:
        task.cancel()  # a crash: nothing ended, the ledger as it was
    second = supervisor(Events(), ledger)
    await second.adopt()
    await wait_until(lambda: not alive(pid), timeout=4)
    assert second.list() == []
    assert json.loads(ledger.read_text())["tunnels"] == []


async def test_a_reused_pid_is_left_alone(tmp_path):
    """The ledger names a pid that is now another program: never signalled, never adopted."""
    ledger = tmp_path / "tunnels.json"
    other = await asyncio.create_subprocess_exec("sleep", "30", start_new_session=True)
    ledger.write_text(json.dumps({"tunnels": [
        {"alias": "kept", "pid": other.pid, "since": 5.0, "keepRunning": True},
        {"alias": "plain", "pid": other.pid, "since": 5.0, "keepRunning": False}]}))
    tunnels = supervisor(Events(), ledger)
    await tunnels.adopt()
    await asyncio.sleep(0.3)
    assert other.returncode is None and alive(other.pid)
    assert tunnels.list() == []
    assert json.loads(ledger.read_text())["tunnels"] == []
    other.kill()
    await other.wait()


@pytest.mark.parametrize("text", ["", "not json", "[]", '{"tunnels": "x"}', '{"tunnels": [{"alias": 3}]}'])
async def test_a_corrupt_ledger_is_ignored(tmp_path, text):
    ledger = tmp_path / "tunnels.json"
    ledger.write_text(text)
    tunnels = supervisor(Events(), ledger)
    await tunnels.adopt()
    assert tunnels.list() == []
    assert json.loads(ledger.read_text()) == {"tunnels": []}


async def test_the_ledger_holds_no_environment(tmp_path, ssh_env):
    events, ledger = Events(), tmp_path / "tunnels.json"
    tunnels = supervisor(events, ledger)
    await tunnels.start("db", ssh_env(SSH_AUTH_SOCK="/secret/agent"))
    await wait_until(lambda: "up" in events.states("db"))
    text = ledger.read_text()
    assert "secret" not in text and "PATH" not in text
    assert set(json.loads(text)["tunnels"][0]) == {"alias", "pid", "since", "keepRunning"}
    await tunnels.stop_all()


async def test_a_missing_ledger_adopts_nothing(tmp_path):
    tunnels = supervisor(Events(), tmp_path / "none" / "tunnels.json")
    await tunnels.adopt()
    assert tunnels.list() == []


async def test_the_daemon_adopts_at_start(make_service, tmp_path, ssh_env):
    """A keep-running ssh from the last daemon is up in the new one's snapshot as soon as it starts."""
    from shellforged.tunnels import SSH_OPTIONS
    ledger = tmp_path / "tunnels.json"
    env = ssh_env()
    ssh = env["PATH"].split(":")[0] + "/ssh"
    kept = await asyncio.create_subprocess_exec(ssh, *SSH_OPTIONS, "kept", env=env, start_new_session=True)
    ledger.write_text(json.dumps({"tunnels": [{"alias": "kept", "pid": kept.pid, "since": 7.0, "keepRunning": True}]}))
    await wait_until(lambda: ps_command(kept.pid) is not None and "kept" in ps_command(kept.pid))
    svc = make_service(tunnel_ledger=ledger)
    await svc.start()
    assert [(t["alias"], t["state"], t["since"]) for t in svc.tunnels.list()] == [("kept", "up", 7.0)]
    await svc.stop()
    assert alive(kept.pid), "it keeps running past this daemon too"
    os.killpg(kept.pid, 9)
    await kept.wait()
