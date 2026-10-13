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
    # Its parent here is this test's first supervisor, not a daemon long gone: reap it, as launchd would.
    first._tunnels["kept"].child.popen.wait()
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



async def test_an_adopted_tunnel_is_watched_without_ps(tmp_path, ssh_env):
    """The command line is checked once, at adoption; after that a cheap signal check, not a
    process spawned on the event loop several times a second."""
    events, ledger = Events(), tmp_path / "tunnels.json"
    first = supervisor(events, ledger)
    await first.start("kept", ssh_env(), keep_running=True)
    await wait_until(lambda: "up" in events.states("kept"))
    pid = first.pid("kept")
    await first.stop_all()
    asked = []

    def counting_ps(p):
        asked.append(p)
        return ps_command(p)

    second = supervisor(Events(), ledger, ps=counting_ps)
    await second.adopt()
    adopted = len(asked)
    await asyncio.sleep(1.0)
    assert len(asked) == adopted, "no ps while watching"
    await second.stop("kept")
    await wait_until(lambda: not alive(pid))


async def test_ending_a_process_outside_its_own_group_is_bounded(tmp_path):
    """A pid that leads no process group of its own is never signalled -- it is not an ssh this
    supervisor started -- and waiting on it never hangs the daemon past its budget."""
    from shellforged.tunnels import TunnelSupervisor, _Child
    child = await asyncio.create_subprocess_exec("/bin/sh", "-c", "trap '' TERM; sleep 30")  # same group as pytest
    handle = _Child(child.pid, None, "x", lambda p: "ssh")
    handle.verified = True
    loop = asyncio.get_running_loop()
    started = loop.time()
    await TunnelSupervisor._end_all([handle], grace=0.2)
    assert loop.time() - started < 3
    assert child.returncode is None, "not signalled"
    child.kill()
    await child.wait()


async def test_the_daemon_adopts_before_it_listens(make_service, tmp_path):
    """A start or a snapshot from an app must see the adopted tunnels, never race them."""
    order = []
    svc = make_service(tunnel_ledger=tmp_path / "tunnels.json")
    real_adopt, real_rpc_start = svc.tunnels.adopt, svc.rpc.start

    async def adopt():
        order.append("adopt")
        await real_adopt()

    async def rpc_start():
        order.append("listen")
        await real_rpc_start()

    svc.tunnels.adopt, svc.rpc.start = adopt, rpc_start
    await svc.start()
    assert order[:2] == ["adopt", "listen"]
    await svc.stop()


@pytest.mark.parametrize("command,ours", [
    ("/usr/bin/ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o BatchMode=yes "
     "-o ControlMaster=no -o ControlPath=none db", True),
    # The test's fake: a shell script named ssh.
    ("/bin/sh /tmp/x/bin/ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 "
     "-o BatchMode=yes -o ControlMaster=no -o ControlPath=none db", True),
    ("vim -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o BatchMode=yes "
     "-o ControlMaster=no -o ControlPath=none db", False),
    ("/usr/bin/ssh -v -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o BatchMode=yes "
     "-o ControlMaster=no -o ControlPath=none db", False),
    ("/usr/bin/ssh -o BatchMode=yes -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 "
     "-o ControlMaster=no -o ControlPath=none db", False),
    ("/usr/bin/ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o BatchMode=yes "
     "-o ControlMaster=no -o ControlPath=none web", False),
])
def test_only_this_supervisors_exact_ssh_is_ours(command, ours):
    from shellforged.tunnels import is_tunnel_ssh
    assert is_tunnel_ssh(command, "db") is ours


async def test_a_pid_leading_no_group_of_its_own_is_never_adopted(tmp_path, ssh_env):
    """Every ssh this supervisor starts leads its own process group; one that does not is not ours."""
    from shellforged.tunnels import SSH_OPTIONS
    env = ssh_env()
    ssh = env["PATH"].split(":")[0] + "/ssh"
    other = await asyncio.create_subprocess_exec(ssh, *SSH_OPTIONS, "kept", env=env)  # pytest's own group
    await wait_until(lambda: ps_command(other.pid) is not None and "kept" in ps_command(other.pid))
    ledger = tmp_path / "tunnels.json"
    ledger.write_text(json.dumps({"tunnels": [{"alias": "kept", "pid": other.pid, "since": 1.0, "keepRunning": False}]}))
    tunnels = supervisor(Events(), ledger)
    await tunnels.adopt()
    await asyncio.sleep(0.2)
    assert other.returncode is None and alive(other.pid), "never signalled"
    other.kill()
    await other.wait()


async def test_an_unanswered_ps_keeps_the_entry(tmp_path):
    """ps failing or timing out says nothing about the pid: the entry stays for the next daemon, and
    nothing is signalled or adopted."""
    from shellforged.tunnels import InspectionFailed

    def failing(pid):
        raise InspectionFailed("ps timed out")

    ledger = tmp_path / "tunnels.json"
    entry = {"alias": "kept", "pid": os.getpid(), "since": 1.0, "keepRunning": True}
    ledger.write_text(json.dumps({"tunnels": [entry]}))
    tunnels = supervisor(Events(), ledger, ps=failing)
    await tunnels.adopt()
    assert tunnels.list() == []
    assert json.loads(ledger.read_text())["tunnels"] == [entry]


async def test_a_start_updates_a_running_tunnels_environment_and_keep_running(tmp_path, ssh_env):
    """The app's start for a tunnel already running -- adopted, or kept after the checkbox changed --
    starts no second ssh, but takes the environment and keep-running it carries."""
    events, ledger = Events(), tmp_path / "tunnels.json"
    tunnels = supervisor(events, ledger)
    await tunnels.start("db", ssh_env())
    await wait_until(lambda: "up" in events.states("db"))
    pid = tunnels.pid("db")
    await tunnels.start("db", ssh_env(), keep_running=True)
    assert tunnels.pid("db") == pid
    assert json.loads(ledger.read_text())["tunnels"][0]["keepRunning"] is True
    await tunnels.stop_all()
    assert alive(pid)
    os.killpg(pid, 9)


async def test_an_adopted_tunnel_given_an_environment_restarts_after_a_drop(tmp_path, ssh_env):
    events, ledger = Events(), tmp_path / "tunnels.json"
    first = supervisor(events, ledger)
    await first.start("kept", ssh_env(), keep_running=True)
    await wait_until(lambda: "up" in events.states("kept"))
    pid = first.pid("kept")
    await first.stop_all()
    later = Events()
    second = supervisor(later, ledger)
    await second.adopt()
    await second.start("kept", ssh_env(), keep_running=True)
    os.killpg(pid, 15)
    first._tunnels["kept"].child.popen.wait()  # reaped, as launchd would
    await wait_until(lambda: second.pid("kept") not in (None, pid) and second.list()[0]["state"] == "up", timeout=5)
    await second.stop_all()
    os.killpg(second.pid("kept"), 9)


async def test_a_failed_ledger_write_leaves_no_temp_file(tmp_path, ssh_env):
    """The ledger's path is a folder: the replace fails, and no .tunnels-* file is left anywhere."""
    (tmp_path / "tunnels.json").mkdir()
    events = Events()
    tunnels = supervisor(events, tmp_path / "tunnels.json")
    await tunnels.start("db", ssh_env())
    await wait_until(lambda: "up" in events.states("db"))
    assert not list(tmp_path.glob("**/.tunnels-*"))
    await tunnels.stop_all()


def test_the_ledger_is_synced_before_it_replaces_the_old(tmp_path, monkeypatch):
    calls = []
    real_fsync, real_replace = os.fsync, os.replace
    monkeypatch.setattr(os, "fsync", lambda fd: (calls.append("fsync"), real_fsync(fd)))
    monkeypatch.setattr(os, "replace", lambda a, b: (calls.append("replace"), real_replace(a, b)))
    tunnels = TunnelSupervisor(Events().broadcast, ledger=tmp_path / "tunnels.json")
    tunnels._write_ledger()
    assert calls == ["fsync", "replace"]


def test_a_ledger_that_cannot_be_serialised_leaves_no_temp_file(tmp_path, monkeypatch):
    """json.dump failing is not an OSError: the temp file still goes, and the run loop goes on."""
    def broken(*_args, **_kwargs):
        raise TypeError("not serialisable")
    monkeypatch.setattr(json, "dump", broken)
    tunnels = TunnelSupervisor(Events().broadcast, ledger=tmp_path / "tunnels.json")
    tunnels._write_ledger()
    assert not list(tmp_path.glob(".tunnels-*"))


async def test_a_log_folder_that_cannot_be_made_does_not_stop_the_tunnel(tmp_path, ssh_env):
    """Beside the ledger is a file named like the log folder: ssh's errors go to a temporary folder."""
    (tmp_path / "tunnel-logs").write_text("not a folder")
    events = Events()
    tunnels = supervisor(events, tmp_path / "tunnels.json")
    await tunnels.start("db", ssh_env())
    await wait_until(lambda: "up" in events.states("db"))
    await tunnels.stop_all()


def test_a_supervisor_without_a_ledger_logs_under_the_tests_own_folder(tmp_path):
    """Its ssh logs go to a fresh temporary folder: in a test, one pytest removes with the test's."""
    tunnels = TunnelSupervisor(Events().broadcast)
    assert tmp_path in tunnels._log_file("db").parents


async def test_an_adopted_tunnel_s_end_is_seen_without_polling(tmp_path, ssh_env, monkeypatch):
    """An adopted ssh is no child, yet its end is watched (kqueue), not checked every second."""
    from shellforged import tunnels as module
    events, ledger = Events(), tmp_path / "tunnels.json"
    first = supervisor(events, ledger)
    await first.start("kept", ssh_env(), keep_running=True)
    await wait_until(lambda: "up" in events.states("kept"))
    pid = first.pid("kept")
    await first.stop_all()
    later = Events()
    second = supervisor(later, ledger)
    await second.adopt()
    checks = []
    real = module._Child.alive
    monkeypatch.setattr(module._Child, "alive", lambda self: (checks.append(1), real(self))[1])
    await asyncio.sleep(1.5)
    assert len(checks) <= 1, f"{len(checks)} liveness checks in 1.5 s: one as the watch begins, then none"
    monkeypatch.setattr(module._Child, "alive", real)
    os.killpg(pid, 15)
    first._tunnels["kept"].child.popen.wait()
    await wait_until(lambda: "stopped" in later.states("kept"), timeout=3)
    await second.stop_all()
